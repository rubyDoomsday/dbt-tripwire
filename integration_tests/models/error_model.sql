{{ config(materialized='sao_table', tags=['sao_poc']) }}

-- SAO-managed, zero source lineage (deterministic no_signal skip once past
-- first_run, same as zero_source_model -- kept independent as its own model
-- so this fixture's SAO_MODEL_STATE row is never touched by anything else).
-- Toggled via `sao_poc_trigger_error` var to reference a table that does not
-- exist, forcing a genuine Snowflake runtime error on the real
-- materialization_table_snowflake() call -- proving the on-run-end
-- four-way branch leaves this model's LAST_RUN_AT/SKIP_COUNT completely
-- untouched on error (only success/pass statuses feed the main MERGE's
-- source query), while its LAST_ERROR_AT gets stamped via the separate
-- error-marking MERGE (only 'error' statuses feed that one).
--
-- Two-invocation manual test for the previous_run_errored retry path:
--   1. `dbt run -s error_model --vars '{sao_poc_trigger_error: true}'` ->
--      errors; SAO_MODEL_STATE.LAST_ERROR_AT gets set, LAST_RUN_AT/SKIP_COUNT
--      untouched.
--   2. `dbt run -s error_model` (var back to default false, no other trigger
--      -- zero source lineage means no_signal on its own) -> should still
--      rebuild, with decision.reason = 'previous_run_errored', proving Tier 0
--      forces the retry regardless of the (irrelevant, here) source
--      baseline. LAST_ERROR_AT is cleared on this successful rebuild.
{% if var('sao_poc_trigger_error', false) %}
select * from {{ target.database }}.{{ target.schema }}.THIS_TABLE_DOES_NOT_EXIST_XYZ
{% else %}
select 1 as ID, current_timestamp() as _built_at
{% endif %}
