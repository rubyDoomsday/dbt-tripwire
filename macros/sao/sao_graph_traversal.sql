{#
    Graph-walking helpers over the `graph` Jinja context var (built from
    Manifest.flat_graph -- graph.nodes holds models/seeds/snapshots/tests,
    graph.sources holds true dbt sources separately; verified against
    dbt-core 1.10.13's Manifest.build_flat_graph()).

    Both macros below use a namespace() object to carry mutable
    frontier/visited state across `{% for %}` iterations, since plain
    `{% set %}` reassignment inside a for-loop does not persist across
    iterations in Jinja2 -- the standard workaround.
#}

{#-
    Ancestor inheritance: walk depends_on.nodes upward from `model_id`,
    breadth-first, through any non-SAO-managed pass-through nodes (plain
    views etc.), looking for an SAO-managed ancestor that is also part of
    this invocation's selected_resources. Stops at the first level where one
    or more qualifying ancestors are found -- does not walk past them.

    Returns {'found': false} if no such ancestor exists on any path, else
    {'found': true, 'should_run': <bool>, 'ancestor_ids': [...]}. should_run
    is true if ANY qualifying ancestor found at that level actually ran.
-#}
{% macro sao_check_ancestor_inheritance(model_id) %}
    {%- set start_node = graph.nodes.get(model_id, {}) -%}
    {%- set ns = namespace(
        frontier = start_node.get('depends_on', {}).get('nodes', []) | list,
        visited = [],
        found_ids = [],
        done = false
    ) -%}

    {% for depth in range(50) %}
        {% if not ns.done %}
            {% if ns.frontier | length == 0 %}
                {%- set ns.done = true -%}
            {% else %}
                {%- set qualifying = [] -%}
                {%- set next_frontier = [] -%}
                {% for aid in ns.frontier %}
                    {% if aid not in ns.visited %}
                        {%- set ns.visited = ns.visited + [aid] -%}
                        {% if aid in graph.nodes %}
                            {%- set anode = graph.nodes[aid] -%}
                            {%- set a_materialized = anode.get('config', {}).get('materialized', '') -%}
                            {%- set is_sao = dbt_tripwire.sao_is_sao_managed_materialization(a_materialized) -%}
                            {%- set is_selected = aid in selected_resources -%}
                            {% if is_sao and is_selected %}
                                {%- do qualifying.append(aid) -%}
                            {% else %}
                                {% for d in anode.get('depends_on', {}).get('nodes', []) %}
                                    {% if d not in ns.visited and d not in next_frontier %}
                                        {%- do next_frontier.append(d) -%}
                                    {% endif %}
                                {% endfor %}
                            {% endif %}
                        {% endif %}
                        {#- if aid is a source (or unknown/disabled node), it's a dead end: no depends_on to add -#}
                    {% endif %}
                {% endfor %}

                {% if qualifying | length > 0 %}
                    {%- set ns.found_ids = qualifying -%}
                    {%- set ns.done = true -%}
                {% else %}
                    {%- set ns.frontier = next_frontier -%}
                {% endif %}
            {% endif %}
        {% endif %}
    {% endfor %}

    {% if not ns.done %}
        {{ log("dbt_tripwire: ancestor-inheritance walk for " ~ model_id ~
               " hit the 50-level depth cap before resolving -- truncated, treating as no" ~
               " qualifying ancestor found. This likely means a real dependency-graph depth" ~
               " issue rather than the loop's own bookkeeping.", info=True) }}
    {% endif %}

    {% if ns.found_ids | length > 0 %}
        {%- set id_list = "'" ~ (ns.found_ids | join("','")) ~ "'" -%}
        {%- set query -%}
            select max(iff(SHOULD_RUN, 1, 0)) as ANY_TRUE
            from {{ dbt_tripwire.sao_run_log_relation() }}
            where INVOCATION_ID = '{{ invocation_id }}'
              and MODEL_ID in ({{ id_list }})
        {%- endset -%}
        {%- set result = run_query(query) -%}
        {%- set any_true = (result.rows | length > 0 and result.rows[0][0] == 1) -%}
        {{ return({'found': true, 'should_run': any_true, 'ancestor_ids': ns.found_ids}) }}
    {% else %}
        {{ return({'found': false}) }}
    {% endif %}
{% endmacro %}

{#-
    Walk further up from `model_id`, through ALL ancestor types (SAO-managed
    or not), to the true dbt sources at the edge of the DAG. Returns a flat,
    de-duplicated list of source unique_ids reachable from this root.

    Zero-source models (no dbt source lineage at all) naturally return an
    empty list here -- the caller (sao_check_root_sources) then reports
    'no_signal', which correctly falls back to Tier 0 only, with no special
    casing required.
-#}
{% macro sao_collect_reachable_sources(model_id) %}
    {%- set ns = namespace(frontier=[model_id], visited=[], sources=[]) -%}

    {% for depth in range(50) %}
        {% if ns.frontier | length > 0 %}
            {%- set next_frontier = [] -%}
            {% for nid in ns.frontier %}
                {% if nid not in ns.visited %}
                    {%- set ns.visited = ns.visited + [nid] -%}
                    {% if nid in graph.sources %}
                        {%- set ns.sources = ns.sources + [nid] -%}
                    {% elif nid in graph.nodes %}
                        {%- set deps = graph.nodes[nid].get('depends_on', {}).get('nodes', []) -%}
                        {% for d in deps %}
                            {% if d not in ns.visited and d not in next_frontier %}
                                {%- do next_frontier.append(d) -%}
                            {% endif %}
                        {% endfor %}
                    {% endif %}
                {% endif %}
            {% endfor %}
            {%- set ns.frontier = next_frontier -%}
        {% endif %}
    {% endfor %}

    {% if ns.frontier | length > 0 %}
        {{ log("dbt_tripwire: source-collection walk for " ~ model_id ~
               " hit the 50-level depth cap before draining the frontier -- some reachable" ~
               " sources may not have been discovered, and a Tier 1/2 signal on one of them" ~
               " could go unnoticed.", info=True) }}
    {% endif %}

    {{ return(ns.sources | unique | list) }}
{% endmacro %}
