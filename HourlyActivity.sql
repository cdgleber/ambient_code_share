SET NOCOUNT ON 
SET ANSI_NULLS ON
SET ANSI_WARNINGS OFF

declare @startdate date = DATEADD(MONTH, DATEDIFF(MONTH, 0, GETDATE())-1, 0) -- use for last month
declare @enddate date = DATEADD(MONTH, DATEDIFF(MONTH, -1, GETDATE())-1, -1) 

--- providers with type, specialty and subspecialty
drop table if exists #provlist
select pvt.PROV_ID
	, ser.PROV_NAME
	, case
		when ser.PROV_TYPE in ('Physician Assistant'
								, 'Nurse Practitioner')
		then 'APP'
		when ser.PROV_TYPE = 'FELLOW'
		then 'Fellow'
		else ser.PROV_TYPE
		end													PROV_TYPE
	, ser.USER_ID
	, emp.SYSTEM_LOGIN										USER_NAME
	, [1]													SPECIALTY
	, coalesce([2], '(None Listed)')						SUBSPECIALTY
into #provlist
from (select PROV_ID, LINE, sp.NAME
		from Clarity..CLARITY_SER_SPEC						spec
			left join Clarity..ZC_SPECIALTY					sp	
				on spec.SPECIALTY_C = sp.SPECIALTY_C
		where LINE in (1, 2))								provspecs
	pivot (max(NAME) for LINE in ([1], [2]))				pvt
	left join Clarity..CLARITY_SER							ser
		on pvt.PROV_ID = ser.PROV_ID
	left join Clarity..CLARITY_EMP							emp
		on ser.USER_ID = emp.USER_ID
where ser.ACTIVE_STATUS_C = 1								-- active
	and ser.REFERRAL_SOURCE_TYPE_C = 1						-- internal

----- pad last 2 months with 0s for providers with no sched time, no EHR time or no WOW
declare @paddates table (PAD_DATE date)
insert into @paddates values (@enddate), (dateadd(MONTH, -1, @enddate))

declare @padactivities table (PAD_ACTIVITY_ID int)
insert into @padactivities values (-999), (-998), (-997)

drop table if exists ##zeropad
select distinct provs.PROV_ID
	, provs.USER_ID
	, dat.PAD_DATE
	, act.PAD_ACTIVITY_ID
into ##zeropad
from @paddates							dat
	cross apply #provlist				provs
	cross apply @padactivities			act

--- base calendar all dates
drop table if exists #calendar
select convert(date, CALENDAR_DT)								BASE_DATE
	, HOUR_OF_DAY_C												BASE_HOUR
	, PROV_ID													BASE_PROV_ID
	, convert(varchar, year(CALENDAR_DT)) + 
		convert(varchar, datepart(wk, CALENDAR_DT))				BASE_WEEK
	, convert(date, WEEK_BEGIN_DT)								WEEK_START
	, convert(date, MONTH_BEGIN_DT)								MONTH_START
into #calendar
from (
	select CALENDAR_DT, WEEK_BEGIN_DT, MONTH_BEGIN_DT											
	from Clarity..DATE_DIMENSION
	where CALENDAR_DT between @startdate and @enddate
	)															datelist
	cross apply
	(
	select HOUR_OF_DAY_C										
	from Clarity..ZC_HOUR_OF_DAY
	)															hourlist
	cross apply #provlist										provlist
	
--- get templated patient scheduled time (excludes held and unavailable time)
drop table if exists #templates
select pr.PROV_ID
	, convert(date, SLOT_BEGIN_TIME)							TEMPLATE_DATE
	, datepart(hour, SLOT_BEGIN_TIME)							TEMPLATE_HOUR
	, convert(varchar, year(SLOT_BEGIN_TIME)) + 
		convert(varchar, datepart(wk, SLOT_BEGIN_TIME))			TEMPLATE_WEEK
	, SLOT_BEGIN_TIME
	, SLOT_LENGTH
	, case when datepart(hour, dateadd(minute, SLOT_LENGTH, SLOT_BEGIN_TIME)) = datepart(hour, SLOT_BEGIN_TIME) then 1
			when datepart(hour, dateadd(minute, SLOT_LENGTH, SLOT_BEGIN_TIME)) = datepart(hour, SLOT_BEGIN_TIME) + 1 and datepart(minute, dateadd(minute, SLOT_LENGTH, SLOT_BEGIN_TIME)) = 0 then 1
			when datepart(hour, dateadd(minute, SLOT_LENGTH, SLOT_BEGIN_TIME)) = datepart(hour, SLOT_BEGIN_TIME) + 1 and datepart(minute, dateadd(minute, SLOT_LENGTH, SLOT_BEGIN_TIME)) > 0 then 0
			end as SLOT_CONTAINED_IN_HOUR
into #templates
from Clarity..AVAILABILITY										av
	inner join #provlist										pr
		on av.PROV_ID = pr.PROV_ID
where APPT_NUMBER = 0											-- availability row
	and DAY_HELD_YN = 'N' and TIME_HELD_YN = 'N'				-- time not held
	and DAY_UNAVAIL_YN = 'N' and TIME_UNAVAIL_YN = 'N'			-- time not unavailable
	and convert(date, SLOT_BEGIN_TIME) 
		between @startdate and @enddate

--- flag weeks with no scheduled patient hours. these weeks, no activity counts.
drop table if exists #weekexclude
select c.BASE_PROV_ID
	, c.BASE_WEEK												WEEK_EXCLUDED
into #weekexclude
from #calendar													c
	left join #templates										t
		on c.BASE_PROV_ID = t.PROV_ID
			and c.BASE_DATE = t.TEMPLATE_DATE
			and c.BASE_HOUR = t.TEMPLATE_HOUR
group by c.BASE_PROV_ID, c.BASE_WEEK
having sum(t.SLOT_LENGTH) is null

--- flag months with scheduled patient hours. if < 16 hours, month excluded
drop table if exists #monthexclude
select c.BASE_PROV_ID
	, c.MONTH_START												MONTH_EXCLUDED
	, coalesce(sum(t.SLOT_LENGTH)/60.0, 0)						MONTHLY_HOURS
into #monthexclude
from #calendar													c
	left join #templates										t
		on c.BASE_PROV_ID = t.PROV_ID
			and c.BASE_DATE = t.TEMPLATE_DATE
			and c.BASE_HOUR = t.TEMPLATE_HOUR
group by c.BASE_PROV_ID, c.MONTH_START
having sum(t.SLOT_LENGTH)/60.0 < 16

--- get scheduled time. distribute slot times over hours (e.g. 40 min slot starting at 8:30 becomes 30 scheduled minutes in hour 8, 10 in hour 9)
drop table if exists #scheduledtime
select s.PROV_ID
	, TEMPLATE_DATE																SCHEDULED_DATE
	, coalesce(hr.HOUR_OF_DAY_C, TEMPLATE_HOUR)									SCHEDULED_HOUR
	, coalesce(sum(case 
		--- slot contained in hour (hour label = start and end hour)
		when hr.HOUR_OF_DAY_C = datepart(hour, SLOT_BEGIN_TIME)					-- hour = slot start hour
			and hr.HOUR_OF_DAY_C = datepart(hour,							-- hour = slot end hour
				dateadd(minute, SLOT_LENGTH, SLOT_BEGIN_TIME))
		then SLOT_LENGTH
		--- slot starts in hour (hour label = start hour)
		when hr.HOUR_OF_DAY_C = datepart(hour, SLOT_BEGIN_TIME)					-- hour = slot start hour
		then datediff(minute,
						SLOT_BEGIN_TIME,
						DATEADD(hour, 
								DATEDIFF(hour, 0, dateadd(hour, 1, SLOT_BEGIN_TIME)), 0)
								)
		--- slot ends in hour (hour label = end hour)
		when hr.HOUR_OF_DAY_C = datepart(hour,							-- hour = slot end hour
				dateadd(minute, SLOT_LENGTH, SLOT_BEGIN_TIME))
		then datediff(minute,
						DATEADD(hour, DATEDIFF(hour, 0, dateadd(minute, SLOT_LENGTH, SLOT_BEGIN_TIME)), 0),
						dateadd(minute, SLOT_LENGTH, SLOT_BEGIN_TIME)
								)
		--- slot spans hour
		when hr.HOUR_OF_DAY_C > datepart(hour, SLOT_BEGIN_TIME)					-- hour after slot start hour
			and hr.HOUR_OF_DAY_C < datepart(hour,							-- hour before slot end hour
				dateadd(minute, SLOT_LENGTH, SLOT_BEGIN_TIME)) 
		then 60
		end), 0)												SCHEDULED_MINUTES_IN_HOUR
into #scheduledtime
from #templates										s
	left join Clarity..ZC_HOUR_OF_DAY				hr
		on hr.HOUR_OF_DAY_C between datepart(hour, SLOT_BEGIN_TIME)
			and datepart(hour, dateadd(minute, SLOT_LENGTH, SLOT_BEGIN_TIME))
group by s.PROV_ID
	, TEMPLATE_DATE
	, coalesce(hr.HOUR_OF_DAY_C, TEMPLATE_HOUR)	

--- get active time. flags inpatient and ed activities. includes activities with workspace undefined as AMB
drop table if exists #activetime
select pr.PROV_ID												ACTIVITY_PROV_ID
	, convert(date, ual.ACTIVITY_HOUR_DTTM)						ACTIVITY_DATE
	, datepart(hour, ual.ACTIVITY_HOUR_DTTM)					ACTIVITY_HOUR
	, coalesce(sum(NUMBER_OF_SECONDS_ACTIVE) / 60.0,0)			ACTIVE_MINUTES_IN_HOUR	
	, case 
		when ual.WORKSPACE_SUBKIND like 'AMB-%'
			or ual.WORKSPACE_SUBKIND like 'TEL-%'
			or ual.WORKSPACE_SUBKIND like 'NONE-%'
			or ual.WORKSPACE_SUBKIND is null
		then 'AMB'
		else 'OTHER'
		end														ACTIVITY_TYPE
into #activetime
from Clarity..UAL_ACTIVITY_HOURS								ual
	inner join Clarity..CLARITY_EMP								emp
		on ual.USER_ID = emp.USER_ID
	inner join #provlist										pr
		on emp.PROV_ID = pr.PROV_ID
where convert(date, ACTIVITY_HOUR_DTTM) between @startdate and @enddate
group by pr.PROV_ID												
	, convert(date, ual.ACTIVITY_HOUR_DTTM)						
	, datepart(hour, ual.ACTIVITY_HOUR_DTTM)
	, case 
		when ual.WORKSPACE_SUBKIND like 'AMB-%'
			or ual.WORKSPACE_SUBKIND like 'TEL-%'
			or ual.WORKSPACE_SUBKIND like 'NONE-%'
			or ual.WORKSPACE_SUBKIND is null
		then 'AMB'
		else 'OTHER'
		end	

--- get times by activity type
drop table if exists #activities
select pr.PROV_ID												ACTIVITY_PROV_ID
	, convert(date, ual.ACTIVITY_HOUR_DTTM)						ACTIVITY_DATE
	, datepart(hour, ual.ACTIVITY_HOUR_DTTM)					ACTIVITY_HOUR
	, ual.ACTIVITY_ID
	, coalesce(sum(NUMBER_OF_SECONDS_ACTIVE) / 60.0,0)			ACTIVE_MINUTES_IN_HOUR	
	, case 
		when ual.WORKSPACE_SUBKIND like 'AMB-%'
			or ual.WORKSPACE_SUBKIND like 'TEL-%'
			or ual.WORKSPACE_SUBKIND like 'NONE-%'
			or ual.WORKSPACE_SUBKIND is null
		then 'AMB'
		else 'OTHER'
		end														ACTIVITY_TYPE
into #activities
from Clarity..UAL_ACTIVITY_HOURS								ual
	inner join Clarity..CLARITY_EMP								emp
		on ual.USER_ID = emp.USER_ID
	inner join #provlist										pr
		on emp.PROV_ID = pr.PROV_ID
where convert(date, ACTIVITY_HOUR_DTTM) between @startdate and @enddate
	--and ual.WORKSPACE_SUBKIND not in ('INP-StandardH', 'ED-StandardH')
group by pr.PROV_ID		
	, convert(date, ual.ACTIVITY_HOUR_DTTM)						
	, datepart(hour, ual.ACTIVITY_HOUR_DTTM)
	, ual.ACTIVITY_ID
	, case 
		when ual.WORKSPACE_SUBKIND like 'AMB-%'
			or ual.WORKSPACE_SUBKIND like 'TEL-%'
			or ual.WORKSPACE_SUBKIND like 'NONE-%'
			or ual.WORKSPACE_SUBKIND is null
		then 'AMB'
		else 'OTHER'
		end	 

--- summarize time: flag hours/days/weeks as clinic y/n
drop table if exists #templatesummary
select s.BASE_PROV_ID
	, s.MONTH_START
	, case
		when mnthexcl.MONTH_EXCLUDED is null
		then 'Y'
		else 'N'
		end														CLINIC_MONTH	
	, s.BASE_WEEK
	, s.WEEK_START
	, case
		when wkexcl.WEEK_EXCLUDED is null
		then 'Y'
		else 'N'
		end														CLINIC_WEEK
	, s.BASE_DATE
	, coalesce(s2.CLINIC_DAY, 'N')								CLINIC_DAY
	, s.BASE_HOUR
	, case 
		when max(s3.SCHEDULED_MINUTES_IN_HOUR) > 0 
		then 'Y' else 'N'
		end														CLINIC_HOUR
into #templatesummary
from #calendar													s
	left join (select PROV_ID
					, SCHEDULED_DATE
					, case 
						when max(SCHEDULED_MINUTES_IN_HOUR) > 0 
						then 'Y' else 'N'
						end										CLINIC_DAY
				from #scheduledtime	
				group by PROV_ID
					, SCHEDULED_DATE )							s2
	on s.BASE_PROV_ID = s2.PROV_ID
		and s.BASE_DATE = s2.SCHEDULED_DATE
	left join #scheduledtime									s3
		on s.BASE_PROV_ID = s3.PROV_ID
			and s.BASE_DATE = s3.SCHEDULED_DATE
			and s.BASE_HOUR = s3.SCHEDULED_HOUR
	left join #weekexclude										wkexcl
		on s.BASE_PROV_ID = wkexcl.BASE_PROV_ID
			and s.BASE_WEEK = wkexcl.WEEK_EXCLUDED
	left join #monthexclude										mnthexcl
		on s.BASE_PROV_ID = mnthexcl.BASE_PROV_ID
			and s.MONTH_START = mnthexcl.MONTH_EXCLUDED
group by s.BASE_PROV_ID
	, s.MONTH_START
	, s.BASE_WEEK
	, s.WEEK_START
	, s.BASE_DATE
	, s2.CLINIC_DAY
	, s.BASE_HOUR
	, wkexcl.WEEK_EXCLUDED
	, mnthexcl.MONTH_EXCLUDED

---- 

drop table if exists ##hourlyactivity
select *
into ##hourlyactivity
from (select PROV_ID											ACTIVITY_PROV_ID
			, SCHEDULED_DATE									ACTIVITY_DATE
			, SCHEDULED_HOUR									ACTIVITY_HOUR
			, -999												ACTIVITY_ID
			, SCHEDULED_MINUTES_IN_HOUR							ACTIVITY_MINUTES
			, 'AMB'												ACTIVITY_TYPE
		from #scheduledtime
		UNION ALL
		---- active EHR time
		select ACTIVITY_PROV_ID
			, ACTIVITY_DATE
			, ACTIVITY_HOUR
			, -998
			, ACTIVE_MINUTES_IN_HOUR
			, ACTIVITY_TYPE
		from #activetime
		UNION ALL
		---- WOW
		select ACTIVITY_PROV_ID
			, ACTIVITY_DATE
			, ACTIVITY_HOUR
			, -997
			, ACTIVE_MINUTES_IN_HOUR
			, ACTIVITY_TYPE
		from #activetime a
			left join #templatesummary ts
				on a.ACTIVITY_PROV_ID = ts.BASE_PROV_ID
					and a.ACTIVITY_DATE = ts.BASE_DATE
					and a.ACTIVITY_HOUR = ts.BASE_HOUR
		where ts.CLINIC_HOUR = 'N'
		UNION ALL
		---- activities
		select * 
		from #activities
		UNION ALL
		select PROV_ID
			, PAD_DATE
			, 12
			, PAD_ACTIVITY_ID
			, 0
			, 'PAD'
		from ##zeropad
	)															hourly
where hourly.ACTIVITY_ID is not null

--------------- ##hourlyactivity becomes Wellbeing..HourlyActivity

select 
    cast(ACTIVITY_PROV_ID as varchar(18)) ACTIVITY_PROV_ID
    , cast(ACTIVITY_DATE as date) ACTIVITY_DATE
    , cast(ACTIVITY_HOUR as int) ACTIVITY_HOUR
    , cast(ACTIVITY_ID as numeric(18,0)) ACTIVITY_ID
    , cast(ACTIVITY_MINUTES as numeric(17,6)) ACTIVITY_MINUTES
    , cast(ACTIVITY_TYPE as varchar(5)) ACTIVITY_TYPE
from ##hourlyactivity 

