{#
    Tier 0 -- business rules, no data check at all. Cheapest possible tier,
    decided entirely from the model's persisted SAO_MODEL_STATE row plus its
    meta.sao config.

    tier0_fires = first_run (no prior state row)
               OR previous_run_errored (LAST_ERROR_AT is set)
               OR always_build
               OR (build_interval_check AND window_elapsed)
               OR (max_skips is set AND skip_count >= max_skips)
#}

{#- Fetch the persisted state row for a model, plus a server-side
    (Snowflake-clock) evaluation of whether the configured interval has
    elapsed since LAST_RUN_AT. Returns none if no row exists yet (first_run). -#}
{% macro sao_fetch_model_state(model_id, interval_unit, interval_value) %}
    {%- set normalized_unit = dbt_tripwire.sao_normalize_interval_unit(interval_unit) -%}
    {%- set normalized_value = dbt_tripwire.sao_validate_interval_value(interval_value) -%}
    {%- set query -%}
        select
            LAST_RUN_AT,
            SKIP_COUNT,
            LAST_ERROR_AT,
            case
                when LAST_RUN_AT is not null
                then current_timestamp() > dateadd({{ normalized_unit }}, {{ normalized_value }}, LAST_RUN_AT)
                else null
            end as WINDOW_ELAPSED
        from {{ dbt_tripwire.sao_model_state_relation() }}
        where MODEL_ID = '{{ model_id }}'
        limit 1
    {%- endset -%}
    {%- set result = run_query(query) -%}
    {% if result.rows | length == 0 %}
        {{ return(none) }}
    {% else %}
        {{ return({
            'last_run_at': result.rows[0][0],
            'skip_count': result.rows[0][1] or 0,
            'last_error_at': result.rows[0][2],
            'window_elapsed': result.rows[0][3],
        }) }}
    {% endif %}
{% endmacro %}

{% macro sao_tier0_check(state_row, sao_config) %}
    {% if state_row is none %}
        {{ return({'fires': true, 'reason': 'first_run'}) }}
    {% endif %}

    {#- The consuming model's real materialization errored last time it was
        attempted. Forces an immediate retry next invocation regardless of the
        interval or the (shared, source-level) Tier 1/2 baseline -- see
        sao_relations.sql for why the source-level baseline alone can't be
        trusted to trigger this model's retry. Cleared on the next successful
        real rebuild (sao_record_run_results.sql). -#}
    {% if state_row.last_error_at is not none %}
        {{ return({'fires': true, 'reason': 'previous_run_errored'}) }}
    {% endif %}

    {% if sao_config.always_build %}
        {{ return({'fires': true, 'reason': 'always_build'}) }}
    {% endif %}

    {% if sao_config.build_interval_check and state_row.window_elapsed %}
        {{ return({'fires': true, 'reason': 'window_elapsed'}) }}
    {% endif %}

    {% if sao_config.max_skips is not none and state_row.skip_count >= sao_config.max_skips %}
        {{ return({'fires': true, 'reason': 'max_skips_exceeded'}) }}
    {% endif %}

    {{ return({'fires': false, 'reason': none}) }}
{% endmacro %}
