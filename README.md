# SQL Server performance related queries
----
## SQL Server Read / Write operations
```
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
```

## SQL Memory Stats

### SQL Server memory utilization
```
SELECT
sqlserver_start_time,
(committed_kb/1024) AS Total_Server_Memory_MB,
(committed_target_kb/1024)  AS Target_Server_Memory_MB
FROM sys.dm_os_sys_info;
```

### SQL Server current memory allocation

```
SELECT
(total_physical_memory_kb/1024) AS Total_OS_Memory_MB,
(available_physical_memory_kb/1024)  AS Available_OS_Memory_MB
FROM sys.dm_os_sys_memory;

SELECT  
(physical_memory_in_use_kb/1024) AS Memory_used_by_Sqlserver_MB,  
(locked_page_allocations_kb/1024) AS Locked_pages_used_by_Sqlserver_MB,  
(total_virtual_address_space_kb/1024) AS Total_VAS_in_MB,
process_physical_memory_low,  
process_virtual_memory_low  
FROM sys.dm_os_process_memory;
```

### SQL Server page life expectancy

```
SELECT
CASE instance_name WHEN '' THEN 'Overall' ELSE instance_name END AS NUMA_Node, cntr_value AS [Page life expectancy]
FROM sys.dm_os_performance_counters    
WHERE counter_name = 'Page life expectancy';
```

### SQL Server Page Splits (Troubleshooting)

Samples Page splits in a 10-second slot
```
/*
Only using the counter_name “Page Splits/sec”(DMV) is misleading, because the metric returns an incrementing value.
*/
DECLARE @ps_Start_ms bigint, @ps_Start bigint
, @ps_End_ms bigint, @ps_End bigint;
SELECT @ps_Start_ms = ms_ticks
, @ps_Start = cntr_value
FROM sys.dm_os_sys_info CROSS APPLY 
sys.dm_os_performance_counters
WHERE counter_name ='Page Splits/sec'
AND object_name LIKE '%SQL%Access Methods %';
WAITFOR DELAY '00:00:05'; --Sample 10 seconds - change as you will.
SELECT @ps_End_ms = MAX(ms_ticks), 
@ps_End = MAX(cntr_value)
FROM sys.dm_os_sys_info CROSS APPLY
sys.dm_os_performance_counters
WHERE counter_name ='Page Splits/sec'
AND object_name LIKE '%SQL%Access Methods%'; 
SELECT Time_Observed = SYSDATETIMEOFFSET(), Page_Splits_per_s = convert(decimal(19,3), 
(@ps_End - @ps_Start)*1.0/ NULLIF(@ps_End_ms - @ps_Start_ms,0)); 

```


## SQL Server disk setup
Use file_layout.sql script above instead.
```
EXEC sp_MSforeachdb 'USE ? SELECT ''?'', SF.filename, SF.size FROM sys.sysfiles SF'

```

## SQL CPU stats

### Top 10 queries by CPU consumption (Troubleshooting)
```
SELECT TOP 10 query_stats.query_hash AS "Query Hash",   
    SUM(query_stats.total_worker_time) / SUM(query_stats.execution_count) AS "Avg CPU Time",  
    MIN(query_stats.statement_text) AS "Statement Text"  
FROM   
    (SELECT QS.*,   
    SUBSTRING(ST.text, (QS.statement_start_offset/2) + 1,  
    ((CASE statement_end_offset   
        WHEN -1 THEN DATALENGTH(ST.text)  
        ELSE QS.statement_end_offset END   
            - QS.statement_start_offset)/2) + 1) AS statement_text  
     FROM sys.dm_exec_query_stats AS QS  
     CROSS APPLY sys.dm_exec_sql_text(QS.sql_handle) as ST) as query_stats  
GROUP BY query_stats.query_hash  
ORDER BY 2 DESC;
```

### CPU consumption per query plan (Troubleshooting)
```
SELECT plan_handle,
      SUM(total_worker_time) AS [Total CPU worker time in millisecond], 
      SUM(execution_count) AS [Total execution count],
      COUNT(*) AS [Number of statements that uses this query plan],
	  SUM(total_worker_time)/SUM(execution_count) AS Avg_workertime,
	  SUM(total_spills) AS Total_spills
FROM sys.dm_exec_query_stats
GROUP BY plan_handle
ORDER BY avg_workertime DESC
```

## Total number of rows returned by queries
```
SELECT qs.execution_count,  
    SUBSTRING(qt.text,qs.statement_start_offset/2 +1,   
                 (CASE WHEN qs.statement_end_offset = -1   
                       THEN LEN(CONVERT(nvarchar(max), qt.text)) * 2   
                       ELSE qs.statement_end_offset end -  
                            qs.statement_start_offset  
                 )/2  
             ) AS query_text,   
     qt.dbid, dbname= DB_NAME (qt.dbid), qt.objectid,   
     qs.total_rows, qs.last_rows, qs.min_rows, qs.max_rows  
FROM sys.dm_exec_query_stats AS qs   
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt   
WHERE qt.text like '%SELECT%'   
ORDER BY qs.execution_count DESC;
```

## Unused Indexes for a given database
```
SELECT
    objects.name AS Table_name,
    indexes.name AS Index_name,
    dm_db_index_usage_stats.user_seeks,
    dm_db_index_usage_stats.user_scans,
    dm_db_index_usage_stats.user_updates
FROM
    sys.dm_db_index_usage_stats
    INNER JOIN sys.objects ON dm_db_index_usage_stats.OBJECT_ID = objects.OBJECT_ID
    INNER JOIN sys.indexes ON indexes.index_id = dm_db_index_usage_stats.index_id AND dm_db_index_usage_stats.OBJECT_ID = indexes.OBJECT_ID
WHERE
    indexes.is_primary_key = 0 
    AND
    indexes. is_unique = 0 
    AND 
    dm_db_index_usage_stats.user_updates <> 0 
    AND
    dm_db_index_usage_stats. user_lookups = 0
    AND
    dm_db_index_usage_stats.user_seeks = 0
    AND
    dm_db_index_usage_stats.user_scans = 0
ORDER BY
    dm_db_index_usage_stats.user_updates DESC
```

## Storage space used by table for a given database (Troubleshooting)
```
SELECT 
    t.NAME AS TableName,
    i.name as IndexName,
    sum(p.rows) as RowCounts,
    sum(a.total_pages) as TotalPages, 
    sum(a.used_pages) as UsedPages, 
    sum(a.data_pages) as DataPages,
    (sum(a.total_pages) * 8) / 1024 as [TotalSpace(MB)], 
    (sum(a.used_pages) * 8) / 1024 as [UsedSpace(MB)], 
    (sum(a.data_pages) * 8) / 1024 as [DataPages(MB)]
FROM 
    sys.tables t
INNER JOIN      
    sys.indexes i ON t.OBJECT_ID = i.object_id
INNER JOIN 
    sys.partitions p ON i.object_id = p.OBJECT_ID AND i.index_id = p.index_id
INNER JOIN 
    sys.allocation_units a ON p.partition_id = a.container_id
WHERE 
    t.NAME NOT LIKE 'dt%' AND
    i.OBJECT_ID > 255 AND   
    i.index_id <= 1
GROUP BY 
    t.NAME, i.object_id, i.index_id, i.name 
ORDER BY 
   [TotalSpace(MB)] desc
```

## Check if SQL Instant File Initialization Enabled
```
exec xp_readerrorlog 0, 1, N'Database Instant File Initialization'
```

## SQL Server I/O per database
```
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
```

## SQL Service/Server Uptime
```
SELECT (DATEDIFF(DAY, sqlserver_start_time, GETDATE()))
       AS [Days],
       ((DATEDIFF(MINUTE, sqlserver_start_time, GETDATE())/60)%24)
       AS [Hours],
       DATEDIFF(MINUTE, sqlserver_start_time, GETDATE())%60
       AS [Minutes]
FROM sys.dm_os_sys_info;
```
## SQL Number of Rows in Partitions (Troubleshooting)
(If SQL partitioning feature is used)
```
SELECT 
t.[name] AS TableName,
p.partition_number AS PartitionNumber, 
f.name AS [Filegroup], 
p.rows AS NumberOfRows 
FROM sys.partitions p
JOIN sys.destination_data_spaces ds ON p.partition_number = ds.destination_id
JOIN sys.filegroups f ON ds.data_space_id = f.data_space_id
JOIN sys.tables t ON t.[object_id]=p.[object_id]
WHERE p.index_id = 1 /*Return Only Clustered Index. Use 2 for Unique Non Clustered and 4 for Non Clustered Indexes*/
```
