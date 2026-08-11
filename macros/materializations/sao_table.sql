{#
    sao_table: skip-aware wrapper around the real, completely unmodified
    materialization_table_snowflake(). The skip check (sao_should_run) is
    the literal first statement in the materialization body -- before
    load_relation(this) or anything else -- mirroring the ordering already
    proven out by run_freshness_skip() on the freshness-model prototype
    branch. load_relation(this) is only computed on the skip path, where its
    result (the existing relation to report back to dbt unchanged) is
    actually used; computing it unconditionally would waste a metadata
    lookup on every real-build invocation where it's immediately discarded.

    If should_run is true, execution falls straight through into
    materialization_table_snowflake() -- no staging table, no swap, so none
    of Snowflake's SWAP WITH gotchas apply here.
#}
{% materialization sao_table, adapter='snowflake' %}

    {%- set decision = dbt_tripwire.sao_should_run() -%}

    {% if not decision.should_run %}
        {{ log("dbt_tripwire: " ~ model.unique_id ~ " skipping rebuild -- reason: " ~ decision.reason, info=True) }}
        {%- set existing_relation = load_relation(this) -%}
        {% call statement('main') %}
            select 'dbt_tripwire: skipped rebuild - ' || '{{ decision.reason }}' as status
        {% endcall %}
        {{ return({'relations': [existing_relation]}) }}
    {% endif %}

    {{ log("dbt_tripwire: " ~ model.unique_id ~ " building -- reason: " ~ decision.reason, info=True) }}
    {{ return(materialization_table_snowflake()) }}

{% endmaterialization %}
