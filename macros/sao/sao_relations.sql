{#
    Relation helpers for the package's own state/log tables, plus idempotent
    table creation. All four tables live in the current target's database/schema
    for this POC. Production impl should isolate these into a dedicated
    package-owned schema (see design doc "Persistence" section) -- out of
    scope for the POC, where the integration_tests project already runs in
    its own isolated schema (WS_RCHAPIN_SAO_POC).
#}

{% macro sao_model_state_relation() %}
    {{ return(api.Relation.create(database=target.database, schema=target.schema, identifier='SAO_MODEL_STATE')) }}
{% endmacro %}

{% macro sao_source_state_relation() %}
    {{ return(api.Relation.create(database=target.database, schema=target.schema, identifier='SAO_SOURCE_STATE')) }}
{% endmacro %}

{% macro sao_run_log_relation() %}
    {{ return(api.Relation.create(database=target.database, schema=target.schema, identifier='SAO_RUN_LOG')) }}
{% endmacro %}

{% macro sao_source_check_log_relation() %}
    {{ return(api.Relation.create(database=target.database, schema=target.schema, identifier='SAO_SOURCE_CHECK_LOG')) }}
{% endmacro %}

{#
    Idempotent CREATE TABLE IF NOT EXISTS for all four SAO tables. Each call is
    cheap (metadata-only op in Snowflake when the table already exists), but
    with hundreds of sao_table candidates in one invocation, four round-trip
    DDL statements per model adds up to real, pointless overhead once the
    tables already exist for this run. sao_ensure_state_tables_once() below
    is the one that should actually be called from sao_should_run() --
    it runs the real DDL only the first time any model needs it this
    invocation, then every other model's call is a single in-memory dict
    lookup (no Snowflake round trip at all).
#}
{% macro sao_ensure_state_tables() %}
    {#- LAST_ERROR_AT is set whenever a model's real materialization errors after
        should_run evaluated true, and cleared the next time it actually rebuilds
        successfully. It never affects LAST_RUN_AT/SKIP_COUNT -- an errored run is
        still never counted as a legitimate skip -- but it forces Tier 0 to fire
        unconditionally on this model's very next invocation, regardless of what
        the (shared, source-level) Tier 1/2 baseline looks like. Without this, a
        model whose build erroneously fails right after a real source signal
        fired would see SAO_SOURCE_STATE's baseline already advanced to reflect
        that signal on its next run (the source-state merge is intentionally
        unconditional -- it tracks the source's own reality, not any one
        consuming model's outcome), compare against it, find no further diff, and
        silently stay skipped until either the source changes again or the
        interval elapses. -#}
    {% do run_query(
        "create table if not exists " ~ dbt_tripwire.sao_model_state_relation() ~ " (
            MODEL_ID varchar,
            LAST_RUN_AT timestamp_ntz,
            SKIP_COUNT number default 0,
            LAST_ERROR_AT timestamp_ntz
        )"
    ) %}

    {#- LAST_CHANGE_COMMIT_TIME is stored as the raw NUMBER(38,0) nanosecond-epoch
        value returned by SYSTEM$LAST_CHANGE_COMMIT_TIME() -- deliberately NOT cast
        to a timestamp type. Casting it loses precision (the function returns
        nanoseconds; TIMESTAMP_NTZ collapses to microseconds) which broke
        equality comparisons against a freshly-queried raw value during POC
        testing: a cast-then-reread baseline never compared equal to a fresh
        raw integer, producing a permanent false "changed" signal every run.
        Comparing the untouched raw value on both sides is the only correct
        approach. -#}
    {% do run_query(
        "create table if not exists " ~ dbt_tripwire.sao_source_state_relation() ~ " (
            SOURCE_ID varchar,
            LAST_CHANGE_COMMIT_TIME number(38,0),
            ROW_COUNT number,
            MIN_WATERMARK variant,
            MAX_WATERMARK variant,
            LAST_CHECKED_AT timestamp_ntz
        )"
    ) %}

    {#- transient: these are pure per-invocation caches, never read across
        invocations by design (unlike SAO_MODEL_STATE/SAO_SOURCE_STATE above) --
        no fail-safe/time-travel storage needed. Matches the README's existing
        description of these two tables as transient; the DDL previously didn't. -#}
    {% do run_query(
        "create transient table if not exists " ~ dbt_tripwire.sao_run_log_relation() ~ " (
            INVOCATION_ID varchar,
            MODEL_ID varchar,
            SHOULD_RUN boolean,
            REASON varchar,
            LOGGED_AT timestamp_ntz default current_timestamp()
        )"
    ) %}

    {% do run_query(
        "create transient table if not exists " ~ dbt_tripwire.sao_source_check_log_relation() ~ " (
            INVOCATION_ID varchar,
            SOURCE_ID varchar,
            SIGNAL_FOUND boolean,
            CHECKED_TIER varchar,
            LAST_CHANGE_COMMIT_TIME number(38,0),
            ROW_COUNT number,
            MIN_WATERMARK variant,
            MAX_WATERMARK variant,
            CHECKED_AT timestamp_ntz default current_timestamp()
        )"
    ) %}
{% endmacro %}

{#-
    Run sao_ensure_state_tables() at most once per dbt invocation. dbt
    materialization macros for every sao_table node in a run execute in the
    same Python/Jinja process, sharing the same `graph` context object
    (Manifest.flat_graph, memoized on the Manifest instance for the whole
    invocation -- verified empirically: a custom key written onto `graph`
    from one model's materialization is visible from another model's
    materialization later in the same invocation, including across
    dbt's default multi-threaded execution). That makes `graph` a safe,
    already-shared place to stash a plain "have we done this yet" flag,
    without needing any extra Snowflake round trip to check it.

    Note: `graph.__setitem__(...)` is blocked by dbt's sandboxed Jinja
    environment ("access to attribute '__setitem__' of 'dict' object is
    unsafe") -- use the public `.update()` method instead, which the
    sandbox allows.

    Two threads racing to be the first to check this flag in the same
    moment could both see it unset and both run the DDL once each --
    harmless (CREATE TABLE IF NOT EXISTS is idempotent), same tolerance
    the design doc already grants the source-check cache for an
    analogous race.
-#}
{% macro sao_ensure_state_tables_once() %}
    {%- set flag_key = '_sao_state_tables_ensured' -%}
    {% if graph.get(flag_key) is none %}
        {% do dbt_tripwire.sao_ensure_state_tables() %}
        {% do graph.update({flag_key: true}) %}
    {% endif %}
{% endmacro %}

{#-
    SAO_RUN_LOG and SAO_SOURCE_CHECK_LOG are append-only inserts with no
    built-in retention -- at 331 candidates times N runs/day, that's an
    unbounded, slow-motion storage bill. Not wired into any hook (a package
    can't schedule its own maintenance job), so a consuming project must
    invoke this deliberately, e.g. `dbt run-operation sao_purge_transient_logs
    --args '{retention_days: 30}'` on its own periodic schedule.
-#}
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
