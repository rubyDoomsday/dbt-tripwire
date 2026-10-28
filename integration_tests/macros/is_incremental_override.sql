{#
    REQUIRED WIRING for any project consuming dbt_tripwire's sao_incremental
    materialization -- same category of requirement as the on-run-end hook
    documented in the package README.

    dbt-core's built-in is_incremental() (dbt/include/global_project/macros/
    materializations/models/incremental/is_incremental.sql) hardcodes:
        model.config.materialized == 'incremental'
    That string comparison is never true for a model materialized as
    'sao_incremental', so any model using the standard
    `{% if is_incremental() %}` pattern in its own SQL would otherwise always
    see it evaluate False -- even once the target table already exists --
    silently turning every "real build" into an unfiltered full-table scan
    fed into the merge, rather than a genuine incremental slice. Discovered
    live during POC testing: incremental_model's pre-existing rows were
    getting rewritten (fresh _incremental_built_at) on every rebuild, not
    just newly-added ones, because the model's own watermark WHERE clause
    was silently never applied.

    dbt's macro resolution for an unqualified call made from a model in the
    ROOT project (like incremental_model.sql here) checks the root project's
    own macros before falling back to dbt-core's built-in -- it does NOT
    pick up a same-named override defined inside an installed package's own
    macros/ directory (that would only apply to unqualified calls made from
    within the package's own files). So this override has to live here, in
    the consuming project, not in dbt_tripwire/macros/.

    Rather than freeze a copy of dbt-core's implementation (which would
    silently drift out of sync with whatever dbt-core version this project
    has installed on every dbt-core upgrade), this only special-cases
    'sao_incremental' and falls through to dbt-core's real is_incremental()
    for every other materialization, via the `dbt.` global-project
    namespace (dbt namespaces its own built-in macros under the literal
    package name `dbt`).
-#}
{% macro is_incremental() %}
    {% if model.config.materialized == 'sao_incremental' %}
        {% if not execute %}
            {{ return(False) }}
        {% else %}
            {% set relation = adapter.get_relation(this.database, this.schema, this.table) %}
            {{ return(relation is not none
                      and relation.type == 'table'
                      and not should_full_refresh()) }}
        {% endif %}
    {% else %}
        {{ return(dbt.is_incremental()) }}
    {% endif %}
{% endmacro %}
