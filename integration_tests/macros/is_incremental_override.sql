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

    This is a straight copy of dbt-core's is_incremental() with the single
    line changed to also accept 'sao_incremental'.
-#}
{% macro is_incremental() %}
    {% if not execute %}
        {{ return(False) }}
    {% else %}
        {% set relation = adapter.get_relation(this.database, this.schema, this.table) %}
        {{ return(relation is not none
                  and relation.type == 'table'
                  and model.config.materialized in ['incremental', 'sao_incremental']
                  and not should_full_refresh()) }}
    {% endif %}
{% endmacro %}
