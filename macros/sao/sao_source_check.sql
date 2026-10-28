{#- Cache correctness relies on the transient SAO_SOURCE_CHECK_LOG table
    itself, not in-memory memoization -- dbt runs multi-threaded. -#}

{% macro sao_get_source_relation(source_id) %}
    {%- set snode = graph.sources[source_id] -%}
    {{ return(api.Relation.create(database=snode.database, schema=snode.schema, identifier=snode.identifier)) }}
{% endmacro %}

{% macro sao_get_source_watermark_col(source_id) %}
    {%- set snode = graph.sources[source_id] -%}
    {%- set meta = snode.get('meta', {}) or {} -%}
    {%- set col = meta.get('sao_watermark_col') -%}
    {% if col is not none %}
        {%- do dbt_tripwire.sao_validate_identifier(col, "sao_watermark_col for source '" ~ source_id ~ "'") -%}
    {% endif %}
    {{ return(col) }}
{% endmacro %}

{#- Watermark cast to varchar for a stable string compare against the baseline. -#}
{% macro sao_scan_source_metrics(relation, watermark_col) %}
    {% if watermark_col %}
        {%- set result = run_query(
            'select count(*) as CNT, min(' ~ watermark_col ~ ')::varchar as MINW, max(' ~ watermark_col ~ ')::varchar as MAXW from ' ~ relation
        ) -%}
        {{ return({'row_count': result.rows[0][0], 'min_watermark': result.rows[0][1], 'max_watermark': result.rows[0][2]}) }}
    {% else %}
        {%- set result = run_query('select count(*) as CNT from ' ~ relation) -%}
        {{ return({'row_count': result.rows[0][0], 'min_watermark': none, 'max_watermark': none}) }}
    {% endif %}
{% endmacro %}

{% macro sao_get_cached_source_check(source_id) %}
    {%- set query -%}
        select SIGNAL_FOUND, CHECKED_TIER
        from {{ dbt_tripwire.sao_source_check_log_relation() }}
        where INVOCATION_ID = '{{ invocation_id }}'
          and SOURCE_ID = '{{ source_id }}'
        limit 1
    {%- endset -%}
    {%- set result = run_query(query) -%}
    {% if result.rows | length > 0 %}
        {{ return({'signal_found': result.rows[0][0], 'tier': result.rows[0][1]}) }}
    {% else %}
        {{ return(none) }}
    {% endif %}
{% endmacro %}

{% macro sao_check_source_uncached(source_id) %}
    {%- set relation = dbt_tripwire.sao_get_source_relation(source_id) -%}
    {%- set watermark_col = dbt_tripwire.sao_get_source_watermark_col(source_id) -%}

    {%- set baseline_query -%}
        select LAST_CHANGE_COMMIT_TIME, ROW_COUNT, MIN_WATERMARK::varchar, MAX_WATERMARK::varchar
        from {{ dbt_tripwire.sao_source_state_relation() }}
        where SOURCE_ID = '{{ source_id }}'
        limit 1
    {%- endset -%}
    {%- set baseline_result = run_query(baseline_query) -%}
    {%- set has_baseline = baseline_result.rows | length > 0 -%}
    {%- set baseline_commit_time = baseline_result.rows[0][0] if has_baseline else none -%}
    {%- set baseline_row_count = baseline_result.rows[0][1] if has_baseline else none -%}
    {%- set baseline_min_watermark = baseline_result.rows[0][2] if has_baseline else none -%}
    {%- set baseline_max_watermark = baseline_result.rows[0][3] if has_baseline else none -%}

    {%- set tier1_query -%}
        select system$last_change_commit_time('{{ relation }}') as COMMIT_TIME
    {%- endset -%}
    {%- set tier1_result = run_query(tier1_query) -%}
    {%- set current_commit_time = tier1_result.rows[0][0] -%}

    {%- set ns = namespace(signal_found=none, tier=none, current_row_count=none, current_min_watermark=none, current_max_watermark=none) -%}

    {#- Whenever Tier 1 fires, also capture Tier 2 metrics as this invocation's
        baseline -- otherwise a stale/NULL baseline guarantees a false-positive
        signal on a later Tier 2 check. -#}
    {% if not has_baseline %}
        {%- set ns.signal_found = true -%}
        {%- set ns.tier = 'TIER1' -%}
        {%- set metrics = dbt_tripwire.sao_scan_source_metrics(relation, watermark_col) -%}
        {%- set ns.current_row_count = metrics.row_count -%}
        {%- set ns.current_min_watermark = metrics.min_watermark -%}
        {%- set ns.current_max_watermark = metrics.max_watermark -%}
    {% elif current_commit_time is not none and current_commit_time != baseline_commit_time %}
        {%- set ns.signal_found = true -%}
        {%- set ns.tier = 'TIER1' -%}
        {%- set metrics = dbt_tripwire.sao_scan_source_metrics(relation, watermark_col) -%}
        {%- set ns.current_row_count = metrics.row_count -%}
        {%- set ns.current_min_watermark = metrics.min_watermark -%}
        {%- set ns.current_max_watermark = metrics.max_watermark -%}
    {% else %}
        {%- set metrics = dbt_tripwire.sao_scan_source_metrics(relation, watermark_col) -%}
        {%- set ns.current_row_count = metrics.row_count -%}
        {%- set ns.current_min_watermark = metrics.min_watermark -%}
        {%- set ns.current_max_watermark = metrics.max_watermark -%}
        {%- set ns.signal_found = (
            ns.current_row_count != baseline_row_count
            or ns.current_min_watermark != baseline_min_watermark
            or ns.current_max_watermark != baseline_max_watermark
        ) -%}
        {%- set ns.tier = 'TIER2' -%}
    {% endif %}

    {%- set insert_sql -%}
        insert into {{ dbt_tripwire.sao_source_check_log_relation() }}
            (INVOCATION_ID, SOURCE_ID, SIGNAL_FOUND, CHECKED_TIER, LAST_CHANGE_COMMIT_TIME, ROW_COUNT, MIN_WATERMARK, MAX_WATERMARK, CHECKED_AT)
        select
            '{{ invocation_id }}',
            '{{ source_id }}',
            {{ 'TRUE' if ns.signal_found else 'FALSE' }},
            '{{ ns.tier }}',
            {{ current_commit_time if current_commit_time is not none else 'null' }},
            {{ ns.current_row_count if ns.current_row_count is not none else 'null' }},
            {{ "to_variant('" ~ (ns.current_min_watermark | replace("'", "''")) ~ "')" if ns.current_min_watermark is not none else 'null' }},
            {{ "to_variant('" ~ (ns.current_max_watermark | replace("'", "''")) ~ "')" if ns.current_max_watermark is not none else 'null' }},
            current_timestamp()
    {%- endset -%}
    {% do run_query(insert_sql) %}

    {{ return({'signal_found': ns.signal_found, 'tier': ns.tier}) }}
{% endmacro %}

{% macro sao_check_source(source_id) %}
    {%- set cached = dbt_tripwire.sao_get_cached_source_check(source_id) -%}
    {% if cached is not none %}
        {{ return(cached) }}
    {% endif %}
    {{ return(dbt_tripwire.sao_check_source_uncached(source_id)) }}
{% endmacro %}

{#- No short-circuit: keeps the shared per-invocation cache warm for other
    models, and refreshes SAO_SOURCE_STATE for every reachable source. -#}
{% macro sao_check_root_sources(model_id) %}
    {%- set source_ids = dbt_tripwire.sao_collect_reachable_sources(model_id) -%}
    {% if source_ids | length == 0 %}
        {{ return({'signal_found': false, 'reason': 'no_signal', 'source_count': 0}) }}
    {% endif %}

    {%- set ns = namespace(any_signal=false, winning_tier=none) -%}
    {% for sid in source_ids %}
        {%- set res = dbt_tripwire.sao_check_source(sid) -%}
        {% if res.signal_found and not ns.any_signal %}
            {%- set ns.any_signal = true -%}
            {%- set ns.winning_tier = res.tier -%}
        {% endif %}
    {% endfor %}

    {% if ns.any_signal %}
        {%- set reason = 'source_signal_tier1' if ns.winning_tier == 'TIER1' else 'source_signal_tier2' -%}
        {{ return({'signal_found': true, 'reason': reason, 'source_count': source_ids | length}) }}
    {% else %}
        {{ return({'signal_found': false, 'reason': 'no_signal', 'source_count': source_ids | length}) }}
    {% endif %}
{% endmacro %}
