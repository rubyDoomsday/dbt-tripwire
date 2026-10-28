{{ config(transient=true) }}

{#- No DEFAULT on LOGGED_AT -- every insert must set it explicitly. -#}
select
    cast(null as varchar) as INVOCATION_ID,
    cast(null as varchar) as MODEL_ID,
    cast(null as boolean) as SHOULD_RUN,
    cast(null as varchar) as REASON,
    cast(null as timestamp_ntz) as LOGGED_AT
where 1 = 0
