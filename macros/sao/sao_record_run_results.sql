{% macro sao_record_run_results(results) %}
    {#- Must stay the literal first check -- keeps this hook's enable/disable
        decision identical to sao_should_run()'s, regardless of how a
        consumer wires the on-run-end hook. -#}
    {% if dbt_tripwire.sao_is_globally_disabled() %}
        {{ return(none) }}
    {% endif %}
    {% if execute and results | length > 0 %}
        {%- set ns = namespace(success_ids=[], errored_ids=[]) -%}
        {% for res in results %}
            {% if res.status in ['success', 'pass'] %}
                {%- do ns.success_ids.append(res.node.unique_id) -%}
            {% elif res.status == 'error' %}
                {%- do ns.errored_ids.append(res.node.unique_id) -%}
            {% endif %}
        {% endfor %}

        {% if ns.success_ids | length > 0 %}
            {%- set select_stmts = [] -%}
            {% for sid in ns.success_ids %}
                {%- do select_stmts.append("select '" ~ sid | replace("'", "''") ~ "' as MODEL_ID") -%}
            {% endfor %}
            {%- set successful_ids_cte = select_stmts | join(' union all ') -%}

            {%- set merge_sql -%}
                merge into {{ dbt_tripwire.sao_model_state_relation() }} as tgt
                using (
                    select s.MODEL_ID as MODEL_ID, rl.SHOULD_RUN as SHOULD_RUN
                    from ( {{ successful_ids_cte }} ) s
                    inner join {{ dbt_tripwire.sao_run_log_relation() }} rl
                        on rl.MODEL_ID = s.MODEL_ID
                       and rl.INVOCATION_ID = '{{ invocation_id }}'
                ) as src
                on tgt.MODEL_ID = src.MODEL_ID
                when matched and src.SHOULD_RUN then update set
                    LAST_RUN_AT = current_timestamp(),
                    SKIP_COUNT = 0,
                    LAST_ERROR_AT = null
                when matched and not src.SHOULD_RUN then update set
                    SKIP_COUNT = tgt.SKIP_COUNT + 1
                when not matched and src.SHOULD_RUN then insert
                    (MODEL_ID, LAST_RUN_AT, SKIP_COUNT) values (src.MODEL_ID, current_timestamp(), 0)
                when not matched and not src.SHOULD_RUN then insert
                    (MODEL_ID, LAST_RUN_AT, SKIP_COUNT) values (src.MODEL_ID, null, 1)
            {%- endset -%}
            {% do run_query(merge_sql) %}
        {% endif %}

        {% if ns.errored_ids | length > 0 %}
            {%- set error_select_stmts = [] -%}
            {% for eid in ns.errored_ids %}
                {%- do error_select_stmts.append("select '" ~ eid | replace("'", "''") ~ "' as MODEL_ID") -%}
            {% endfor %}
            {%- set errored_ids_cte = error_select_stmts | join(' union all ') -%}

            {%- set error_merge_sql -%}
                merge into {{ dbt_tripwire.sao_model_state_relation() }} as tgt
                using (
                    select s.MODEL_ID as MODEL_ID
                    from ( {{ errored_ids_cte }} ) s
                    inner join {{ dbt_tripwire.sao_run_log_relation() }} rl
                        on rl.MODEL_ID = s.MODEL_ID
                       and rl.INVOCATION_ID = '{{ invocation_id }}'
                ) as src
                on tgt.MODEL_ID = src.MODEL_ID
                when matched then update set
                    LAST_ERROR_AT = current_timestamp()
                when not matched then insert
                    (MODEL_ID, LAST_RUN_AT, SKIP_COUNT, LAST_ERROR_AT)
                    values (src.MODEL_ID, null, 0, current_timestamp())
            {%- endset -%}
            {% do run_query(error_merge_sql) %}
        {% endif %}

        {#- SAO_SOURCE_STATE: batch-merge whatever fresh Tier 1/2 values were
            computed into SAO_SOURCE_CHECK_LOG this invocation, regardless of
            which models' decisions those checks fed. #}
        {%- set source_merge_sql -%}
            merge into {{ dbt_tripwire.sao_source_state_relation() }} as tgt
            using (
                select SOURCE_ID, LAST_CHANGE_COMMIT_TIME, ROW_COUNT, MIN_WATERMARK, MAX_WATERMARK, CHECKED_AT
                from {{ dbt_tripwire.sao_source_check_log_relation() }}
                where INVOCATION_ID = '{{ invocation_id }}'
                qualify row_number() over (partition by SOURCE_ID order by CHECKED_AT desc) = 1
            ) as src
            on tgt.SOURCE_ID = src.SOURCE_ID
            when matched then update set
                LAST_CHANGE_COMMIT_TIME = coalesce(src.LAST_CHANGE_COMMIT_TIME, tgt.LAST_CHANGE_COMMIT_TIME),
                ROW_COUNT = coalesce(src.ROW_COUNT, tgt.ROW_COUNT),
                MIN_WATERMARK = coalesce(src.MIN_WATERMARK, tgt.MIN_WATERMARK),
                MAX_WATERMARK = coalesce(src.MAX_WATERMARK, tgt.MAX_WATERMARK),
                LAST_CHECKED_AT = src.CHECKED_AT
            when not matched then insert
                (SOURCE_ID, LAST_CHANGE_COMMIT_TIME, ROW_COUNT, MIN_WATERMARK, MAX_WATERMARK, LAST_CHECKED_AT)
                values (src.SOURCE_ID, src.LAST_CHANGE_COMMIT_TIME, src.ROW_COUNT, src.MIN_WATERMARK, src.MAX_WATERMARK, src.CHECKED_AT)
        {%- endset -%}
        {%- set check_count = run_query(
            "select count(*) from " ~ dbt_tripwire.sao_source_check_log_relation() ~
            " where INVOCATION_ID = '" ~ invocation_id ~ "'"
        ).rows[0][0] -%}
        {% if check_count > 0 %}
            {% do run_query(source_merge_sql) %}
        {% endif %}
    {% endif %}
{% endmacro %}
