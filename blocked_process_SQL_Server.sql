sp_configure 'show advanced options', 1;
GO

RECONFIGURE;
GO
/* Sets the blocked process threshold to 10 seconds, generating a blocked process report for each task that is blocked. */
sp_configure 'blocked process threshold', 10;
GO

RECONFIGURE;
GO

CREATE EVENT SESSION [blocked_process_report1] ON SERVER 
ADD EVENT sqlserver.blocked_process_report(
    ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.query_hash,sqlserver.query_plan_hash,sqlserver.sql_text)),
ADD EVENT sqlserver.xml_deadlock_report(
    ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.query_hash,sqlserver.query_plan_hash,sqlserver.sql_text))
ADD TARGET package0.event_file(SET filename=N'c:\temp\b_report')
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=ON)
GO

/* start the Extended Event session  */
