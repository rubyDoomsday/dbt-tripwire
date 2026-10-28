{{ config(transient=false) }}

select
    cast(null as varchar) as MODEL_ID,
    cast(null as timestamp_ntz) as LAST_RUN_AT,
    cast(null as number) as SKIP_COUNT,
    cast(null as timestamp_ntz) as LAST_ERROR_AT
where 1 = 0
