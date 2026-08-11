{#
    Top-level orchestrator, called as the literal first thing inside the
    sao_table materialization. Combines: global kill switch -> Tier 0 ->
    ancestor inheritance -> Tier 1/2 root source check. Writes its decision
    to the transient, append-only SAO_RUN_LOG immediately (via run_query,
    never statement()) so descendants relying on ancestor inheritance can
    read it later in this same invocation.
#}

{% macro sao_log_run_decision(model_id, decision) %}
    {%- set insert_sql -%}
        insert into {{ dbt_tripwire.sao_run_log_relation() }} (INVOCATION_ID, MODEL_ID, SHOULD_RUN, REASON)
        select
            '{{ invocation_id }}',
            '{{ model_id }}',
            {{ 'TRUE' if decision.should_run else 'FALSE' }},
            '{{ decision.reason }}'
    {%- endset -%}
    {% do run_query(insert_sql) %}
{% endmacro %}

{% macro sao_should_run() %}
    {% do dbt_tripwire.sao_ensure_state_tables_once() %}
    {%- set model_id = model.unique_id -%}

    {#- Missing-relation guard: if SAO_MODEL_STATE has a row for this model but
        its target relation doesn't actually exist (dropped, schema rebuild,
        cloned env), the skip path would otherwise hand dbt a `none` relation
        and downstream refs would face-plant. Treat this exactly like
        first_run -- takes priority over everything else, including the
        global kill switch's own reason, since building is correct either way
        and this is the more specific/useful reason to log. -#}
    {% if load_relation(this) is none %}
        {%- set decision = {'should_run': true, 'reason': 'first_run'} -%}
    {% elif dbt_tripwire.sao_is_globally_disabled() %}
        {%- set decision = {'should_run': true, 'reason': 'disabled_globally'} -%}
    {% else %}
        {%- set sao_config = dbt_tripwire.sao_get_current_model_config() -%}
        {%- set state_row = dbt_tripwire.sao_fetch_model_state(
            model_id,
            sao_config.build_after_interval_unit,
            sao_config.build_after_interval_value
        ) -%}
        {%- set tier0 = dbt_tripwire.sao_tier0_check(state_row, sao_config) -%}

        {% if tier0.fires %}
            {%- set decision = {'should_run': true, 'reason': tier0.reason} -%}
        {% else %}
            {#- Ancestor inheritance no longer short-circuits this model's own
                source check. A model can both inherit from a qualifying
                SAO-managed ancestor AND ref a raw source directly (or via a
                pass-through node the ancestor doesn't cover) -- inheriting
                the ancestor's decision alone would miss a change signal on
                that direct source whenever the ancestor happened to skip.
                sao_check_root_sources walks ALL of this model's reachable
                sources regardless of ancestor status; any source already
                "owned" by the ancestor is a per-invocation cache hit
                (SAO_SOURCE_CHECK_LOG), so this costs a metadata lookup, not
                a re-scan. -#}
            {%- set ancestor = dbt_tripwire.sao_check_ancestor_inheritance(model_id) -%}
            {%- set ancestor_should_run = (ancestor.found and ancestor.should_run) -%}

            {% if sao_config.build_source_check %}
                {%- set source_check = dbt_tripwire.sao_check_root_sources(model_id) -%}
            {% else %}
                {#- build_source_check: false -> this model never builds from a data-change
                    signal, falls back to ancestor inheritance / Tier 0 only. -#}
                {%- set source_check = {'signal_found': false, 'reason': 'no_signal'} -%}
            {% endif %}

            {%- set should_run = ancestor_should_run or source_check.signal_found -%}
            {% if ancestor_should_run %}
                {%- set reason = 'upstream_propagated' -%}
            {% elif source_check.signal_found %}
                {%- set reason = source_check.reason -%}
            {% else %}
                {%- set reason = 'no_signal' -%}
            {% endif %}
            {%- set decision = {'should_run': should_run, 'reason': reason} -%}
        {% endif %}
    {% endif %}

    {% do dbt_tripwire.sao_log_run_decision(model_id, decision) %}
    {{ return(decision) }}
{% endmacro %}
