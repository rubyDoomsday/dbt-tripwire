{% macro sao_config_defaults() %}
    {{ return({
        'always_build': false,
        'build_interval_check': true,
        'build_after_interval_value': 1,
        'build_after_interval_unit': 'hour',
        'build_source_check': true,
        'max_skips': none,
    }) }}
{% endmacro %}

{% macro sao_apply_config_defaults(sao_meta) %}
    {%- set merged = dbt_tripwire.sao_config_defaults() -%}
    {%- do merged.update(sao_meta or {}) -%}
    {{ return(merged) }}
{% endmacro %}

{% macro sao_get_current_model_config() %}
    {%- set sao_meta = config.get('meta', {}).get('sao', {}) -%}
    {{ return(dbt_tripwire.sao_apply_config_defaults(sao_meta)) }}
{% endmacro %}

{#- Never interpolate an unvalidated unit string into SQL. -#}
{% macro sao_normalize_interval_unit(unit) %}
    {%- set u = (unit | string | lower) -%}
    {%- set mapping = {
        'hour': 'hour', 'hours': 'hour', 'h': 'hour',
        'minute': 'minute', 'minutes': 'minute', 'min': 'minute',
        'day': 'day', 'days': 'day', 'd': 'day',
    } -%}
    {% if u not in mapping %}
        {{ exceptions.raise_compiler_error(
            "dbt_tripwire: invalid build_after_interval_unit '" ~ unit ~
            "' -- must be one of: " ~ (mapping.keys() | list | join(', '))
        ) }}
    {% endif %}
    {{ return(mapping[u]) }}
{% endmacro %}

{#- Bare number spliced directly into SQL -- never skip this validation. -#}
{% macro sao_validate_interval_value(value) %}
    {%- set is_valid_int = (value is number and value == (value | int) and value > 0) -%}
    {% if not is_valid_int %}
        {{ exceptions.raise_compiler_error(
            "dbt_tripwire: invalid build_after_interval_value '" ~ value ~
            "' -- must be a positive integer"
        ) }}
    {% endif %}
    {{ return(value | int) }}
{% endmacro %}

{#- Interpolated unquoted into SQL -- never skip this validation. -#}
{% macro sao_validate_identifier(value, context_label) %}
    {%- set v = (value | string) -%}
    {% if not modules.re.match('^[A-Za-z_][A-Za-z0-9_$]*$', v) %}
        {{ exceptions.raise_compiler_error(
            "dbt_tripwire: invalid " ~ context_label ~ " '" ~ value ~
            "' -- must be a valid unquoted SQL identifier (letters, digits, underscore, $, not starting with a digit)"
        ) }}
    {% endif %}
    {{ return(v) }}
{% endmacro %}

{% macro sao_is_globally_disabled() %}
    {#- Never set sao_enable/sao_disable in vars:, even to false -- permanently
        shadows the env var. force_disabled takes priority over enabled. -#}
    {%- set enabled = (var('sao_enable', env_var('DBT_ENABLE_SAO', 'false')) | string | lower) == 'true' -%}
    {%- set force_disabled = (var('sao_disable', env_var('DBT_SAO_DISABLE', 'false')) | string | lower) == 'true' -%}
    {{ return((not enabled) or force_disabled) }}
{% endmacro %}

{% macro sao_is_sao_managed_materialization(materialized) %}
    {{ return(materialized in ['sao_table', 'sao_incremental']) }}
{% endmacro %}
