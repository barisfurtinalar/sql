<#
.SYNOPSIS
Performs automated assessment of SQL Server health, performance, and configuration by collecting key DMV and server metrics, and evaluates the instance's eligibility to migrate to Amazon RDS for SQL Server.

.DESCRIPTION
This script performs a comprehensive assessment of a target SQL Server instance by collecting and analyzing key system and SQL Server metrics. 
Leveraging a series of queries against SQL Server Dynamic Management Views (DMVs) and server properties, it gathers crucial information about 
server health, performance bottlenecks, resource consumption, and configuration details. Results are exported as CSV files for easy review and
further analysis and are optionally packaged as a compressed ZIP archive with a timestamp.

In addition, the script can optionally run an Amazon RDS for SQL Server eligibility assessment that detects usage of features that are
unsupported, or have limited support, on Amazon RDS. This is disabled by default and enabled with the -TestRdsEligibility switch. When
enabled, the eligibility results are written to a dedicated CSV (<server>-RDSEligibility.csv) and included in the ZIP archive alongside
the other assessment outputs.

Reference for unsupported / limited-support features:
https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/SQLServer.Concepts.General.FeatureNonSupport.html

The script must be run with Administrator privileges on the system. Additionally, the executing user must have the VIEW SERVER STATE and VIEW 
DATABASE STATE permissions on the SQL Server instance to access the necessary metadata and DMV information.

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

.PARAMETER SqlCredential
PSCredential object containing SQL login username and password when SQL authentication is enabled.

.PARAMETER CleanupCsvFiles
Remove individual CSV files after creating ZIP archive (default: $true)

.PARAMETER TestRdsEligibility
Optional switch. When specified, runs the Amazon RDS for SQL Server eligibility assessment and adds <server>-RDSEligibility.csv to the ZIP
archive. Disabled by default.

.EXAMPLE
.\Export-SqlServerAssessment.ps1 -DestinationFolder "C:\Temp" -server "node1.cobra.kai" -IncludeTimestamp

.EXAMPLE
# Include the Amazon RDS for SQL Server eligibility assessment in the output.
.\Export-SqlServerAssessment.ps1 -DestinationFolder "C:\Temp" -server "node1.cobra.kai" -TestRdsEligibility -IncludeTimestamp

.EXAMPLE
$cred = Get-Credential
.\Export-SqlServerAssessment.ps1 -DestinationFolder "C:\Temp" -server "node1.cobra.kai" -UseSqlAuthentication -SqlCredential $cred -IncludeTimestamp
#>

#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$server,
    
    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$database = "master",
    
    [Parameter(Mandatory=$false)]
    [ValidateScript({Test-Path $_ -IsValid})]
    [string]$DestinationFolder = "C:\Temp",
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludeTimestamp,
    
    [Parameter(Mandatory=$false)]
    [switch]$UseSqlAuthentication,
    
    [Parameter(Mandatory=$false)]
    [PSCredential]$SqlCredential,
    
    [Parameter(Mandatory=$false)]
    [bool]$CleanupCsvFiles = $true,
    
    [Parameter(Mandatory=$false)]
    [switch]$TestRdsEligibility
)

$ErrorActionPreference = "Stop"

# Logging function
function Write-Log {
    param(
        [string]$Message, 
        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp [$Level] $Message"
    Write-Output $logMessage
    $logMessage | Out-File -FilePath "$DestinationFolder\assessment.log" -Append -Encoding UTF8
}

# Validate SQL Credential if SQL Authentication is used
if ($UseSqlAuthentication -and -not $SqlCredential) {
    Write-Log "SQL Authentication requested but no credential provided. Prompting for credentials..." "WARNING"
    $SqlCredential = Get-Credential -Message "Enter SQL Server credentials"
    if (-not $SqlCredential) {
        throw "SQL Server credentials are required when using SQL Authentication"
    }
}

# Create destination folder if it doesn't exist
try {
    if (-not (Test-Path -Path $DestinationFolder)) {
        New-Item -ItemType Directory -Path $DestinationFolder | Out-Null
        Write-Log "Created destination folder: $DestinationFolder"
    }
    
    # Check available disk space (require at least 100MB)
    $drive = Split-Path $DestinationFolder -Qualifier
    $freeSpace = (Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='$drive'").FreeSpace
    if ($freeSpace -lt 100MB) {
        throw "Insufficient disk space. At least 100MB required, only $([math]::Round($freeSpace/1MB, 2))MB available."
    }
    Write-Log "Available disk space: $([math]::Round($freeSpace/1MB, 2))MB"
    
} catch {
    Write-Log "Failed to create destination folder or check disk space: $_" "ERROR"
    exit 1
}

# Check and install SqlServer module
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Log "SqlServer module not found" "WARNING"
    $choice = Read-Host "SqlServer module is required. Install it now? (Y/N)"
    if ($choice -eq 'Y' -or $choice -eq 'y') {
        try {
            Write-Log "Installing SqlServer module..."
            Install-Module -Name SqlServer -Force -Scope CurrentUser -AllowClobber
            Write-Log "SqlServer module installed successfully"
        } catch {
            Write-Log "Failed to install SqlServer module: $_" "ERROR"
            exit 1
        }
    } else {
        Write-Log "SqlServer module is required to continue" "ERROR"
        exit 1
    }
}

Import-Module SqlServer

# Some older SqlServer/SQLPS module versions of Invoke-Sqlcmd do not support
# the -TrustServerCertificate parameter. Detect support so we only pass it when
# available (avoids "A parameter cannot be found that matches parameter name
# 'TrustServerCertificate'").
$invokeSqlcmd = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
$supportsTrustServerCertificate = $invokeSqlcmd -and $invokeSqlcmd.Parameters.ContainsKey('TrustServerCertificate')
if (-not $supportsTrustServerCertificate) {
    Write-Log "Installed Invoke-Sqlcmd does not support -TrustServerCertificate; continuing without it. Consider 'Install-Module SqlServer -Force' to update." "WARNING"
}

# Setup SQL connection parameters
$sqlParams = @{
    ServerInstance = $server
    Database = $database
    QueryTimeout = 300
    Query = $null
}

if ($supportsTrustServerCertificate) {
    $sqlParams["TrustServerCertificate"] = $true
}

if ($UseSqlAuthentication) {
    $sqlParams["Username"] = $SqlCredential.UserName
    $sqlParams["Password"] = $SqlCredential.GetNetworkCredential().Password
}

# Test SQL Server connectivity
Write-Log "Testing connection to SQL Server: $server"
try {
    $testQuery = "SELECT @@VERSION AS Version, @@SERVERNAME AS ServerName, GETDATE() AS CurrentTime"
    $sqlParams["Query"] = $testQuery
    $result = Invoke-Sqlcmd @sqlParams
    Write-Log "Successfully connected to: $($result.ServerName)"
    Write-Log "SQL Server Version: $($result.Version.Split("`n")[0])"
} catch {
    Write-Log "Failed to connect to SQL Server '$server': $_" "ERROR"
    exit 1
}

# =====================================================================
# Amazon RDS for SQL Server - eligibility assessment
# ---------------------------------------------------------------------
# Detects usage of features that are unsupported, or have limited support,
# on Amazon RDS for SQL Server. Reuses the $sqlParams connection context
# (Invoke-Sqlcmd) so it honors the same -server/-database/auth settings.
#
# Reference:
# https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/SQLServer.Concepts.General.FeatureNonSupport.html
# =====================================================================

# Holds the eligibility result rows for this run.
$script:RdsResults = New-Object System.Collections.Generic.List[object]

function Add-RdsResult {
    param(
        [string]$Feature,
        [ValidateSet('Unsupported', 'LimitedSupport', 'SQL2022Unsupported')]
        [string]$Category,
        [ValidateSet('InUse', 'NotInUse', 'Manual', 'Error')]
        [string]$Status,
        [string]$Detail
    )
    $script:RdsResults.Add([pscustomobject]@{
            Feature  = $Feature
            Category = $Category
            Status   = $Status
            Detail   = $Detail
        })
}

# Run an arbitrary query through the shared Invoke-Sqlcmd connection context.
function Invoke-RdsSql {
    param([string]$Query)
    $p = $script:sqlParams.Clone()
    $p["Query"] = $Query
    # Suppress Invoke-Sqlcmd informational/verbose streams; surface errors only.
    return Invoke-Sqlcmd @p -ErrorAction Stop
}

# Return the first column of the first row as an integer (0 when empty/NULL).
function Get-RdsScalarInt {
    param([string]$Query)
    $r = Invoke-RdsSql -Query $Query
    if (-not $r) { return 0 }
    $row = $r | Select-Object -First 1
    $prop = $row.PSObject.Properties | Select-Object -First 1
    if ($null -eq $prop) { return 0 }
    $val = $prop.Value
    if ($null -eq $val -or $val -is [System.DBNull]) { return 0 }
    return [int]$val
}

# Enumerate online user databases (exclude system DBs and database snapshots).
function Get-RdsUserDatabases {
    $q = @"
SELECT name
FROM sys.databases
WHERE state = 0
  AND database_id > 4
  AND source_database_id IS NULL
ORDER BY name;
"@
    $r = Invoke-RdsSql -Query $q
    return @($r | ForEach-Object { $_.name })
}

# Run a COUNT query in each user database; return hashtable of db -> count (>0 only).
function Invoke-RdsPerDatabase {
    param(
        [string[]]$Databases,
        [string]$CountQuery
    )
    $hits = @{}
    foreach ($db in $Databases) {
        $safe = $db -replace ']', ']]'
        $scoped = "USE [$safe];`n$CountQuery"
        try {
            $c = Get-RdsScalarInt -Query $scoped
            if ($c -gt 0) { $hits[$db] = $c }
        }
        catch {
            $hits["$db (scan error)"] = $_.Exception.Message
        }
    }
    return $hits
}

# Wrap an individual check so a failure becomes an 'Error' row, not a fatal stop.
function Invoke-RdsCheck {
    param(
        [string]$Feature,
        [string]$Category,
        [scriptblock]$Body
    )
    try {
        & $Body
    }
    catch {
        Add-RdsResult -Feature $Feature -Category $Category -Status 'Error' -Detail $_.Exception.Message
    }
}

function Get-RdsMajorVersion {
    $v = Get-RdsScalarInt -Query "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) AS v"
    if ($v -gt 0) { return $v }
    $r = Invoke-RdsSql -Query "SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)) AS v"
    $ver = [string]($r | Select-Object -First 1).v
    if ([string]::IsNullOrWhiteSpace($ver)) { return 0 }
    return [int]($ver.Split('.')[0])
}

function Invoke-RdsEligibilityAssessment {
    <#
        Runs the full battery of RDS for SQL Server eligibility checks and
        returns the result rows (sorted by severity).
    #>
    $script:RdsResults.Clear()

    $majorVersion = 0
    try { $majorVersion = Get-RdsMajorVersion } catch { $majorVersion = 0 }

    $userDbs = @()
    try { $userDbs = Get-RdsUserDatabases } catch { Write-Log "RDS: could not enumerate user databases: $_" "WARNING" }

    # =================================================================
    # UNSUPPORTED FEATURES
    # =================================================================

    Invoke-RdsCheck 'Database Log Shipping' 'Unsupported' {
        $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM msdb.dbo.log_shipping_primary_databases"
        $c2 = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM msdb.dbo.log_shipping_secondary_databases"
        if (($c + $c2) -gt 0) {
            Add-RdsResult 'Database Log Shipping' 'Unsupported' 'InUse' "Primary configs: $c, Secondary configs: $c2"
        }
        else {
            Add-RdsResult 'Database Log Shipping' 'Unsupported' 'NotInUse' 'No log shipping configurations found.'
        }
    }

    Invoke-RdsCheck 'Database snapshots' 'Unsupported' {
        $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM sys.databases WHERE source_database_id IS NOT NULL"
        if ($c -gt 0) {
            Add-RdsResult 'Database snapshots' 'Unsupported' 'InUse' "$c database snapshot(s) present."
        }
        else {
            Add-RdsResult 'Database snapshots' 'Unsupported' 'NotInUse' 'No database snapshots found.'
        }
    }

    Invoke-RdsCheck 'Extended stored procedures (incl. xp_cmdshell)' 'Unsupported' {
        $c = 0
        try { $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM sys.extended_procedures" } catch { $c = 0 }
        $xp = 0
        try { $xp = Get-RdsScalarInt -Query "SELECT CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'xp_cmdshell'" } catch { $xp = 0 }
        if ($c -gt 0 -or $xp -gt 0) {
            Add-RdsResult 'Extended stored procedures (incl. xp_cmdshell)' 'Unsupported' 'InUse' "User-defined extended procedures: $c. xp_cmdshell enabled: $([bool]$xp)."
        }
        else {
            Add-RdsResult 'Extended stored procedures (incl. xp_cmdshell)' 'Unsupported' 'NotInUse' 'No user extended procedures; xp_cmdshell disabled.'
        }
    }

    Invoke-RdsCheck 'FILESTREAM support' 'Unsupported' {
        $cfg = 0
        try { $cfg = Get-RdsScalarInt -Query "SELECT CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'filestream access level'" } catch { $cfg = 0 }
        $fsHits = Invoke-RdsPerDatabase -Databases $userDbs -CountQuery "SELECT COUNT(*) FROM sys.database_files WHERE type_desc = 'FILESTREAM'"
        if ($cfg -gt 0 -or $fsHits.Count -gt 0) {
            Add-RdsResult 'FILESTREAM support' 'Unsupported' 'InUse' "FILESTREAM access level: $cfg. DBs with FILESTREAM files: $($fsHits.Keys -join ', ')"
        }
        else {
            Add-RdsResult 'FILESTREAM support' 'Unsupported' 'NotInUse' 'FILESTREAM disabled and no FILESTREAM files found.'
        }
    }

    Invoke-RdsCheck 'File tables' 'Unsupported' {
        $hits = Invoke-RdsPerDatabase -Databases $userDbs -CountQuery "SELECT COUNT(*) FROM sys.tables WHERE is_filetable = 1"
        if ($hits.Count -gt 0) {
            Add-RdsResult 'File tables' 'Unsupported' 'InUse' "FileTables found in: $($hits.Keys -join ', ')"
        }
        else {
            Add-RdsResult 'File tables' 'Unsupported' 'NotInUse' 'No FileTables found.'
        }
    }

    Invoke-RdsCheck 'Maintenance plans' 'Unsupported' {
        $c = 0
        try { $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM msdb.dbo.sysmaintplan_plans" } catch { $c = 0 }
        if ($c -gt 0) {
            Add-RdsResult 'Maintenance plans' 'Unsupported' 'InUse' "$c maintenance plan(s) defined."
        }
        else {
            Add-RdsResult 'Maintenance plans' 'Unsupported' 'NotInUse' 'No maintenance plans found.'
        }
    }

    Invoke-RdsCheck 'Performance Data Collector' 'Unsupported' {
        $c = 0
        try { $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM msdb.dbo.syscollector_collection_sets WHERE is_running = 1" } catch { $c = 0 }
        if ($c -gt 0) {
            Add-RdsResult 'Performance Data Collector' 'Unsupported' 'InUse' "$c running collection set(s)."
        }
        else {
            Add-RdsResult 'Performance Data Collector' 'Unsupported' 'NotInUse' 'No running data collection sets.'
        }
    }

    Invoke-RdsCheck 'Policy-Based Management' 'Unsupported' {
        $c = 0
        try { $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM msdb.dbo.syspolicy_policies WHERE is_enabled = 1" } catch { $c = 0 }
        if ($c -gt 0) {
            Add-RdsResult 'Policy-Based Management' 'Unsupported' 'InUse' "$c enabled policy/policies."
        }
        else {
            Add-RdsResult 'Policy-Based Management' 'Unsupported' 'NotInUse' 'No enabled policies.'
        }
    }

    Invoke-RdsCheck 'PolyBase' 'Unsupported' {
        $c = 0
        try { $c = Get-RdsScalarInt -Query "SELECT CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'polybase enabled'" } catch { $c = 0 }
        if ($c -gt 0) {
            Add-RdsResult 'PolyBase' 'Unsupported' 'InUse' 'PolyBase is enabled.'
        }
        else {
            Add-RdsResult 'PolyBase' 'Unsupported' 'NotInUse' 'PolyBase not enabled (or not installed).'
        }
    }

    Invoke-RdsCheck 'Replication' 'Unsupported' {
        $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM sys.databases WHERE is_published = 1 OR is_subscribed = 1 OR is_merge_published = 1 OR is_distributor = 1"
        if ($c -gt 0) {
            Add-RdsResult 'Replication' 'Unsupported' 'InUse' "$c database(s) participate in replication."
        }
        else {
            Add-RdsResult 'Replication' 'Unsupported' 'NotInUse' 'No databases configured for replication.'
        }
    }

    Invoke-RdsCheck 'Server-level triggers' 'Unsupported' {
        $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM sys.server_triggers WHERE is_disabled = 0"
        if ($c -gt 0) {
            Add-RdsResult 'Server-level triggers' 'Unsupported' 'InUse' "$c enabled server-level trigger(s)."
        }
        else {
            Add-RdsResult 'Server-level triggers' 'Unsupported' 'NotInUse' 'No enabled server-level triggers.'
        }
    }

    Invoke-RdsCheck 'Service Broker endpoints' 'Unsupported' {
        $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM sys.service_broker_endpoints"
        if ($c -gt 0) {
            Add-RdsResult 'Service Broker endpoints' 'Unsupported' 'InUse' "$c Service Broker endpoint(s)."
        }
        else {
            Add-RdsResult 'Service Broker endpoints' 'Unsupported' 'NotInUse' 'No Service Broker endpoints.'
        }
    }

    Invoke-RdsCheck 'Stretch database' 'Unsupported' {
        $c = 0
        try { $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM sys.databases WHERE is_remote_data_archive_enabled = 1" } catch { $c = 0 }
        if ($c -gt 0) {
            Add-RdsResult 'Stretch database' 'Unsupported' 'InUse' "$c database(s) Stretch-enabled."
        }
        else {
            Add-RdsResult 'Stretch database' 'Unsupported' 'NotInUse' 'No Stretch-enabled databases.'
        }
    }

    Invoke-RdsCheck 'TRUSTWORTHY database property' 'Unsupported' {
        $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM sys.databases WHERE is_trustworthy_on = 1 AND database_id > 4"
        if ($c -gt 0) {
            $names = Invoke-RdsSql -Query "SELECT name FROM sys.databases WHERE is_trustworthy_on = 1 AND database_id > 4"
            $list = ($names | ForEach-Object { $_.name }) -join ', '
            Add-RdsResult 'TRUSTWORTHY database property' 'Unsupported' 'InUse' "TRUSTWORTHY ON for: $list"
        }
        else {
            Add-RdsResult 'TRUSTWORTHY database property' 'Unsupported' 'NotInUse' 'No user databases with TRUSTWORTHY ON.'
        }
    }

    Invoke-RdsCheck 'T-SQL / SOAP endpoints' 'Unsupported' {
        # User-created endpoints have endpoint_id > 65535. Classify by type:
        #   TSQL / SOAP        -> the actual RDS blocker (CREATE ENDPOINT FOR TSQL/SOAP)
        #   DATABASE_MIRRORING -> created by Always On AGs / mirroring; expected on AG nodes
        #   SERVICE_BROKER     -> covered by the dedicated Service Broker check
        $rows = Invoke-RdsSql -Query "SELECT name, type_desc FROM sys.endpoints WHERE endpoint_id > 65535"
        $tsqlSoap = @($rows | Where-Object { $_.type_desc -in @('TSQL', 'SOAP') })
        $mirroring = @($rows | Where-Object { $_.type_desc -eq 'DATABASE_MIRRORING' })
        if ($tsqlSoap.Count -gt 0) {
            $detail = ($tsqlSoap | ForEach-Object { "$($_.name) [$($_.type_desc)]" }) -join ', '
            Add-RdsResult 'T-SQL / SOAP endpoints' 'Unsupported' 'InUse' "User-created T-SQL/SOAP endpoint(s): $detail"
        }
        elseif ($mirroring.Count -gt 0) {
            $detail = ($mirroring | ForEach-Object { $_.name }) -join ', '
            Add-RdsResult 'T-SQL / SOAP endpoints' 'Unsupported' 'NotInUse' "No T-SQL/SOAP endpoints. Found DATABASE_MIRRORING endpoint(s) ($detail) - expected on Always On/mirroring nodes."
        }
        else {
            Add-RdsResult 'T-SQL / SOAP endpoints' 'Unsupported' 'NotInUse' 'Only default system endpoints present.'
        }
    }

    Invoke-RdsCheck 'Custom password policies' 'Unsupported' {
        Add-RdsResult 'Custom password policies' 'Unsupported' 'Manual' 'Custom (Windows/3rd-party) password policies cannot be detected via T-SQL. Review domain/local policy and any custom password filters.'
    }

    Invoke-RdsCheck 'Backup to Azure Blob Storage' 'Unsupported' {
        $c = 0
        try { $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM msdb.dbo.backupmediafamily WHERE device_type = 9 OR physical_device_name LIKE 'https://%'" } catch { $c = 0 }
        if ($c -gt 0) {
            Add-RdsResult 'Backup to Azure Blob Storage' 'Unsupported' 'InUse' "$c backup(s) to URL/Azure detected in history."
        }
        else {
            Add-RdsResult 'Backup to Azure Blob Storage' 'Unsupported' 'NotInUse' 'No URL/Azure backups found in backup history.'
        }
    }

    Invoke-RdsCheck 'Buffer pool extension' 'Unsupported' {
        $c = 0
        try { $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM sys.dm_os_buffer_pool_extension_configuration WHERE state_description <> 'BUFFER POOL EXTENSION DISABLED'" } catch { $c = 0 }
        if ($c -gt 0) {
            Add-RdsResult 'Buffer pool extension' 'Unsupported' 'InUse' 'Buffer pool extension is enabled.'
        }
        else {
            Add-RdsResult 'Buffer pool extension' 'Unsupported' 'NotInUse' 'Buffer pool extension disabled.'
        }
    }

    Invoke-RdsCheck 'Data Quality Services (DQS)' 'Unsupported' {
        $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM sys.databases WHERE name IN ('DQS_MAIN','DQS_PROJECTS','DQS_STAGING_DATA')"
        if ($c -gt 0) {
            Add-RdsResult 'Data Quality Services (DQS)' 'Unsupported' 'InUse' 'DQS databases present (DQS_MAIN/PROJECTS/STAGING).'
        }
        else {
            Add-RdsResult 'Data Quality Services (DQS)' 'Unsupported' 'NotInUse' 'No DQS databases found.'
        }
    }

    Invoke-RdsCheck 'Machine Learning / R Services' 'Unsupported' {
        $c = 0
        try { $c = Get-RdsScalarInt -Query "SELECT CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'external scripts enabled'" } catch { $c = 0 }
        if ($c -gt 0) {
            Add-RdsResult 'Machine Learning / R Services' 'Unsupported' 'InUse' "'external scripts enabled' is on (in-database ML/R/Python in use)."
        }
        else {
            Add-RdsResult 'Machine Learning / R Services' 'Unsupported' 'NotInUse' 'External scripts not enabled.'
        }
    }

    Invoke-RdsCheck 'WCF Data Services' 'Unsupported' {
        Add-RdsResult 'WCF Data Services' 'Unsupported' 'Manual' 'WCF Data Services is an application-layer feature; review application code/IIS, not detectable via T-SQL.'
    }

    # =================================================================
    # LIMITED SUPPORT FEATURES
    # =================================================================

    Invoke-RdsCheck 'Distributed queries / linked servers' 'LimitedSupport' {
        $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM sys.servers WHERE is_linked = 1"
        if ($c -gt 0) {
            $rows = Invoke-RdsSql -Query "SELECT name, provider FROM sys.servers WHERE is_linked = 1"
            $detail = ($rows | ForEach-Object { "$($_.name) [$($_.provider)]" }) -join ', '
            Add-RdsResult 'Distributed queries / linked servers' 'LimitedSupport' 'InUse' "Linked servers: $detail"
        }
        else {
            Add-RdsResult 'Distributed queries / linked servers' 'LimitedSupport' 'NotInUse' 'No linked servers defined.'
        }
    }

    Invoke-RdsCheck 'CLR integration' 'LimitedSupport' {
        $cfg = 0
        try { $cfg = Get-RdsScalarInt -Query "SELECT CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'clr enabled'" } catch { $cfg = 0 }
        $asmHits = Invoke-RdsPerDatabase -Databases $userDbs -CountQuery "SELECT COUNT(*) FROM sys.assemblies WHERE is_user_defined = 1"
        if ($cfg -gt 0 -or $asmHits.Count -gt 0) {
            $note = if ($majorVersion -ge 14) { ' NOTE: CLR is NOT supported on RDS for SQL Server 2017+.' } else { ' CLR limited to SAFE mode on RDS 2016 and lower.' }
            Add-RdsResult 'CLR integration' 'LimitedSupport' 'InUse' ("clr enabled: $([bool]$cfg). User assemblies in: $($asmHits.Keys -join ', ')." + $note)
        }
        else {
            Add-RdsResult 'CLR integration' 'LimitedSupport' 'NotInUse' 'CLR disabled and no user assemblies.'
        }
    }

    Invoke-RdsCheck 'Linked servers with Oracle OLEDB' 'LimitedSupport' {
        $c = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM sys.servers WHERE is_linked = 1 AND (provider LIKE '%Ora%' OR provider LIKE '%MSDAORA%')"
        if ($c -gt 0) {
            Add-RdsResult 'Linked servers with Oracle OLEDB' 'LimitedSupport' 'InUse' "$c Oracle OLEDB linked server(s)."
        }
        else {
            Add-RdsResult 'Linked servers with Oracle OLEDB' 'LimitedSupport' 'NotInUse' 'No Oracle OLEDB linked servers.'
        }
    }

    Invoke-RdsCheck 'Always On Availability Groups' 'LimitedSupport' {
        $hadr = 0
        try { $hadr = Get-RdsScalarInt -Query "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS INT)" } catch { $hadr = 0 }
        $agCount = 0
        try { $agCount = Get-RdsScalarInt -Query "SELECT COUNT(*) FROM sys.availability_groups" } catch { $agCount = 0 }
        if ($hadr -gt 0 -and $agCount -gt 0) {
            Add-RdsResult 'Always On Availability Groups' 'LimitedSupport' 'InUse' "$agCount availability group(s) configured. RDS provides HA via Multi-AZ (Always On under the hood); self-managed AG topology is not migrated as-is. The associated DATABASE_MIRRORING endpoint is expected."
        }
        else {
            Add-RdsResult 'Always On Availability Groups' 'LimitedSupport' 'NotInUse' 'HADR not enabled or no availability groups configured.'
        }
    }

    # =================================================================
    # SQL SERVER 2022-SPECIFIC UNSUPPORTED FEATURES
    # =================================================================

    if ($majorVersion -ge 16) {
        Invoke-RdsCheck 'External Data Source (PolyBase/S3)' 'SQL2022Unsupported' {
            $hits = Invoke-RdsPerDatabase -Databases $userDbs -CountQuery "SELECT COUNT(*) FROM sys.external_data_sources"
            if ($hits.Count -gt 0) {
                Add-RdsResult 'External Data Source (PolyBase/S3)' 'SQL2022Unsupported' 'InUse' "External data sources in: $($hits.Keys -join ', ')"
            }
            else {
                Add-RdsResult 'External Data Source (PolyBase/S3)' 'SQL2022Unsupported' 'NotInUse' 'No external data sources defined.'
            }
        }

        Invoke-RdsCheck 'SSAS / Object store / QAT / TLS 1.3 (SQL 2022)' 'SQL2022Unsupported' {
            Add-RdsResult 'SSAS / Object store / QAT / TLS 1.3 (SQL 2022)' 'SQL2022Unsupported' 'Manual' 'SQL 2022 items (SSAS, S3 object-store integration, backup to S3-compatible storage, QAT backup compression, TLS 1.3/MS-TDS 8.0, suspend-for-snapshot, mirroring on Multi-AZ) require manual/architecture review.'
        }
    }
    else {
        Add-RdsResult 'SQL Server 2022-specific features' 'SQL2022Unsupported' 'NotInUse' "Instance is major version $majorVersion (< 16); SQL 2022-specific restrictions do not apply."
    }

    # Return rows ordered by severity (InUse, Error, Manual, NotInUse).
    return $script:RdsResults | Sort-Object `
        @{Expression = { switch ($_.Status) { 'InUse' { 0 } 'Error' { 1 } 'Manual' { 2 } 'NotInUse' { 3 } } } }, `
        Category, Feature
}

# Define all queries
$queries = @(
    @{
        Name = "Wait Statistics"
        Query = @"
WITH Uptime AS (
    SELECT DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) AS UptimeInSeconds
    FROM sys.dm_os_sys_info
),
WaitStats AS (
    SELECT 
        wait_type,
        wait_time_ms,
        waiting_tasks_count,
        signal_wait_time_ms,
        wait_time_ms - signal_wait_time_ms AS resource_wait_time_ms
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN (
        -- Filter out benign waits
        'CLR_SEMAPHORE', 'LAZYWRITER_SLEEP', 'RESOURCE_QUEUE', 'SLEEP_TASK',
        'SLEEP_SYSTEMTASK', 'SQLTRACE_BUFFER_FLUSH', 'WAITFOR', 'LOGMGR_QUEUE',
        'CHECKPOINT_QUEUE', 'REQUEST_FOR_DEADLOCK_SEARCH', 'XE_TIMER_EVENT',
        'BROKER_TO_FLUSH', 'BROKER_TASK_STOP', 'CLR_MANUAL_EVENT',
        'CLR_AUTO_EVENT', 'DISPATCHER_QUEUE_SEMAPHORE', 'FT_IFTS_SCHEDULER_IDLE_WAIT',
        'XE_DISPATCHER_WAIT', 'XE_DISPATCHER_JOIN'
    )
    AND wait_time_ms > 0
    AND waiting_tasks_count > 0
)
SELECT TOP 30
    ws.wait_type,
    ws.wait_time_ms,
    CAST(ws.wait_time_ms / 1000.0 / 60.0 AS DECIMAL(18,2)) AS wait_time_minutes,
    ws.waiting_tasks_count,
    CAST(ws.wait_time_ms / NULLIF(ws.waiting_tasks_count, 0) AS DECIMAL(18,2)) AS avg_wait_time_ms,
    CAST(ws.waiting_tasks_count / CAST(u.UptimeInSeconds AS FLOAT) AS DECIMAL(18,2)) AS avg_waits_per_second,
    
    -- Improved impact metrics
    CAST((ws.wait_time_ms / 1000.0) / u.UptimeInSeconds * 100 AS DECIMAL(18,2)) AS pct_of_total_time,
    CAST(ws.wait_time_ms / (SELECT SUM(wait_time_ms) FROM WaitStats) * 100 AS DECIMAL(18,2)) AS pct_of_wait_time,
    
    -- Resource vs Signal wait breakdown
    CAST(ws.resource_wait_time_ms / 1000.0 / 60.0 AS DECIMAL(18,2)) AS resource_wait_minutes,
    CAST(ws.signal_wait_time_ms / 1000.0 / 60.0 AS DECIMAL(18,2)) AS signal_wait_minutes,
    
    -- Comprehensive impact score (0-100 scale)
    CAST(
        (ws.wait_time_ms / (SELECT SUM(wait_time_ms) FROM WaitStats) * 50) +  -- 50% weight on total wait time
        (CASE 
            WHEN ws.wait_time_ms / NULLIF(ws.waiting_tasks_count, 0) > 100 THEN 25  -- High avg wait = 25 points
            WHEN ws.wait_time_ms / NULLIF(ws.waiting_tasks_count, 0) > 10 THEN 15   -- Medium avg wait = 15 points
            ELSE 5  -- Low avg wait = 5 points
        END) +
        (CASE 
            WHEN ws.waiting_tasks_count / CAST(u.UptimeInSeconds AS FLOAT) > 10 THEN 25  -- High frequency = 25 points
            WHEN ws.waiting_tasks_count / CAST(u.UptimeInSeconds AS FLOAT) > 1 THEN 15   -- Medium frequency = 15 points
            ELSE 5  -- Low frequency = 5 points
        END)
        AS DECIMAL(18,2)
    ) AS impact_score,
    
    -- Sizing recommendations based on wait type
    CASE 
        WHEN ws.wait_type IN ('PAGEIOLATCH_SH', 'PAGEIOLATCH_EX', 'PAGEIOLATCH_UP') THEN 'Storage IOPS'
        WHEN ws.wait_type IN ('WRITELOG', 'LOGMGR', 'LOGBUFFER') THEN 'Log Storage'
        WHEN ws.wait_type IN ('SOS_SCHEDULER_YIELD', 'CXPACKET', 'CXCONSUMER') THEN 'CPU Cores'
        WHEN ws.wait_type IN ('RESOURCE_SEMAPHORE', 'CMEMTHREAD') THEN 'Memory'
        WHEN ws.wait_type IN ('LCK_M_%') THEN 'Concurrency'
        WHEN ws.wait_type IN ('ASYNC_NETWORK_IO', 'NETWORKIO') THEN 'Network'
        WHEN ws.wait_type LIKE 'HADR_%' THEN 'HA Network'
        ELSE 'General'
    END AS sizing_category

FROM WaitStats ws
CROSS JOIN Uptime u
ORDER BY impact_score DESC;
"@
        OutputFile = "SQLServerWaitStats.csv"
    },
    @{
        Name = "SQL Server Files"
        Query = @"
SELECT 
    DB_NAME(vfs.database_id) AS database_name,
    vfs.file_id,
    mf.name AS file_name,
    mf.physical_name AS file_path,
    CAST(mf.size AS FLOAT) * 8 / 1024 AS size_mb,
    vfs.num_of_reads,
    CAST(vfs.num_of_bytes_read AS FLOAT) / 1024 AS num_of_kb_read,
    vfs.io_stall_read_ms,
    vfs.num_of_writes,
    CAST(vfs.num_of_bytes_written AS FLOAT) / 1024 AS num_of_kb_written,
    vfs.io_stall_write_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
ORDER BY vfs.io_stall_read_ms DESC;
"@
        OutputFile = "SQLServerFiles.csv"
    },
    @{
        Name = "Execution Plan Statistics"
        Query = @"
SELECT TOP 100
    SUBSTRING(t.text, (s.statement_start_offset/2)+1,
        ((CASE s.statement_end_offset
            WHEN -1 THEN DATALENGTH(t.text)
            ELSE s.statement_end_offset
        END - s.statement_start_offset)/2) + 1) AS sql_text,
    s.execution_count,
    s.total_elapsed_time / 1000000.0 AS total_elapsed_time_sec,
    s.total_elapsed_time / NULLIF(s.execution_count, 0) / 1000.0 AS avg_elapsed_time_ms,
    s.total_worker_time / NULLIF(s.execution_count, 0) / 1000.0 AS avg_cpu_time_ms,
    s.total_physical_reads / NULLIF(s.execution_count, 0) AS avg_physical_reads,
    s.total_logical_reads / NULLIF(s.execution_count, 0) AS avg_logical_reads,
    s.total_logical_writes / NULLIF(s.execution_count, 0) AS avg_logical_writes,
    s.max_grant_kb / 1024.0 AS max_memory_grant_mb,
    s.total_grant_kb / NULLIF(s.execution_count, 0) / 1024.0 AS avg_memory_grant_mb,
    s.max_used_grant_kb / 1024.0 AS max_used_memory_mb,
    s.total_rows / NULLIF(s.execution_count, 0) AS avg_rows_returned,
    s.max_elapsed_time / 1000.0 AS max_elapsed_time_ms,
    s.max_worker_time / 1000.0 AS max_cpu_time_ms,
    s.creation_time,
    s.last_execution_time,
    -- Resource intensity score for sizing (experimantal)
    (s.total_worker_time * 0.4 + s.total_physical_reads * 0.3 + s.total_grant_kb * 0.3) / NULLIF(s.execution_count, 0) AS resource_intensity_score
FROM sys.dm_exec_query_stats AS s
CROSS APPLY sys.dm_exec_sql_text(s.sql_handle) AS t
WHERE s.execution_count >= 5  -- Lower threshold for better coverage
    AND s.total_elapsed_time > 1000000  -- Only queries taking >1 second total
    AND t.text NOT LIKE '%sys.dm_%'  -- Exclude DMV queries
ORDER BY resource_intensity_score DESC;
"@
        OutputFile = "SQLServerExecutionPlanStats.csv"
    },
    @{
        Name = "OS Information"
        Query = @"
SELECT 
    virtual_machine_type_desc AS [virtualized?],
    cpu_count AS Cores,
    hyperthread_ratio AS Hyperthreading,
    CAST(physical_memory_kb AS FLOAT) / 1024 / 1024 AS Memory_in_GB,
    DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) AS UptimeInSeconds
FROM sys.dm_os_sys_info;
"@
        OutputFile = "SQLServerOSinfo.csv"
    },
    @{
        Name = "SQL Server Information"
        Query = @"
SELECT 
    SERVERPROPERTY('ProductVersion') AS [ProductVersion],
    SERVERPROPERTY('ProductLevel') AS [ProductLevel],
    SERVERPROPERTY('Edition') AS [Edition],
    SERVERPROPERTY('EngineEdition') AS [EngineEdition],
    SERVERPROPERTY('ProductUpdateLevel') AS [ProductUpdateLevel],
    SERVERPROPERTY('ProductBuildType') AS [ProductBuildType],
    SERVERPROPERTY('InstanceName') AS [InstanceName],
    SERVERPROPERTY('MachineName') AS [MachineName],
    SERVERPROPERTY('IsClustered') AS [IsClustered]
"@
        OutputFile = "SQLServerInfo.csv"
    },
    @{
        Name = "Memory State"
        Query = @"
SELECT 
    total_physical_memory_kb / 1024 AS [Total_Physical_Memory_MB],
    available_physical_memory_kb / 1024 AS [Available_Physical_Memory_MB],
    total_page_file_kb / 1024 AS [Total_Page_File_MB],
    available_page_file_kb / 1024 AS [Available_Page_File_MB],
    system_memory_state_desc AS [SystemMemoryState]
FROM sys.dm_os_sys_memory;
"@
        OutputFile = "SQLServerMemoryState.csv"
    },
    @{
        Name = "Index Usage Profile"
        Query = @"
WITH reads_and_writes AS (
    SELECT 
        db.name AS database_name,
        SUM(user_seeks + user_scans + user_lookups) AS reads,
        SUM(user_updates) AS writes,
        SUM(user_seeks + user_scans + user_lookups + user_updates) AS all_activity
    FROM sys.dm_db_index_usage_stats us
    INNER JOIN sys.databases db ON us.database_id = db.database_id
    GROUP BY db.name
)
SELECT 
    database_name,
    reads,
    FORMAT(((reads * 1.0) / all_activity),'P') AS reads_percent,
    writes,
    FORMAT(((writes * 1.0) / all_activity),'P') AS writes_percent
FROM reads_and_writes rw
ORDER BY database_name;
"@
        OutputFile = "SQLServerIndexUsageStats.csv"
    },
    @{
        Name = "SQL Configuration"
        Query = @"
SELECT 
    name,
    CAST(value AS INT) AS ConfiguredValue,
    CAST(value_in_use AS INT) AS EffectiveValue
FROM sys.configurations
WHERE name IN ('max degree of parallelism', 'cost threshold for parallelism');
"@
        OutputFile = "SQLServerConfig.csv"
    },
    @{
        Name = "Physical I/O per Database"
        Query = @"
SELECT 
    DB_NAME(mf.database_id) AS database_name,
    SUM(vfs.num_of_reads) AS total_physical_reads,
    SUM(vfs.num_of_writes) AS total_physical_writes,
    SUM(vfs.num_of_reads + vfs.num_of_writes) AS total_io,
    FORMAT(
        (SUM(vfs.num_of_reads) * 1.0 / NULLIF(SUM(vfs.num_of_reads + vfs.num_of_writes), 0)),
        'P'
    ) AS reads_percent,
    FORMAT(
        (SUM(vfs.num_of_writes) * 1.0 / NULLIF(SUM(vfs.num_of_reads + vfs.num_of_writes), 0)),
        'P'
    ) AS writes_percent
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
GROUP BY mf.database_id
ORDER BY total_io DESC;
"@
        OutputFile = "SQLServerPhysicalIO.csv"
    },
    @{
        Name = "High Availability Configuration"
        Query = @"
SELECT 'Availability Group' AS HA_Type,
    ag.name AS AG_Name,
    ar.replica_server_name AS Server_Name,
    ar.availability_mode_desc AS Availability_Mode,
    ar.failover_mode_desc AS Failover_Mode,
    ars.role_desc AS Current_Role,
    ars.operational_state_desc AS Operational_State,
    ars.connected_state_desc AS Connected_State,
    ars.synchronization_health_desc AS Sync_Health
FROM sys.availability_groups ag
INNER JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
INNER JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ar.replica_server_name = @@SERVERNAME

UNION ALL

SELECT 'Failover Cluster Instance' AS HA_Type,
    NodeName AS AG_Name,
    NodeName AS Server_Name,
    'N/A' AS Availability_Mode,
    'N/A' AS Failover_Mode,
    CASE 
        WHEN status_description = 'up' THEN 'ACTIVE'
        ELSE 'PASSIVE'
    END AS Current_Role,
    status_description AS Operational_State,
    'N/A' AS Connected_State,
    'N/A' AS Sync_Health
FROM sys.dm_os_cluster_nodes
WHERE NodeName = CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS NVARCHAR(128))

UNION ALL

SELECT 'Standalone Instance' AS HA_Type,
    @@SERVERNAME AS AG_Name,
    @@SERVERNAME AS Server_Name,
    'N/A' AS Availability_Mode,
    'N/A' AS Failover_Mode,
    'N/A' AS Current_Role,
    'N/A' AS Operational_State,
    'N/A' AS Connected_State,
    'N/A' AS Sync_Health
WHERE NOT EXISTS (SELECT 1 FROM sys.availability_groups)
  AND NOT EXISTS (SELECT 1 FROM sys.dm_os_cluster_nodes);
"@
        OutputFile = "SQLServerHAConfig.csv"
    },
    @{
        Name = "CPU Utilization"
        Query = @"
DECLARE @ts_now bigint = (
    SELECT CASE 
        WHEN ms_ticks = 0 THEN cpu_ticks 
        ELSE cpu_ticks/(cpu_ticks/ms_ticks) 
    END
    FROM sys.dm_os_sys_info
);

SELECT TOP 256
    DATEADD(ms, -1 * (@ts_now - [timestamp]), GETDATE()) AS EventTime,
    SQLProcessUtilization AS SQL_CPU_Usage,
    SystemIdle AS System_Idle,
    100 - SystemIdle - SQLProcessUtilization AS Other_Process_CPU_Usage
FROM (
    SELECT 
        record.value('(./Record/@id)[1]', 'int') AS record_id,
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemIdle,
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS SQLProcessUtilization,
        timestamp
    FROM (
        SELECT timestamp, CONVERT(xml, record) AS record
        FROM sys.dm_os_ring_buffers
        WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
        AND record LIKE '%<SystemHealth>%'
    ) AS x
) AS y
ORDER BY record_id DESC;
"@
        OutputFile = "SQLCPUUtilisation.csv"
    }
)

# Execute queries with progress indication
Write-Log "Starting data collection from $($queries.Count) queries"
$csvFiles = @()

for ($i = 0; $i -lt $queries.Count; $i++) {
    $query = $queries[$i]
    $percentComplete = [math]::Round((($i + 1) / $queries.Count) * 100, 0)
    
    Write-Progress -Activity "Collecting SQL Server Metrics" -Status $query.Name -PercentComplete $percentComplete
    Write-Log "Executing query: $($query.Name)"
    
    try {
        $sqlParams["Query"] = $query.Query
        $outputPath = "$DestinationFolder\$($server)-$($query.OutputFile)"
        
        $result = Invoke-Sqlcmd @sqlParams
        $result | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8
        
        $csvFiles += $outputPath
        Write-Log "Completed: $($query.Name) -> $($query.OutputFile)"
        
    } catch {
        Write-Log "Failed to execute query '$($query.Name)': $_" "ERROR"
        # Continue with other queries instead of failing completely
    }
}

# Collect CPU specifications from WMI
Write-Progress -Activity "Collecting SQL Server Metrics" -Status "CPU Specifications" -PercentComplete 90
Write-Log "Collecting CPU specifications"

try {
    $cpuOutputPath = "$DestinationFolder\$($server)-CpuSpecs.csv"
    Get-CimInstance Win32_Processor | Select-Object Name, MaxClockSpeed | Export-Csv -Path $cpuOutputPath -NoTypeInformation -Encoding UTF8
    $csvFiles += $cpuOutputPath
    Write-Log "Completed: CPU Specifications -> CpuSpecs.csv"
} catch {
    Write-Log "Failed to collect CPU specifications: $_" "WARNING"
}

# Run Amazon RDS for SQL Server eligibility assessment (optional, off by default)
if ($TestRdsEligibility) {
    Write-Progress -Activity "Collecting SQL Server Metrics" -Status "Amazon RDS Eligibility" -PercentComplete 95
    Write-Log "Running Amazon RDS for SQL Server eligibility assessment"

    try {
        $rdsResults = Invoke-RdsEligibilityAssessment
        $rdsOutputPath = "$DestinationFolder\$($server)-RDSEligibility.csv"
        $rdsResults | Export-Csv -Path $rdsOutputPath -NoTypeInformation -Encoding UTF8
        $csvFiles += $rdsOutputPath

        $rdsInUse = @($rdsResults | Where-Object { $_.Status -eq 'InUse' })
        $rdsManual = @($rdsResults | Where-Object { $_.Status -eq 'Manual' })
        $rdsErrors = @($rdsResults | Where-Object { $_.Status -eq 'Error' })
        Write-Log "RDS eligibility complete: $($rdsInUse.Count) feature(s) in use, $($rdsManual.Count) need manual review, $($rdsErrors.Count) check error(s) -> RDSEligibility.csv"
        foreach ($b in $rdsInUse) {
            Write-Log "RDS blocker: [$($b.Category)] $($b.Feature) -> $($b.Detail)" "WARNING"
        }
    } catch {
        Write-Log "Failed to run RDS eligibility assessment: $_" "WARNING"
    }
}
else {
    Write-Log "RDS eligibility assessment skipped (use -TestRdsEligibility to enable)"
}

Write-Progress -Activity "Collecting SQL Server Metrics" -Completed

# Create ZIP archive
Write-Log "Creating ZIP archive"
try {
    if ($IncludeTimestamp) {
        $zipName = "$($server)-SQLAssessment_$((Get-Date -Format 'yyyyMMdd_HHmmss')).zip"
    } else {
        $zipName = "$($server)-SQLAssessment.zip"
    }
    
    $destinationZip = Join-Path -Path $DestinationFolder -ChildPath $zipName
    
    # Create the zip file
    Compress-Archive -Path $csvFiles -DestinationPath $destinationZip -Force
    
    # Verify zip file was created
    if (Test-Path -Path $destinationZip) {
        $zipSize = [math]::Round((Get-Item $destinationZip).Length / 1MB, 2)
        Write-Log "Successfully created zip file: $destinationZip ($zipSize MB)"
        
        # Clean up CSV files if requested
        if ($CleanupCsvFiles) {
            Write-Log "Cleaning up temporary CSV files"
            try {
                $csvFiles | ForEach-Object { Remove-Item $_ -Force }
                Write-Log "Cleaned up $($csvFiles.Count) CSV files"
            } catch {
                Write-Log "Warning: Failed to clean up some CSV files: $_" "WARNING"
            }
        }
        
    } else {
        throw "Failed to create zip file"
    }
    
} catch {
    Write-Log "Failed to create ZIP archive: $_" "ERROR"
    exit 1
}

Write-Log "Assessment completed successfully"
Write-Log "Output: $destinationZip"
Write-Log "Log file: $DestinationFolder\assessment.log"
