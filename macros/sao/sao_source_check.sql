{#
    Tier 1/2 source-anchored checks, with the mandatory per-invocation cache
    (SAO_SOURCE_CHECK_LOG). See design doc "Risks" -- this cache is not
    optional, it's the central lesson of round-4 review.

    Cache correctness relies on the transient SAO_SOURCE_CHECK_LOG table
    itself (queried via SQL), not on any in-process/in-memory memoization --
    that's deliberate: dbt runs multi-threaded, so an in-memory Jinja/Python
    dict would not be reliably shared across threads. Two threads racing to
    check the same uncached source in the same moment may both compute it
    independently before either writes its cache row -- harmless duplicate
    work per the design doc, not a correctness problem.
#}

{% macro sao_get_source_relation(source_id) %}
    {%- set snode = graph.sources[source_id] -%}
    {{ return(api.Relation.create(database=snode.database, schema=snode.schema, identifier=snode.identifier)) }}
{% endmacro %}

{#- Optional per-source watermark column, surfaced via `meta.sao_watermark_col`
    on the source table in sources.yml. Sources with no watermark column
    configured fall back to COUNT(*)-only Tier 2, same as before. Validated
    against an identifier allowlist before it's ever interpolated into SQL
    (see sao_validate_identifier in sao_config.sql) -- this value ends up
    unquoted inside a min()/max() expression, so it gets the same treatment
    build_after_interval_unit already gets. -#}
{% macro sao_get_source_watermark_col(source_id) %}
    {%- set snode = graph.sources[source_id] -%}
    {%- set meta = snode.get('meta', {}) or {} -%}
    {%- set col = meta.get('sao_watermark_col') -%}
    {% if col is not none %}
        {%- do dbt_tripwire.sao_validate_identifier(col, "sao_watermark_col for source '" ~ source_id ~ "'") -%}
    {% endif %}
    {{ return(col) }}
{% endmacro %}

{#-
    Tier 2 scan: COUNT(*), plus MIN/MAX(watermark_col) when a watermark
    column is configured for this source. Returns a dict with row_count
    (always) and min_watermark/max_watermark (none if not configured).
    Watermark values are cast to varchar before being read back, so the
    later baseline comparison is a stable string compare rather than
    comparing whatever native Python type the driver happens to deserialize
    a variant/timestamp column into.
-#}
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

{#- Look up this invocation's cached check result for one source, if any. -#}
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

{#-
    Tier 1: SYSTEM$LAST_CHANGE_COMMIT_TIME() against the true source -- no
    scan. Tier 2 (only if Tier 1 found no signal, including when Tier 1's
    baseline is missing on the very first check for this source, or when
    Snowflake returns null for a source with no change-tracking metadata):
    COUNT(*) against the same source -- requires a scan.

    Persists the freshly observed values into SAO_SOURCE_CHECK_LOG
    (append-only insert) for later batched merge into SAO_SOURCE_STATE at
    on-run-end, regardless of which tier ultimately fired.
-#}
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

    {#- Whenever Tier 1 fires -- whether because there's no baseline yet (true
        first check) or because the commit-time moved since the last baseline
        (real change, OR a spurious one-off metadata shift; Snowflake's
        SYSTEM$LAST_CHANGE_COMMIT_TIME is documented as not fully reliable for
        very small tables and was observed during POC testing to shift once
        with no real DML involved) -- also capture the current Tier 2 metrics
        (ROW_COUNT, and MIN/MAX watermark if configured) and persist them as
        this invocation's Tier 2 baseline. Without this, the Tier 2 baseline
        stays stale (or NULL) in SAO_SOURCE_STATE until some future
        invocation happens to fall through to the Tier 2 branch, at which
        point it would compare the current values against a stale/NULL
        baseline and (for the NULL case) a comparison against None always
        evaluates true -- a guaranteed false-positive signal on that source's
        next "Tier 1 stable" invocation, indistinguishable from a real
        change. Piggybacking the scan onto an already-expensive
        Tier-1-fires check (which is already driving a model rebuild) costs
        one extra scan per source, only on invocations that were rebuilding
        anyway. -#}
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
        {#- Tier 1 found no signal (either unchanged, or null/unavailable) -> fall to Tier 2 -#}
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
            (INVOCATION_ID, SOURCE_ID, SIGNAL_FOUND, CHECKED_TIER, LAST_CHANGE_COMMIT_TIME, ROW_COUNT, MIN_WATERMARK, MAX_WATERMARK)
        select
            '{{ invocation_id }}',
            '{{ source_id }}',
            {{ 'TRUE' if ns.signal_found else 'FALSE' }},
            '{{ ns.tier }}',
            {{ current_commit_time if current_commit_time is not none else 'null' }},
            {{ ns.current_row_count if ns.current_row_count is not none else 'null' }},
            {{ "to_variant('" ~ (ns.current_min_watermark | replace("'", "''")) ~ "')" if ns.current_min_watermark is not none else 'null' }},
            {{ "to_variant('" ~ (ns.current_max_watermark | replace("'", "''")) ~ "')" if ns.current_max_watermark is not none else 'null' }}
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

{#-
    Root source check: collect all true sources reachable from `model_id`,
    check each (cache-first), and fire true if ANY shows a signal at either
    tier. Every reachable source is checked (no short-circuit) so the shared
    per-invocation cache stays warm for every other model touching the same
    sources this run, and so SAO_SOURCE_STATE gets refreshed for all of them
    at on-run-end regardless of which source ultimately drove the decision.
-#}
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
