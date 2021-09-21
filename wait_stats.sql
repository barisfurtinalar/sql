WITH [Waits] AS
    (SELECT
        [wait_type],
        [wait_time_ms] / 1000.0 AS [WaitS],
        ([wait_time_ms] - [signal_wait_time_ms]) / 1000.0 AS [ResourceS],
        [signal_wait_time_ms] / 1000.0 AS [SignalS],
        [waiting_tasks_count] AS [WaitCount],
        100.0 * [wait_time_ms] / SUM ([wait_time_ms]) OVER() AS [Percentage],
        ROW_NUMBER() OVER(ORDER BY [wait_time_ms] DESC) AS [RowNum]
    FROM sys.dm_os_wait_stats
    WHERE [wait_type] NOT IN (
        /* These wait types may not indicate a problem */
        N'BROKER_EVENTHANDLER',
        N'BROKER_RECEIVE_WAITFOR',
        N'BROKER_TASK_STOP', 
        N'BROKER_TO_FLUSH', 
        N'BROKER_TRANSMITTER', 
        N'CHECKPOINT_QUEUE', 
        N'CHKPT', 
        N'CLR_AUTO_EVENT', 
        N'CLR_MANUAL_EVENT', 
        N'CLR_SEMAPHORE',
        /* Comment this next line if you suspect parallelism issues */
        N'CXCONSUMER', 

        N'DIRTY_PAGE_POLL', 
        N'DISPATCHER_QUEUE_SEMAPHORE', 
        N'EXECSYNC', 
        N'FSAGENT', 
        N'FT_IFTS_SCHEDULER_IDLE_WAIT', 
        N'FT_IFTSHC_MUTEX', 
        N'KSOURCE_WAKEUP',
        N'LAZYWRITER_SLEEP', 
        N'LOGMGR_QUEUE',
        N'MEMORY_ALLOCATION_EXT', 
        N'ONDEMAND_TASK_QUEUE', 
        N'PARALLEL_REDO_DRAIN_WORKER', 
        N'PARALLEL_REDO_LOG_CACHE',
        N'PARALLEL_REDO_TRAN_LIST', 
        N'PARALLEL_REDO_WORKER_SYNC',
        N'PARALLEL_REDO_WORKER_WAIT_WORK',
        N'PREEMPTIVE_OS_FLUSHFILEBUFFERS', 
        N'PREEMPTIVE_XE_GETTARGETSTATE', 
        N'PWAIT_ALL_COMPONENTS_INITIALIZED', 
        N'PWAIT_DIRECTLOGCONSUMER_GETNEXT', 
        N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', 
        N'QDS_ASYNC_QUEUE', 
        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        N'QDS_SHUTDOWN_QUEUE',
        N'REDO_THREAD_PENDING_WORK',
        N'REQUEST_FOR_DEADLOCK_SEARCH',
        N'RESOURCE_QUEUE', 
        N'SERVER_IDLE_CHECK', 
        N'SLEEP_BPOOL_FLUSH',
        N'SLEEP_DBSTARTUP',
        N'SLEEP_DCOMSTARTUP', 
        N'SLEEP_MASTERDBREADY',
        N'SLEEP_MASTERMDREADY', 
        N'SLEEP_MASTERUPGRADED', 
        N'SLEEP_MSDBSTARTUP', 
        N'SLEEP_SYSTEMTASK', 
        N'SLEEP_TASK', 
        N'SLEEP_TEMPDBSTARTUP', 
        N'SNI_HTTP_ACCEPT', 
        N'SOS_WORK_DISPATCHER', 
        N'SP_SERVER_DIAGNOSTICS_SLEEP',
        N'SQLTRACE_BUFFER_FLUSH',
        N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', 
        N'SQLTRACE_WAIT_ENTRIES',
        N'VDI_CLIENT_OTHER',
        N'WAIT_FOR_RESULTS', 
        N'WAITFOR', 
        N'WAITFOR_TASKSHUTDOWN', 
        N'WAIT_XTP_RECOVERY',
        N'WAIT_XTP_HOST_WAIT',
        N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', 
        N'WAIT_XTP_CKPT_CLOSE', 
        N'XE_DISPATCHER_JOIN', 
        N'XE_DISPATCHER_WAIT', 
        N'XE_TIMER_EVENT' 
        )
    AND [waiting_tasks_count] > 0
    )
SELECT
    MAX ([W1].[wait_type]) AS [WaitType],
    CAST (MAX ([W1].[WaitS]) AS DECIMAL (16,2)) AS [Wait_Secs],
    CAST (MAX ([W1].[ResourceS]) AS DECIMAL (16,2)) AS [Resource_Secs],
    CAST (MAX ([W1].[SignalS]) AS DECIMAL (16,2)) AS [Signal_Secs],
    MAX ([W1].[WaitCount]) AS [WaitCount],
    CAST (MAX ([W1].[Percentage]) AS DECIMAL (5,2)) AS [PercentageofWait],
    CAST ((MAX ([W1].[WaitS]) / MAX ([W1].[WaitCount])) AS DECIMAL (16,4)) AS [AvgWait_S],
    CAST ((MAX ([W1].[ResourceS]) / MAX ([W1].[WaitCount])) AS DECIMAL (16,4)) AS [AvgRes_S],
    CAST ((MAX ([W1].[SignalS]) / MAX ([W1].[WaitCount])) AS DECIMAL (16,4)) AS [AvgSig_S]
FROM [Waits] AS [W1]
INNER JOIN [Waits] AS [W2] ON [W2].[RowNum] <= [W1].[RowNum]
GROUP BY [W1].[RowNum]
HAVING SUM ([W2].[Percentage]) - MAX( [W1].[Percentage] ) < 100; -- The percentage threshold %95
GO
