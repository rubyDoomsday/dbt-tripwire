{{
    config(
        materialized='sao_table',
        tags=['sao_poc'],
        meta={
            'sao': {
                'always_build': false,
                'build_interval_check': false,
                'build_source_check': false,
                'max_skips': 2
            }
        }
    )
}}

-- SAO-managed, with build_interval_check and build_source_check both
-- disabled -- the ONLY things that can ever trigger a rebuild after the
-- first run are Tier 0's first_run and max_skips_exceeded checks. This
-- isolates max_skips from the source-signal machinery (and its Snowflake
-- SYSTEM$LAST_CHANGE_COMMIT_TIME timing quirks) entirely, so a forced
-- rebuild at SKIP_COUNT=2 can only be explained by max_skips firing.
-- Reads from a real source anyway (proving build_source_check: false really
-- does suppress the source-tier check for an otherwise-real root, per the
-- design doc, rather than this being conflated with the zero-source case).
select
    a.ID,
    a.VALUE,
    current_timestamp() as _built_at
from {{ source('sao_poc', 'SAO_POC_SOURCE_A') }} a
