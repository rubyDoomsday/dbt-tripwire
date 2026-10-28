{% macro sao_state_relation(model_name) %}
    {% if execute %}
        {%- set state_node = graph.nodes.values()
            | selectattr('name', 'equalto', model_name)
            | selectattr('package_name', 'equalto', 'dbt_tripwire')
            | first -%}
        {{ return(api.Relation.create(
            database=state_node.database,
            schema=state_node.schema,
            identifier=state_node.alias
        )) }}
    {% else %}
        {{ return(api.Relation.create()) }}
    {% endif %}
{% endmacro %}

{% macro sao_model_state_relation() %}
    {{ return(dbt_tripwire.sao_state_relation('sao_model_state')) }}
{% endmacro %}

{% macro sao_source_state_relation() %}
    {{ return(dbt_tripwire.sao_state_relation('sao_source_state')) }}
{% endmacro %}

{% macro sao_run_log_relation() %}
    {{ return(dbt_tripwire.sao_state_relation('sao_run_log')) }}
{% endmacro %}

{% macro sao_source_check_log_relation() %}
    {{ return(dbt_tripwire.sao_state_relation('sao_source_check_log')) }}
{% endmacro %}

{% macro sao_purge_transient_logs(retention_days=30) %}
    {%- set is_valid = (retention_days is number and retention_days == (retention_days | int) and retention_days > 0) -%}
    {% if not is_valid %}
        {{ exceptions.raise_compiler_error(
            "dbt_tripwire: retention_days must be a positive integer, got '" ~ retention_days ~ "'"
        ) }}
    {% endif %}
    {% if execute %}
        {% do run_query(
            "delete from " ~ dbt_tripwire.sao_run_log_relation() ~
            " where LOGGED_AT < dateadd(day, -" ~ (retention_days | int) ~ ", current_timestamp())"
        ) %}
        {% do run_query(
            "delete from " ~ dbt_tripwire.sao_source_check_log_relation() ~
            " where CHECKED_AT < dateadd(day, -" ~ (retention_days | int) ~ ", current_timestamp())"
        ) %}
    {% endif %}
{% endmacro %}
