{#
    sao_incremental: skip-aware wrapper around the real, completely unmodified
    materialization_incremental_snowflake(). Decision logic is IDENTICAL to
    sao_table's -- Tier 1/2 checks in this design only ever run against
    upstream *source* tables (via sao_check_root_sources / the source-check
    cache), never against a model's own compiled SQL, so there is no
    incremental-predicate-specific logic needed here at all. The only
    difference from sao_table is what happens on the build path: this falls
    through to materialization_incremental_snowflake() instead of
    materialization_table_snowflake().

    The skip check (sao_should_run) is the literal first statement in the
    materialization body -- before load_relation(this) or anything else --
    mirroring sao_table.sql exactly. load_relation(this) is only computed on
    the skip path, where its result (the existing relation to report back to
    dbt unchanged) is actually used; computing it unconditionally would waste
    a metadata lookup on every real-build invocation where it's immediately
    discarded.

    If should_run is true, this checks is_incremental() itself once (see the
    guard below) purely to fail loudly if the required project-level override
    is missing, then falls straight through into
    materialization_incremental_snowflake() -- dbt's real incremental merge
    logic (is_incremental(), unique_key handling, etc.) runs completely
    unmodified; this wrapper never reconstructs or re-derives any part of the
    incremental predicate itself.
#}
{% materialization sao_incremental, adapter='snowflake' %}

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

    {#- Loud guard against the missing is_incremental() override documented in
        the README. If the target table already exists and this isn't a
        full-refresh, is_incremental() MUST return true; if it doesn't, the
        override isn't installed in the consuming project and
        materialization_incremental_snowflake() is about to run an unfiltered
        full-table select straight into the merge, rewriting every
        pre-existing matched row. Fail loudly here instead of silently
        corrupting the table -- this was caught live during POC testing and
        nobody reliably reads the README. -#}
    {%- set existing_relation = load_relation(this) -%}
    {% if existing_relation is not none and existing_relation.type == 'table' and not should_full_refresh() and not is_incremental() %}
        {{ exceptions.raise_compiler_error(
            "dbt_tripwire: is_incremental() returned False for " ~ this ~
            ", but its target table already exists and this is not a --full-refresh run. " ~
            "This almost always means the required is_incremental() override " ~
            "(see dbt_tripwire README, 'Required wiring for sao_incremental') is missing from " ~
            "this project's own macros/ -- proceeding would feed an unfiltered full-table " ~
            "select into the incremental merge and rewrite every existing row."
        ) }}
    {% endif %}

    {{ return(materialization_incremental_snowflake()) }}

{% endmaterialization %}
