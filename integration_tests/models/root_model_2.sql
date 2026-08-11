{{ config(materialized='sao_table', tags=['sao_poc']) }}

-- Shares SAO_POC_SOURCE_A with root_model_1, to prove the per-invocation
-- source-check cache works (source A's Tier 1/2 check should only run once
-- per invocation even though two roots depend on it).
select
    a.ID,
    a.VALUE as A_VALUE,
    null as B_VALUE,
    current_timestamp() as _built_at
from {{ source('sao_poc', 'SAO_POC_SOURCE_A') }} a

union all

select
    b.ID,
    null as A_VALUE,
    b.VALUE as B_VALUE,
    current_timestamp() as _built_at
from {{ source('sao_poc', 'SAO_POC_SOURCE_B') }} b
