{#
    One-time (idempotent) DDL setup for the two synthetic "true dbt source"
    tables backing the diamond fixture. Run via:
        dbt run-operation create_poc_sources
    before the first sao_table run.
#}
{% macro create_poc_sources() %}
    {% do run_query("create schema if not exists " ~ target.database ~ "." ~ target.schema) %}
    {% do run_query(
        "create table if not exists " ~ target.database ~ "." ~ target.schema ~ ".SAO_POC_SOURCE_A (
            ID number, VALUE varchar, LOADED_AT timestamp_ntz
        )"
    ) %}
    {% do run_query(
        "create table if not exists " ~ target.database ~ "." ~ target.schema ~ ".SAO_POC_SOURCE_B (
            ID number, VALUE varchar, LOADED_AT timestamp_ntz
        )"
    ) %}

    {%- set cnt_a = run_query("select count(*) as CNT from " ~ target.database ~ "." ~ target.schema ~ ".SAO_POC_SOURCE_A").rows[0][0] -%}
    {% if cnt_a == 0 %}
        {% do run_query(
            "insert into " ~ target.database ~ "." ~ target.schema ~ ".SAO_POC_SOURCE_A (ID, VALUE, LOADED_AT) " ~
            "values (1, 'seed-a-1', current_timestamp())"
        ) %}
        {{ log("dbt_tripwire poc: seeded SAO_POC_SOURCE_A with 1 row", info=True) }}
    {% endif %}

    {%- set cnt_b = run_query("select count(*) as CNT from " ~ target.database ~ "." ~ target.schema ~ ".SAO_POC_SOURCE_B").rows[0][0] -%}
    {% if cnt_b == 0 %}
        {% do run_query(
            "insert into " ~ target.database ~ "." ~ target.schema ~ ".SAO_POC_SOURCE_B (ID, VALUE, LOADED_AT) " ~
            "values (1, 'seed-b-1', current_timestamp())"
        ) %}
        {{ log("dbt_tripwire poc: seeded SAO_POC_SOURCE_B with 1 row", info=True) }}
    {% endif %}

    {{ log("dbt_tripwire poc: source tables ready", info=True) }}
{% endmacro %}

{#- Convenience: insert a new row into SAO_POC_SOURCE_A, to exercise the
    Tier 1/2 change-signal path (functional check #4). -#}
{% macro insert_poc_source_a_row() %}
    {%- set next_id_result = run_query("select coalesce(max(ID), 0) + 1 as NEXT_ID from " ~ target.database ~ "." ~ target.schema ~ ".SAO_POC_SOURCE_A") -%}
    {%- set next_id = next_id_result.rows[0][0] -%}
    {% do run_query(
        "insert into " ~ target.database ~ "." ~ target.schema ~ ".SAO_POC_SOURCE_A (ID, VALUE, LOADED_AT) " ~
        "values (" ~ next_id ~ ", 'row-" ~ next_id ~ "', current_timestamp())"
    ) %}
    {{ log("dbt_tripwire poc: inserted ID=" ~ next_id ~ " into SAO_POC_SOURCE_A", info=True) }}
{% endmacro %}

{#- Diagnostic: dump all four SAO state/log tables to the dbt log, for manual
    inspection during POC validation. Not part of the package itself. -#}
{% macro inspect_sao_state() %}
    {% set tables = [
        dbt_tripwire.sao_model_state_relation(),
        dbt_tripwire.sao_source_state_relation(),
        dbt_tripwire.sao_run_log_relation(),
        dbt_tripwire.sao_source_check_log_relation()
    ] %}
    {% for rel in tables %}
        {{ log("=== " ~ rel ~ " ===", info=True) }}
        {%- set result = run_query("select * from " ~ rel ~ " order by 1") -%}
        {{ log(result.column_names, info=True) }}
        {% for row in result.rows %}
            {{ log(row.values() | list, info=True) }}
        {% endfor %}
    {% endfor %}
{% endmacro %}

{#- Diagnostic: dump the two synthetic source tables' contents. -#}
{% macro inspect_poc_sources() %}
    {% for tbl in ['SAO_POC_SOURCE_A', 'SAO_POC_SOURCE_B'] %}
        {{ log("=== " ~ tbl ~ " ===", info=True) }}
        {%- set result = run_query("select * from " ~ target.database ~ "." ~ target.schema ~ "." ~ tbl ~ " order by ID") -%}
        {{ log(result.column_names, info=True) }}
        {% for row in result.rows %}
            {{ log(row.values() | list, info=True) }}
        {% endfor %}
    {% endfor %}
{% endmacro %}

{#- Full reset for a clean demonstration run: drops all four SAO state/log
    tables and the two synthetic source tables so the next invocation is a
    genuine "no prior state" bootstrap. Diagnostic only, not part of the
    package itself. -#}
{% macro reset_poc_state() %}
    {% for rel in [
        dbt_tripwire.sao_model_state_relation(),
        dbt_tripwire.sao_source_state_relation(),
        dbt_tripwire.sao_run_log_relation(),
        dbt_tripwire.sao_source_check_log_relation()
    ] %}
        {% do run_query("drop table if exists " ~ rel) %}
        {{ log("dbt_tripwire poc: dropped " ~ rel, info=True) }}
    {% endfor %}
    {% for tbl in ['SAO_POC_SOURCE_A', 'SAO_POC_SOURCE_B'] %}
        {% do run_query("drop table if exists " ~ target.database ~ "." ~ target.schema ~ "." ~ tbl) %}
        {{ log("dbt_tripwire poc: dropped " ~ tbl, info=True) }}
    {% endfor %}
{% endmacro %}

{#- Diagnostic: probe SYSTEM$LAST_CHANGE_COMMIT_TIME() stability across
    repeated calls with no intervening DML, to check for the known Snowflake
    limitation where this function is unreliable for very small tables. -#}
{% macro probe_commit_time() %}
    {% for i in range(4) %}
        {%- set r = run_query("select system$last_change_commit_time('" ~ target.database ~ "." ~ target.schema ~ ".SAO_POC_SOURCE_A') as CT, current_timestamp() as NOW_TS") -%}
        {{ log("probe " ~ i ~ ": CT=" ~ r.rows[0][0] ~ " NOW=" ~ r.rows[0][1], info=True) }}
    {% endfor %}
{% endmacro %}


{#- Diagnostic ONLY: run an arbitrary read-only query and log its rows. -#}
{% macro run_sql(sql) %}
    {%- set result = run_query(sql) -%}
    {{ log(result.column_names, info=True) }}
    {% for row in result.rows %}
        {{ log(row.values() | list, info=True) }}
    {% endfor %}
{% endmacro %}

{#- Diagnostic ONLY: insert a row into SAO_POC_SOURCE_A whose VALUE contains
    a literal single quote, to test that watermark values containing quotes
    don't break the SAO_SOURCE_CHECK_LOG INSERT (regression test for the
    to_variant('...') escaping fix in sao_check_source_uncached). Uses a
    Jinja string literal (not shell/YAML args) to avoid nested-quoting
    pitfalls entirely -- the apostrophe below is a real, single character. -#}
{% macro insert_quote_test_row() %}
    {%- set literal_value = "zzz-quote-test-o'brien" -%}
    {%- set escaped_value = literal_value | replace("'", "''") -%}
    {% do run_query(
        "insert into " ~ target.database ~ "." ~ target.schema ~ ".SAO_POC_SOURCE_A (ID, VALUE, LOADED_AT) " ~
        "select 99, '" ~ escaped_value ~ "', current_timestamp()"
    ) %}
    {{ log("dbt_tripwire poc: inserted quote-containing VALUE = " ~ literal_value, info=True) }}
{% endmacro %}
