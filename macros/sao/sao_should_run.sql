{% macro sao_log_run_decision(model_id, decision) %}
    {%- set insert_sql -%}
        insert into {{ dbt_tripwire.sao_run_log_relation() }} (INVOCATION_ID, MODEL_ID, SHOULD_RUN, REASON, LOGGED_AT)
        select
            '{{ invocation_id }}',
            '{{ model_id }}',
            {{ 'TRUE' if decision.should_run else 'FALSE' }},
            '{{ decision.reason }}',
            current_timestamp()
    {%- endset -%}
    {% do run_query(insert_sql) %}
{% endmacro %}

{% macro sao_should_run() %}
    {#- Must stay the literal first check -- disabled must never touch SAO_RUN_LOG. -#}
    {% if dbt_tripwire.sao_is_globally_disabled() %}
        {{ return({'should_run': true, 'reason': 'disabled_globally'}) }}
    {% endif %}

    {%- set model_id = model.unique_id -%}

    {% if load_relation(this) is none %}
        {%- set decision = {'should_run': true, 'reason': 'first_run'} -%}
    {% elif should_full_refresh() %}
        {%- set decision = {'should_run': true, 'reason': 'full_refresh'} -%}
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
            {%- set ancestor = dbt_tripwire.sao_check_ancestor_inheritance(model_id) -%}
            {%- set ancestor_should_run = (ancestor.found and ancestor.should_run) -%}

            {% if sao_config.build_source_check %}
                {%- set source_check = dbt_tripwire.sao_check_root_sources(model_id) -%}
            {% else %}
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
