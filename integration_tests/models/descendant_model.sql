{{ config(materialized='sao_table', tags=['sao_poc']) }}

-- SAO-managed, but never directly queries a dbt source. depends_on.nodes
-- only contains passthrough_view (plain view, not SAO-managed). Must prove
-- ancestor inheritance walks through passthrough_view to reach
-- root_model_1's decision.
select
    ID,
    VALUE,
    LOADED_AT,
    _built_at,
    current_timestamp() as _descendant_built_at
from {{ ref('passthrough_view') }}
