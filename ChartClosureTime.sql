

select
	wk.WEEK_DT
	, dep.DEPARTMENT_ID
	, dep.DEPARTMENT_NAME
	, emp.USER_ID
	, emp.NAME as USER_NAME
	, minfo.DEFINITION_ID
	,'Avg Time (sec) to Closed Enc' METRIC_DEF
	, CAST(wk.SUM_WEEK / wk.SAMPLE_SIZE_WEEK as float) AVG_CLOSE_TIME_SEC
	, CAST(wk.SUM_WEEK / wk.SAMPLE_SIZE_WEEK / 86400 as float) AVG_CLOSE_TIME_DAY
	, case when wk.SUM_WEEK / wk.SAMPLE_SIZE_WEEK / 86400 <= 1 then 1 else 0 end CLOSE_SAME_DAY
	, case when wk.SUM_WEEK / wk.SAMPLE_SIZE_WEEK / 86400 <= 3 then 1 else 0 end CLOSE_THREE_DAY
from METRIC_DATA_SUMMARIES met_sum 
	inner join WEEKLY_DATA wk on wk.SUM_FACTS_ID = met_sum.SUM_FACTS_ID
	left join METRIC_INFO minfo on minfo.DEFINITION_ID = met_sum.DEFINITION_ID
	left join CLARITY_EMP emp on emp.USER_ID = met_sum.TIER2_TARGET_TRANS
	left join CLARITY_DEP dep on dep.DEPARTMENT_ID = met_sum.TIER1_TARGET_TRANS
where met_sum.DEFINITION_ID = 50019 -- Close Patient Office Visits Promptly  https://datahandbook.epic.com/Metrics/Details/2724540
	and wk.WEEK_DT > DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE())-1, 0)
	and met_sum.COMPLD_SUM_LEVEL = '3^5'
