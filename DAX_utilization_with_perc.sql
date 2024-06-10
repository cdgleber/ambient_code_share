

select
	enc.VISIT_PROV_ID
	, ser.PROV_NAME
	, convert(date, DATEADD(DAY, 1-DATEPART(WEEKDAY, enc.EFFECTIVE_DATE_DT), enc.EFFECTIVE_DATE_DT)) WEEK_START --returns the Sunday of that week
	, count(distinct amb.PAT_ENC_CSN_ID) TOTAL_AMB_ENCOUNTERS
	, count(distinct enc.PAT_ENC_CSN_ID) TOTAL_ENCOUNTERS
	, count(distinct amb.PAT_ENC_CSN_ID)*1.0 / count(distinct enc.PAT_ENC_CSN_ID)*1.0 PERC
from PAT_ENC enc
	left join PAT_ENC_AMBIENT_SESSIONS amb on enc.PAT_ENC_CSN_ID = amb.PAT_ENC_CSN_ID
	left join CLARITY_SER ser on ser.PROV_ID = enc.VISIT_PROV_ID
where enc.EFFECTIVE_DATE_DT >= '2024-03-05' -- START OF DAX PILOT
	and enc.ENC_TYPE_C in ('101','2562','2561') --SPECIFIC ENCOUNTER TYPES TO CONSIDER
group by enc.VISIT_PROV_ID, ser.PROV_NAME, convert(date, DATEADD(DAY, 1-DATEPART(WEEKDAY, enc.EFFECTIVE_DATE_DT), enc.EFFECTIVE_DATE_DT))
having count(distinct amb.PAT_ENC_CSN_ID) > 0
order by count(distinct amb.PAT_ENC_CSN_ID)*1.0 / count(distinct enc.PAT_ENC_CSN_ID)*1.0 desc

