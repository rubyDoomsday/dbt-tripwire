{{ config(materialized='view', tags=['sao_poc']) }}

-- Plain view, NOT SAO-managed. Sits between root_model_1 and
-- descendant_model to prove ancestor inheritance cascades correctly
-- through a non-SAO-managed pass-through node.
select
    ID,
    VALUE,
    LOADED_AT,
    _built_at
from {{ ref('root_model_1') }}
