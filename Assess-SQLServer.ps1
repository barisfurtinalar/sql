  <#
.SYNOPSIS
    Performs automated assessment of SQL Server health, performance, and configuration by collecting key DMV and server metrics
.DESCRIPTION
    This script performs a comprehensive assessment of a target SQL Server instance by collecting and analyzing key system and SQL Server metrics. 
    Leveraging a series of queries against SQL Server Dynamic Management Views (DMVs) and server properties, it gathers crucial information about 
    server health, performance bottlenecks, resource consumption, and configuration details. Results are exported as CSV files for easy review and
    further analysis and are optionally packaged as a compressed ZIP archive with a timestamp 
.PARAMETER server
    The SQL Server name or listener name.
.PARAMETER database
    The database name to connect to (defaults to 'master' if not specified).
.PARAMETER DestinationFolder
    Destination folder to save .csv files and the final .zip file. (defaults to 'C:\Temp' if not specified)
.PARAMETER IncludeTimestamp
    Add timestamp to output (.zip file)
.PARAMETER UseSqlAuthentication
    Switch to enable SQL authentication instead of Windows authentication.
.PARAMETER SqlUser
    The SQL login username to use when SQL authentication is enabled.
.PARAMETER SqlPassword
    The SQL login password to use when SQL authentication is enabled.
.EXAMPLE
    .\Assess-SQLServer.ps1 -DestinationFolder "C:\Temp" -server "listener1.cobra.kai" -IncludeTimestamp
.EXAMPLE
    .\Assess-SQLServer.ps1 -DestinationFolder "C:\Temp" -server "listener1.cobra.kai" -UseSqlAuthentication -SqlUser "sa" -SqlPassword "YourPassword!" -IncludeTimestamp 
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [string]$server,

    [Parameter(Mandatory=$false)]
    [string]$database = "master",
    
    [Parameter(Mandatory=$false)]
    [string]$DestinationFolder = "C:\Temp",
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludeTimestamp,

    [Parameter(Mandatory=$false)]
    [switch]$UseSqlAuthentication,
    
    [Parameter(Mandatory=$false)]
    [string]$SqlUser,

    [Parameter(Mandatory=$false)]
    [string]$SqlPassword

)

$ErrorActionPreference = "Stop"

try {
    
    # Create destination folder if it doesn't exist
    if (-not (Test-Path -Path $DestinationFolder)) {
        New-Item -ItemType Directory -Path $DestinationFolder | Out-Null
        Write-Output "Created destination folder: $DestinationFolder"
    }
    
}
catch {
    Write-Error "An error occurred: $_"
    exit 1
}

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Install-Module -Name SqlServer -Force
}
Import-Module SqlServer

$sqlParams = @{
    ServerInstance = $server
    Database = $database
    TrustServerCertificate = $true
    Query = $null
}

if ($UseSqlAuthentication) {
    $sqlParams["Username"] = $SqlUser
    $sqlParams["Password"] = $SqlPassword
}

#Various DMV queries (you can tweak as needed)
$waitstats = @"
WITH Uptime AS (
    SELECT DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) AS UptimeInSeconds
    FROM sys.dm_os_sys_info
)
SELECT TOP 10
    wait_type,
    wait_time_ms,
    wait_time_ms / 1000 /60 AS wait_time_minutes,
    waiting_tasks_count,
    CASE 
        WHEN waiting_tasks_count > 0 THEN wait_time_ms / waiting_tasks_count ELSE 0 
    END AS avg_wait_time_ms,
    CAST(CAST(waiting_tasks_count AS FLOAT) / (SELECT UptimeInSeconds FROM Uptime) AS DECIMAL(18,2)) AS avg_waits_per_second,
    CAST((CASE 
        WHEN waiting_tasks_count > 0 THEN wait_time_ms / waiting_tasks_count ELSE 0 
    END) * (CAST(waiting_tasks_count AS FLOAT) / (SELECT UptimeInSeconds FROM Uptime)) AS DECIMAL(18,2)) AS potential_impact
FROM sys.dm_os_wait_stats
ORDER BY potential_impact DESC;

"@

$sqlfiles = @"
SELECT
    DB_NAME(vfs.database_id) AS database_name,
    vfs.file_id,
    mf.name AS file_name,
    mf.physical_name AS file_path,
    vfs.num_of_reads,
    CAST(vfs.num_of_bytes_read AS FLOAT) / 1024 AS num_of_kb_read,
    vfs.io_stall_read_ms,
    vfs.num_of_writes,
    CAST(vfs.num_of_bytes_written AS FLOAT) / 1024 AS num_of_kb_written,
    vfs.io_stall_write_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf
    ON vfs.database_id = mf.database_id
    AND vfs.file_id = mf.file_id
ORDER BY vfs.io_stall_read_ms DESC;

"@

$executionplan = @"
SELECT
    t.text AS sql_text,
    s.execution_count,
    s.total_physical_reads / s.execution_count AS avg_physical_reads,
    s.total_logical_reads / s.execution_count AS avg_logical_reads,
    s.total_logical_writes / s.execution_count AS avg_logical_writes,
	s.total_elapsed_time / s.execution_count AS [avg_execution_time],
	s.total_worker_time / s.execution_count AS avg_CPU_Time,
	s.total_grant_kb / s.execution_count AS avg_memory_grant,
	s.max_physical_reads,
	s.min_physical_reads
FROM sys.dm_exec_query_stats AS s
CROSS APPLY sys.dm_exec_sql_text(s.sql_handle) AS t
ORDER BY avg_physical_reads DESC;
"@

$osinfo = @"
SELECT 
	virtual_machine_type_desc AS [virtualized?],
	cpu_count AS Cores,
	hyperthread_ratio AS Hyperthreading,
	CAST(physical_memory_kb AS FLOAT) / 1024 / 1024 AS Memory_in_GB,
	DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) AS UptimeInSeconds
FROM sys.dm_os_sys_info;
"@

$sqlinfo = @"
SELECT  
    SERVERPROPERTY('ProductVersion')     AS [ProductVersion],
    SERVERPROPERTY('ProductLevel')       AS [ProductLevel],  
    SERVERPROPERTY('Edition')            AS [Edition],
    SERVERPROPERTY('EngineEdition')      AS [EngineEdition],  
    SERVERPROPERTY('ProductUpdateLevel') AS [ProductUpdateLevel], 
    SERVERPROPERTY('ProductBuildType')   AS [ProductBuildType],   
    SERVERPROPERTY('InstanceName')       AS [InstanceName],
    SERVERPROPERTY('MachineName')        AS [MachineName],
    SERVERPROPERTY('IsClustered')        AS [IsClustered]
"@

$memorystate = @"
SELECT  
    total_physical_memory_kb / 1024 AS [Total_Physical_Memory_MB],
    available_physical_memory_kb / 1024 AS [Available_Physical_Memory_MB],
    total_page_file_kb / 1024 AS [Total_Page_File_MB],
    available_page_file_kb / 1024 AS [Available_Page_File_MB],
    system_memory_state_desc AS [SystemMemoryState]
FROM sys.dm_os_sys_memory;
"@

$diskIOperDB = @"
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
"@

try {

    $sqlParams["Query"] = $waitstats
    Invoke-Sqlcmd @sqlParams | Export-Csv -Path "$DestinationFolder\SQLServerWaitStats.csv" -NoTypeInformation -Encoding UTF8

    $sqlParams["Query"] = $sqlfiles
    Invoke-Sqlcmd @sqlParams | Export-Csv -Path "$DestinationFolder\SQLServerFiles.csv" -NoTypeInformation -Encoding UTF8

    $sqlParams["Query"] = $executionplan
    Invoke-Sqlcmd @sqlParams | Export-Csv -Path "$DestinationFolder\SQLServerExecutionPlanStats.csv" -NoTypeInformation -Encoding UTF8

    $sqlParams["Query"] = $osinfo
    Invoke-Sqlcmd @sqlParams | Export-Csv -Path "$DestinationFolder\SQLServerOSinfo.csv" -NoTypeInformation -Encoding UTF8

    $sqlParams["Query"] = $sqlinfo
    Invoke-Sqlcmd @sqlParams | Export-Csv -Path "$DestinationFolder\SQLServerInfo.csv" -NoTypeInformation -Encoding UTF8

    $sqlParams["Query"] = $memorystate
    Invoke-Sqlcmd @sqlParams | Export-Csv -Path "$DestinationFolder\SQLServerMemoryState.csv" -NoTypeInformation -Encoding UTF8

    $sqlParams["Query"] = $diskIOperDB
    Invoke-Sqlcmd @sqlParams | Export-Csv -Path "$DestinationFolder\SQLServerIOstats.csv" -NoTypeInformation -Encoding UTF8

}
catch {
    Write-Error "An error occurred: $_"
    exit 1
}

try {

    if ($IncludeTimestamp) {
        $zipName = "SQLAssessment_$((Get-Date -Format 'yyyyMMdd_HHmmss')).zip"
    } else {
        $zipName = "SQLAssessment.zip"
    }

    $destinationZip = Join-Path -Path $DestinationFolder -ChildPath $zipName
    # Create the zip file
    Compress-Archive -Path "$DestinationFolder\*.csv" -DestinationPath $destinationZip -Force

    # Verify zip file was created
    if (Test-Path -Path $destinationZip) {
        Write-Output "Successfully created zip file: $destinationZip"
        Write-Output "Zip file size: $((Get-Item $destinationZip).Length / 1MB) MB"
    }
    else {
        throw "Failed to create zip file"
    }
}
catch {
    Write-Error "An error occurred: $_"
    exit 1
}
 
