{{ config(materialized='sao_table', tags=['sao_poc']) }}

select
    a.ID,
    a.VALUE,
    a.LOADED_AT,
    current_timestamp() as _built_at
from {{ source('sao_poc', 'SAO_POC_SOURCE_A') }} a
