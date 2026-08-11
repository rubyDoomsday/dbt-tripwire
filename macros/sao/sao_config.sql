{#
    meta.sao config resolution + defaults. Note the config-merge caveat from
    the design doc: dbt's `meta` merge across project/model config is shallow,
    so a model-level meta.sao block fully replaces a project-level one rather
    than merging key by key. Document prominently in the package README.
#}
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

{#- Config for the CURRENT model being materialized (uses the `config` global,
    same mechanism proven out on the freshness-model prototype branch). -#}
{% macro sao_get_current_model_config() %}
    {%- set sao_meta = config.get('meta', {}).get('sao', {}) -%}
    {{ return(dbt_tripwire.sao_apply_config_defaults(sao_meta)) }}
{% endmacro %}

{#-
    Validate + normalize an interval unit string against an allowlist, mapped
    to the exact Snowflake DATEADD token. Never interpolate an unvalidated
    unit string into SQL.
-#}
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

{#-
    Validate build_after_interval_value before it's ever interpolated into
    SQL. Unlike build_after_interval_unit (an enum, allowlisted above),
    the value is a bare number spliced directly into `dateadd(unit, value,
    LAST_RUN_AT)` -- it must be a positive integer, not just "anything that
    happens to render". Rejects floats, zero, negatives, and non-numeric
    values with a clear compiler error rather than letting a bad config
    silently produce broken or nonsensical SQL (or, worse, a value an
    attacker-controlled var could turn into SQL injection).
-#}
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

{#-
    Validate a bare SQL identifier before it's ever interpolated directly into
    SQL (unquoted, not passed as a bind param). Currently used for
    meta.sao_watermark_col (sao_source_check.sql) -- unlike
    build_after_interval_unit, that value previously went straight into a
    `min(...)`/`max(...)` expression with no allowlist at all.
-#}
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
    {{ return((var('sao_disable', env_var('DBT_SAO_DISABLE', 'false')) | string | lower) == 'true') }}
{% endmacro %}

{% macro sao_is_sao_managed_materialization(materialized) %}
    {{ return(materialized in ['sao_table', 'sao_incremental']) }}
{% endmacro %}
