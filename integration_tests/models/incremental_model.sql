{{ config(materialized='sao_incremental', unique_key='ID', tags=['sao_poc']) }}

-- SAO-managed, sao_incremental. Real incremental merge on unique_key=ID,
-- watermark-filtered via LOADED_AT so that, once past the first full build,
-- only genuinely new/changed rows from SAO_POC_SOURCE_A are ever re-scanned
-- and merged -- proving sao_incremental delegates real incremental behavior
-- to the unmodified materialization_incremental_snowflake(), not a full
-- table replace. _incremental_built_at lets us prove, row by row, whether a
-- given row was (re)processed by a given invocation: unchanged rows keep
-- their old timestamp; only newly-merged rows get a fresh one.
select
    a.ID,
    a.VALUE,
    a.LOADED_AT,
    current_timestamp() as _incremental_built_at
from {{ source('sao_poc', 'SAO_POC_SOURCE_A') }} a
{% if is_incremental() %}
where a.LOADED_AT > (select coalesce(max(LOADED_AT), '1900-01-01'::timestamp_ntz) from {{ this }})
{% endif %}
