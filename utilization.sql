
WITH reads_and_writes AS (
	SELECT db.name AS database_name,
		SUM(user_seeks + user_scans + user_lookups) AS reads,
		SUM(user_updates) AS writes,
		SUM(user_seeks + user_scans + user_lookups + user_updates) AS all_activity
	FROM sys.dm_db_index_usage_stats us
	INNER JOIN sys.databases db ON us.database_id = db.database_id
	GROUP BY db.name)
SELECT database_name, reads, 
		FORMAT(((reads * 1.0) / all_activity),'P')  AS reads_percent,
		writes,
		FORMAT(((writes * 1.0) / all_activity),'P')  AS writes_percent
	FROM reads_and_writes rw
	ORDER BY database_name;

SELECT
CASE instance_name WHEN '' THEN 'Overall' ELSE instance_name END AS NUMA_Node, cntr_value AS [Page life expectancy]
FROM sys.dm_os_performance_counters    
WHERE counter_name = 'Page life expectancy';

SELECT
    db.name AS [DB_Name],
    mfr.physical_name AS Data_file,
    mfl.physical_name AS Log_file,
	mfr.size*8/1024 as [Data_file_size_(MiB)],
	mfr.state_desc as [File_state],
	mfr.growth
FROM sys.databases db
    JOIN sys.master_files mfr ON db.database_id=mfr.database_id AND mfr.type_desc='ROWS'
    JOIN sys.master_files mfl ON db.database_id=mfl.database_id AND mfl.type_desc='LOG'
WHERE db.database_id > 4
ORDER BY mfr.size DESC

SELECT  
[Event_Time] = DATEADD(ms, -1 * (si.cpu_ticks / (si.cpu_ticks/si.ms_ticks) - x.[timestamp]), SYSDATETIMEOFFSET())
,CPU_Util_SQL = bufferxml.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int')
,CPU_Idle = bufferxml.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int')
FROM (SELECT timestamp, CONVERT(xml, record) AS bufferxml
   FROM sys.dm_os_ring_buffers
   WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR') AS x
CROSS APPLY sys.dm_os_sys_info AS si
ORDER BY [Event_Time] desc;

DECLARE @d DateTime
DECLARE @s BigInt
SET @d = (SELECT sqlserver_start_time FROM sys.dm_os_sys_info)
SET @s = (SELECT CAST((DATEDIFF(SECOND, CONVERT(DATE, @d), GETDATE())) AS bigint))
SELECT sysdb.name,sum(sysio.num_of_reads) AS [Total # of Read Ops],
SUM(sysio.num_of_writes) AS [Total # of Write Ops], 
SUM(sysio.num_of_reads)/@s AS [Avg_Read/s],SUM(sysio.num_of_writes)/@s AS [Avg_Writes/s]
FROM sys.dm_io_virtual_file_stats(null,null) as sysio JOIN sys.databases AS sysdb
ON sysio.database_id=sysdb.database_id GROUP BY sysdb.name 
ORDER BY [Total # of Write Ops] DESC


