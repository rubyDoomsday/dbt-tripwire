{{ config(transient=true) }}

{#- No DEFAULT on CHECKED_AT -- every insert must set it explicitly. -#}
select
    cast(null as varchar) as INVOCATION_ID,
    cast(null as varchar) as SOURCE_ID,
    cast(null as boolean) as SIGNAL_FOUND,
    cast(null as varchar) as CHECKED_TIER,
    cast(null as number(38, 0)) as LAST_CHANGE_COMMIT_TIME,
    cast(null as number) as ROW_COUNT,
    cast(null as variant) as MIN_WATERMARK,
    cast(null as variant) as MAX_WATERMARK,
    cast(null as timestamp_ntz) as CHECKED_AT
where 1 = 0
