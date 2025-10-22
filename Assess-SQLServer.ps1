  <#
.SYNOPSIS
    SQL server assessment script based on server and SQL server metrics
.DESCRIPTION
    SQL server assessment script collecting metrics using SQL Server DMVs. Outputs are saved to Destination folder and compressed. The script needs necessary permissions to create files/folders.
    Uses Windows authentication to connect to SQL Server.
.PARAMETER server
    The SQL Server name or listener name.
.PARAMETER database
    The database name to connect to (defaults to 'master' if not specified).
.PARAMETER SourceFolder
    source folder that contains .csv files. (defaults to 'C:\Temp' if not specified)
.PARAMETER DestinationFolder
    Destination folder to save .zip file. (defaults to 'C:\Temp' if not specified)
.PARAMETER IncludeTimestamp
    Add timestamp to output (.zip file)
.EXAMPLE
    .\assessment-v2.ps1 -SourceFolder "C:\Temp" -DestinationFolder "C:\Temp" -server "listener1.cobra.kai" -IncludeTimestamp
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$server,
    
    [Parameter(Mandatory=$true)]
    [string]$SourceFolder = "C:\Temp",
    
    [Parameter(Mandatory=$false)]
    [string]$DestinationFolder = "C:\Temp",
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludeTimestamp
)

try {
    # Validate source folder
    if (-not (Test-Path -Path $SourceFolder)) {
        New-Item -ItemType Directory -Path $SourceFolder | Out-Null
        Write-Host "Created destination folder: $SourceFolder"
    }
    # Create destination folder if it doesn't exist
    if (-not (Test-Path -Path $DestinationFolder)) {
        New-Item -ItemType Directory -Path $DestinationFolder | Out-Null
        Write-Host "Created destination folder: $DestinationFolder"
    }
    
}
catch {
    Write-Error "An error occurred: $_"
    exit 1
}

Install-Module -Name SqlServer

$database = "master"

# Define query combining DMV queries (you can tweak as needed)
$query1 = @"
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

$query2 = @"
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

$query3 = @"
SELECT TOP 20
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

$query4 = @"
SELECT 
	virtual_machine_type_desc AS [virtualized?],
	cpu_count AS Cores,
	hyperthread_ratio AS Hyperthreading,
	CAST(physical_memory_kb AS FLOAT) / 1024 / 1024 AS Memory_in_GB,
	DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) AS UptimeInSeconds
FROM sys.dm_os_sys_info;
"@

$query5 = @"
SELECT  
    SERVERPROPERTY('ProductVersion')     AS [ProductVersion],
    SERVERPROPERTY('ProductLevel')       AS [ProductLevel],   -- RTM / SP / CU
    SERVERPROPERTY('Edition')            AS [Edition],
    SERVERPROPERTY('EngineEdition')      AS [EngineEdition],  -- numeric code
    SERVERPROPERTY('ProductUpdateLevel') AS [ProductUpdateLevel], -- e.g. CU number
    SERVERPROPERTY('ProductBuildType')   AS [ProductBuildType],   -- e.g. GDR / CU
    SERVERPROPERTY('InstanceName')       AS [InstanceName],
    SERVERPROPERTY('MachineName')        AS [MachineName],
    SERVERPROPERTY('IsClustered')        AS [IsClustered]
"@

# Load SQL Server module
Import-Module SqlServer

# Execute query and export results
Invoke-Sqlcmd -ServerInstance $server -Database $database -Query $query1 -TrustServerCertificate | 
    Export-Csv -Path "$DestinationFolder\SQLServerWaitStats.csv" -NoTypeInformation -Encoding UTF8

Invoke-Sqlcmd -ServerInstance $server -Database $database -Query $query2 -TrustServerCertificate | 
    Export-Csv -Path "$DestinationFolder\SQLServerFileLayout.csv" -NoTypeInformation -Encoding UTF8

Invoke-Sqlcmd -ServerInstance $server -Database $database -Query $query3 -TrustServerCertificate | 
    Export-Csv -Path "$DestinationFolder\SQLServerExecutionPlanMetrics.csv" -NoTypeInformation -Encoding UTF8

Invoke-Sqlcmd -ServerInstance $server -Database $database -Query $query4 -TrustServerCertificate | 
    Export-Csv -Path "$DestinationFolder\SQLServerOSandHW.csv" -NoTypeInformation -Encoding UTF8

Invoke-Sqlcmd -ServerInstance $server -Database $database -Query $query5 -TrustServerCertificate | 
    Export-Csv -Path "$DestinationFolder\SQLServerInfo.csv" -NoTypeInformation -Encoding UTF8

try {

    # Generate zip file name
    $folderName = Split-Path -Path $SourceFolder -Leaf
    $timestamp = if ($IncludeTimestamp) { "_$(Get-Date -Format 'yyyyMMdd_HHmmss')" } else { "" }
    $zipName = "SQLAssesment-${timestamp}.zip"
    $destinationZip = Join-Path -Path $DestinationFolder -ChildPath $zipName

    # Create the zip file
    Compress-Archive -Path "$SourceFolder\*.csv" -DestinationPath $destinationZip -Force
    
    # Verify zip file was created
    if (Test-Path -Path $destinationZip) {
        Write-Host "Successfully created zip file: $destinationZip"
        Write-Host "Zip file size: $((Get-Item $destinationZip).Length / 1MB) MB"
    }
    else {
        throw "Failed to create zip file"
    }
}
catch {
    Write-Error "An error occurred: $_"
    exit 1
}
 
