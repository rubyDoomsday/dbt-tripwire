{{ config(materialized='sao_table', tags=['sao_poc']) }}

-- SAO-managed, but has NO dbt source lineage at all (no ref/source calls).
-- Exercises the zero-source fallback in sao_check_root_sources: this model
-- is a root for every invocation (no ancestor), build_source_check is true,
-- but sao_collect_reachable_sources() returns an empty list for it, so it
-- always reports {'signal_found': false, 'reason': 'no_signal'} -- relies on
-- Tier 0 (first_run / always_build / build_interval_check / max_skips) only,
-- exactly like the 12 real zero-source candidates the design doc calls out.
select 1 as ID, current_timestamp() as _built_at
