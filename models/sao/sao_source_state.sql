{{ config(transient=false) }}

select
    cast(null as varchar) as SOURCE_ID,
    cast(null as number(38, 0)) as LAST_CHANGE_COMMIT_TIME,
    cast(null as number) as ROW_COUNT,
    cast(null as variant) as MIN_WATERMARK,
    cast(null as variant) as MAX_WATERMARK,
    cast(null as timestamp_ntz) as LAST_CHECKED_AT
where 1 = 0
