{{ config(materialized='sao_table', tags=['sao_poc']) }}

-- SAO-managed, refs BOTH a qualifying SAO ancestor (root_model_1, via
-- SAO_POC_SOURCE_A) AND a raw source directly (SAO_POC_SOURCE_B). Proves the
-- fix for the ancestor-inheritance blind spot: previously, once root_model_1
-- qualified as an in-selection SAO-managed ancestor, this model inherited
-- its should_run decision alone and never checked its own sources -- a
-- change on SAO_POC_SOURCE_B alone (with root_model_1 otherwise not
-- rebuilding) would have gone unnoticed until the interval elapsed.
-- sao_should_run() now ORs ancestor.should_run with this model's own
-- sao_check_root_sources() result (which walks ALL of this model's
-- reachable sources, both root_model_1's SOURCE_A transitively and this
-- model's own direct SOURCE_B), so a signal on either one forces a rebuild.
select
    a.ID,
    a.VALUE as A_VALUE,
    b.VALUE as B_VALUE,
    current_timestamp() as _built_at
from {{ ref('root_model_1') }} a
inner join {{ source('sao_poc', 'SAO_POC_SOURCE_B') }} b
    on a.ID = b.ID
