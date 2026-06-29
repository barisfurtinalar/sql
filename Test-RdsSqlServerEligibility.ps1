<#
.SYNOPSIS
    Evaluates a Microsoft SQL Server instance for eligibility to migrate to
    Amazon RDS for SQL Server by detecting usage of unsupported features and
    features with limited support.

.DESCRIPTION
    This tool connects to a SQL Server instance and runs a battery of T-SQL
    checks against the list of features that Amazon RDS for SQL Server does not
    support, or supports only in a limited fashion.

    Reference:
    https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/SQLServer.Concepts.General.FeatureNonSupport.html

    Each check reports one of the following statuses:
        InUse        - The feature appears to be in use (migration blocker / risk).
        NotInUse     - The feature was checked and is not in use.
        Manual       - The feature cannot be reliably detected via T-SQL and
                       requires manual review.
        Error        - The check failed to run (e.g. permissions, version).

.PARAMETER ServerInstance
    The SQL Server instance to evaluate, e.g. "localhost", "SQLPROD01\INST1",
    or "10.0.0.5,1433". Defaults to "localhost" so the script can be run directly
    on the SQL Server host with no arguments (Windows authentication).

    Local connection shortcuts: "localhost", ".", "(local)", or
    "localhost\INSTANCENAME" for a named instance.

.PARAMETER Database
    The initial database to connect to. Defaults to "master". Instance-wide and
    per-database checks are run regardless of this value.

.PARAMETER Username
    SQL authentication user name. If omitted, Windows (integrated) authentication
    is used.

.PARAMETER Password
    SQL authentication password. Used with -Username.

.PARAMETER OutputPath
    Optional path to write a report. The format is inferred from the file
    extension (.csv or .html). If omitted, results are written to the console only.

.PARAMETER ConnectionTimeout
    Connection timeout in seconds. Default 15.

.PARAMETER QueryTimeout
    Per-query timeout in seconds. Default 30.

.EXAMPLE
    # Run directly on the SQL Server host using Windows authentication.
    .\Test-RdsSqlServerEligibility.ps1

.EXAMPLE
    .\Test-RdsSqlServerEligibility.ps1 -ServerInstance "localhost\SQLEXPRESS"

.EXAMPLE
    .\Test-RdsSqlServerEligibility.ps1 -ServerInstance "SQLPROD01" -Username sa -Password 'P@ss' -OutputPath .\report.html

.NOTES
    Requires read access to server-level DMVs/catalog views and the ability to
    enumerate databases. VIEW SERVER STATE and membership that allows reading
    sys.* catalog views is recommended.
#>
[CmdletBinding()]
param(
    [string]$ServerInstance = 'localhost',

    [string]$Database = 'master',

    [string]$Username,

    [string]$Password,

    [string]$OutputPath,

    [int]$ConnectionTimeout = 15,

    [int]$QueryTimeout = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Connection helpers ---------------------------------------------------

function New-SqlConnectionString {
    param(
        [string]$Server,
        [string]$Db,
        [string]$User,
        [string]$Pass,
        [int]$Timeout
    )
    $sb = "Server=$Server;Database=$Db;Connect Timeout=$Timeout;Application Name=RdsEligibilityCheck;"
    if ([string]::IsNullOrWhiteSpace($User)) {
        $sb += 'Integrated Security=SSPI;'
    }
    else {
        # Escape any embedded quotes in the password by wrapping in single quotes.
        $escaped = $Pass -replace "'", "''"
        $sb += "User ID=$User;Password='$escaped';"
    }
    return $sb
}

function Invoke-Sql {
    <#
        Runs a query and returns a DataTable. Throws on failure so callers can
        translate exceptions into an 'Error' status.
    #>
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$Query,
        [int]$Timeout
    )
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = $Timeout
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    $table = New-Object System.Data.DataTable
    [void]$adapter.Fill($table)
    # Return with the unary comma so PowerShell does NOT enumerate the DataTable
    # into individual DataRow objects. Without this, callers receive rows instead
    # of the table and ".Rows" fails.
    return , $table
}

#endregion

#region Result model ---------------------------------------------------------

$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Feature,
        [ValidateSet('Unsupported', 'LimitedSupport', 'SQL2022Unsupported')]
        [string]$Category,
        [ValidateSet('InUse', 'NotInUse', 'Manual', 'Error')]
        [string]$Status,
        [string]$Detail
    )
    $script:Results.Add([pscustomobject]@{
            Feature  = $Feature
            Category = $Category
            Status   = $Status
            Detail   = $Detail
        })
}

#endregion

#region Generic helpers ------------------------------------------------------

function ConvertTo-HtmlEncoded {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}


function Test-ScalarCount {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$Query,
        [int]$Timeout
    )
    $t = Invoke-Sql -Connection $Connection -Query $Query -Timeout $Timeout
    if ($t.Rows.Count -eq 0) { return 0 }
    if ($t.Rows[0][0] -eq [DBNull]::Value) { return 0 }
    return [int]$t.Rows[0][0]
}

function Get-UserDatabases {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [int]$Timeout
    )
    # Only online databases we can actually query. Exclude system DBs for
    # per-database object scans (system DBs are recreated by RDS anyway).
    $q = @"
SELECT name
FROM sys.databases
WHERE state = 0
  AND database_id > 4
  AND source_database_id IS NULL
ORDER BY name;
"@
    $t = Invoke-Sql -Connection $Connection -Query $q -Timeout $Timeout
    return @($t | ForEach-Object { $_.name })
}

function Invoke-PerDatabase {
    <#
        Runs a count query in every user database and returns a hashtable of
        DatabaseName -> count for databases where count > 0.
    #>
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string[]]$Databases,
        [string]$CountQuery,
        [int]$Timeout
    )
    $hits = @{}
    foreach ($db in $Databases) {
        $safe = $db -replace ']', ']]'
        $scoped = "USE [$safe];`n$CountQuery"
        try {
            $c = Test-ScalarCount -Connection $Connection -Query $scoped -Timeout $Timeout
            if ($c -gt 0) { $hits[$db] = $c }
        }
        catch {
            # Record the database as un-scannable but keep going.
            $hits["$db (scan error)"] = $_.Exception.Message
        }
    }
    return $hits
}

#endregion

#region Check wrappers -------------------------------------------------------

function Invoke-Check {
    param(
        [string]$Feature,
        [string]$Category,
        [scriptblock]$Body
    )
    try {
        & $Body
    }
    catch {
        Add-Result -Feature $Feature -Category $Category -Status 'Error' -Detail $_.Exception.Message
    }
}

function Get-SqlMajorVersion {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [int]$Timeout
    )
    $t = Invoke-Sql -Connection $Connection -Query "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) AS v" -Timeout $Timeout
    if ($t.Rows.Count -gt 0 -and $t.Rows[0][0] -ne [DBNull]::Value) {
        return [int]$t.Rows[0][0]
    }
    $t2 = Invoke-Sql -Connection $Connection -Query "SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)) AS v" -Timeout $Timeout
    $ver = [string]$t2.Rows[0][0]
    return [int]($ver.Split('.')[0])
}

#endregion

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

$connString = New-SqlConnectionString -Server $ServerInstance -Db $Database -User $Username -Pass $Password -Timeout $ConnectionTimeout
$conn = New-Object System.Data.SqlClient.SqlConnection $connString

try {
    Write-Host "Connecting to '$ServerInstance'..." -ForegroundColor Cyan
    $conn.Open()
}
catch {
    Write-Error "Failed to connect to '$ServerInstance': $($_.Exception.Message)"
    exit 1
}

try {
    $majorVersion = Get-SqlMajorVersion -Connection $conn -Timeout $QueryTimeout
    $verRow = Invoke-Sql -Connection $conn -Query "SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)) AS pv, CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) AS ed" -Timeout $QueryTimeout
    $productVersion = [string]$verRow.Rows[0]['pv']
    $edition = [string]$verRow.Rows[0]['ed']
    Write-Host "Connected. SQL Server $productVersion ($edition), major version $majorVersion." -ForegroundColor Green
    Write-Host ""
}
catch {
    Write-Warning "Could not determine SQL Server version: $($_.Exception.Message)"
    $majorVersion = 0
    $productVersion = 'unknown'
    $edition = 'unknown'
}

Write-Host "Enumerating user databases..." -ForegroundColor Cyan
$userDbs = @()
try {
    $userDbs = Get-UserDatabases -Connection $conn -Timeout $QueryTimeout
    Write-Host ("Found {0} user database(s): {1}" -f $userDbs.Count, ($userDbs -join ', ')) -ForegroundColor Green
}
catch {
    Write-Warning "Could not enumerate databases: $($_.Exception.Message)"
}
Write-Host ""
Write-Host "Running eligibility checks..." -ForegroundColor Cyan

# =====================================================================
# UNSUPPORTED FEATURES
# =====================================================================

# --- Database Log Shipping ---
Invoke-Check 'Database Log Shipping' 'Unsupported' {
    $q = "SELECT COUNT(*) FROM msdb.dbo.log_shipping_primary_databases"
    $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout
    $q2 = "SELECT COUNT(*) FROM msdb.dbo.log_shipping_secondary_databases"
    $c2 = Test-ScalarCount -Connection $conn -Query $q2 -Timeout $QueryTimeout
    if (($c + $c2) -gt 0) {
        Add-Result 'Database Log Shipping' 'Unsupported' 'InUse' "Primary configs: $c, Secondary configs: $c2"
    }
    else {
        Add-Result 'Database Log Shipping' 'Unsupported' 'NotInUse' 'No log shipping configurations found.'
    }
}

# --- Database snapshots ---
Invoke-Check 'Database snapshots' 'Unsupported' {
    $q = "SELECT COUNT(*) FROM sys.databases WHERE source_database_id IS NOT NULL"
    $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout
    if ($c -gt 0) {
        Add-Result 'Database snapshots' 'Unsupported' 'InUse' "$c database snapshot(s) present."
    }
    else {
        Add-Result 'Database snapshots' 'Unsupported' 'NotInUse' 'No database snapshots found.'
    }
}

# --- Extended stored procedures (incl. xp_cmdshell) ---
Invoke-Check 'Extended stored procedures (incl. xp_cmdshell)' 'Unsupported' {
    $q = @"
SELECT COUNT(*) FROM sys.extended_procedures;
"@
    $c = 0
    try { $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout } catch { $c = 0 }
    # xp_cmdshell enabled state
    $xpQ = "SELECT CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'xp_cmdshell'"
    $xp = 0
    try { $xp = Test-ScalarCount -Connection $conn -Query $xpQ -Timeout $QueryTimeout } catch { $xp = 0 }
    if ($c -gt 0 -or $xp -gt 0) {
        $detail = "User-defined extended procedures: $c. xp_cmdshell enabled: $([bool]$xp)."
        Add-Result 'Extended stored procedures (incl. xp_cmdshell)' 'Unsupported' 'InUse' $detail
    }
    else {
        Add-Result 'Extended stored procedures (incl. xp_cmdshell)' 'Unsupported' 'NotInUse' 'No user extended procedures; xp_cmdshell disabled.'
    }
}

# --- FILESTREAM ---
Invoke-Check 'FILESTREAM support' 'Unsupported' {
    $cfgQ = "SELECT CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'filestream access level'"
    $cfg = 0
    try { $cfg = Test-ScalarCount -Connection $conn -Query $cfgQ -Timeout $QueryTimeout } catch { $cfg = 0 }
    $fsQuery = "SELECT COUNT(*) FROM sys.database_files WHERE type_desc = 'FILESTREAM'"
    $fsHits = Invoke-PerDatabase -Connection $conn -Databases $userDbs -CountQuery $fsQuery -Timeout $QueryTimeout
    if ($cfg -gt 0 -or $fsHits.Count -gt 0) {
        $dbList = ($fsHits.Keys -join ', ')
        Add-Result 'FILESTREAM support' 'Unsupported' 'InUse' "FILESTREAM access level: $cfg. DBs with FILESTREAM files: $dbList"
    }
    else {
        Add-Result 'FILESTREAM support' 'Unsupported' 'NotInUse' 'FILESTREAM disabled and no FILESTREAM files found.'
    }
}

# --- File tables ---
Invoke-Check 'File tables' 'Unsupported' {
    $q = "SELECT COUNT(*) FROM sys.tables WHERE is_filetable = 1"
    $hits = Invoke-PerDatabase -Connection $conn -Databases $userDbs -CountQuery $q -Timeout $QueryTimeout
    if ($hits.Count -gt 0) {
        Add-Result 'File tables' 'Unsupported' 'InUse' "FileTables found in: $($hits.Keys -join ', ')"
    }
    else {
        Add-Result 'File tables' 'Unsupported' 'NotInUse' 'No FileTables found.'
    }
}

# --- Maintenance plans ---
Invoke-Check 'Maintenance plans' 'Unsupported' {
    $q = "SELECT COUNT(*) FROM msdb.dbo.sysmaintplan_plans"
    $c = 0
    try { $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout } catch { $c = 0 }
    if ($c -gt 0) {
        Add-Result 'Maintenance plans' 'Unsupported' 'InUse' "$c maintenance plan(s) defined."
    }
    else {
        Add-Result 'Maintenance plans' 'Unsupported' 'NotInUse' 'No maintenance plans found.'
    }
}

# --- Performance Data Collector ---
Invoke-Check 'Performance Data Collector' 'Unsupported' {
    $q = "SELECT COUNT(*) FROM msdb.dbo.syscollector_collection_sets WHERE is_running = 1"
    $c = 0
    try { $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout } catch { $c = 0 }
    if ($c -gt 0) {
        Add-Result 'Performance Data Collector' 'Unsupported' 'InUse' "$c running collection set(s)."
    }
    else {
        Add-Result 'Performance Data Collector' 'Unsupported' 'NotInUse' 'No running data collection sets.'
    }
}

# --- Policy-Based Management ---
Invoke-Check 'Policy-Based Management' 'Unsupported' {
    $q = "SELECT COUNT(*) FROM msdb.dbo.syspolicy_policies WHERE is_enabled = 1"
    $c = 0
    try { $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout } catch { $c = 0 }
    if ($c -gt 0) {
        Add-Result 'Policy-Based Management' 'Unsupported' 'InUse' "$c enabled policy/policies."
    }
    else {
        Add-Result 'Policy-Based Management' 'Unsupported' 'NotInUse' 'No enabled policies.'
    }
}

# --- PolyBase ---
Invoke-Check 'PolyBase' 'Unsupported' {
    $q = "SELECT CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'polybase enabled'"
    $c = 0
    try { $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout } catch { $c = 0 }
    if ($c -gt 0) {
        Add-Result 'PolyBase' 'Unsupported' 'InUse' 'PolyBase is enabled.'
    }
    else {
        Add-Result 'PolyBase' 'Unsupported' 'NotInUse' 'PolyBase not enabled (or not installed).'
    }
}

# --- Replication ---
Invoke-Check 'Replication' 'Unsupported' {
    $q = "SELECT COUNT(*) FROM sys.databases WHERE is_published = 1 OR is_subscribed = 1 OR is_merge_published = 1 OR is_distributor = 1"
    $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout
    if ($c -gt 0) {
        Add-Result 'Replication' 'Unsupported' 'InUse' "$c database(s) participate in replication."
    }
    else {
        Add-Result 'Replication' 'Unsupported' 'NotInUse' 'No databases configured for replication.'
    }
}

# --- Server-level triggers ---
Invoke-Check 'Server-level triggers' 'Unsupported' {
    $q = "SELECT COUNT(*) FROM sys.server_triggers WHERE is_disabled = 0"
    $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout
    if ($c -gt 0) {
        Add-Result 'Server-level triggers' 'Unsupported' 'InUse' "$c enabled server-level trigger(s)."
    }
    else {
        Add-Result 'Server-level triggers' 'Unsupported' 'NotInUse' 'No enabled server-level triggers.'
    }
}

# --- Service Broker endpoints ---
Invoke-Check 'Service Broker endpoints' 'Unsupported' {
    $q = "SELECT COUNT(*) FROM sys.service_broker_endpoints"
    $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout
    if ($c -gt 0) {
        Add-Result 'Service Broker endpoints' 'Unsupported' 'InUse' "$c Service Broker endpoint(s)."
    }
    else {
        Add-Result 'Service Broker endpoints' 'Unsupported' 'NotInUse' 'No Service Broker endpoints.'
    }
}

# --- Stretch database ---
Invoke-Check 'Stretch database' 'Unsupported' {
    $q = "SELECT COUNT(*) FROM sys.databases WHERE is_remote_data_archive_enabled = 1"
    $c = 0
    try { $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout } catch { $c = 0 }
    if ($c -gt 0) {
        Add-Result 'Stretch database' 'Unsupported' 'InUse' "$c database(s) Stretch-enabled."
    }
    else {
        Add-Result 'Stretch database' 'Unsupported' 'NotInUse' 'No Stretch-enabled databases.'
    }
}

# --- TRUSTWORTHY database property ---
Invoke-Check 'TRUSTWORTHY database property' 'Unsupported' {
    $q = "SELECT COUNT(*) FROM sys.databases WHERE is_trustworthy_on = 1 AND database_id > 4"
    $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout
    if ($c -gt 0) {
        $names = Invoke-Sql -Connection $conn -Query "SELECT name FROM sys.databases WHERE is_trustworthy_on = 1 AND database_id > 4" -Timeout $QueryTimeout
        $list = ($names | ForEach-Object { $_.name }) -join ', '
        Add-Result 'TRUSTWORTHY database property' 'Unsupported' 'InUse' "TRUSTWORTHY ON for: $list"
    }
    else {
        Add-Result 'TRUSTWORTHY database property' 'Unsupported' 'NotInUse' 'No user databases with TRUSTWORTHY ON.'
    }
}

# --- T-SQL / SOAP endpoints (CREATE ENDPOINT) ---
Invoke-Check 'T-SQL / SOAP endpoints' 'Unsupported' {
    # User-created endpoints have endpoint_id > 65535. We classify them by type:
    #   TSQL / SOAP            -> the actual RDS blocker (CREATE ENDPOINT FOR TSQL/SOAP)
    #   DATABASE_MIRRORING     -> created by Always On AGs / database mirroring; this
    #                             is expected on AG nodes and maps to the separate
    #                             "mirroring/Always On on Multi-AZ" consideration.
    #   SERVICE_BROKER         -> reported by the dedicated Service Broker check.
    $rows = Invoke-Sql -Connection $conn -Query @"
SELECT name, type_desc
FROM sys.endpoints
WHERE endpoint_id > 65535
"@ -Timeout $QueryTimeout

    $tsqlSoap = @($rows | Where-Object { $_.type_desc -in @('TSQL', 'SOAP') })
    $mirroring = @($rows | Where-Object { $_.type_desc -eq 'DATABASE_MIRRORING' })

    if ($tsqlSoap.Count -gt 0) {
        $detail = ($tsqlSoap | ForEach-Object { "$($_.name) [$($_.type_desc)]" }) -join ', '
        Add-Result 'T-SQL / SOAP endpoints' 'Unsupported' 'InUse' "User-created T-SQL/SOAP endpoint(s): $detail"
    }
    elseif ($mirroring.Count -gt 0) {
        $detail = ($mirroring | ForEach-Object { $_.name }) -join ', '
        Add-Result 'T-SQL / SOAP endpoints' 'Unsupported' 'NotInUse' "No T-SQL/SOAP endpoints. Found DATABASE_MIRRORING endpoint(s) ($detail) - expected on Always On/mirroring nodes; see the Always On / Multi-AZ note."
    }
    else {
        Add-Result 'T-SQL / SOAP endpoints' 'Unsupported' 'NotInUse' 'Only default system endpoints present.'
    }
}

# --- Always On Availability Groups (informational) ---
Invoke-Check 'Always On Availability Groups' 'LimitedSupport' {
    $agSupported = "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS INT)"
    $hadr = 0
    try { $hadr = Test-ScalarCount -Connection $conn -Query $agSupported -Timeout $QueryTimeout } catch { $hadr = 0 }
    $agCount = 0
    try { $agCount = Test-ScalarCount -Connection $conn -Query "SELECT COUNT(*) FROM sys.availability_groups" -Timeout $QueryTimeout } catch { $agCount = 0 }
    if ($hadr -gt 0 -and $agCount -gt 0) {
        Add-Result 'Always On Availability Groups' 'LimitedSupport' 'InUse' "$agCount availability group(s) configured. RDS provides HA via Multi-AZ (Always On under the hood); self-managed AG topology is not migrated as-is. The associated DATABASE_MIRRORING endpoint is expected."
    }
    else {
        Add-Result 'Always On Availability Groups' 'LimitedSupport' 'NotInUse' 'HADR not enabled or no availability groups configured.'
    }
}

# --- Custom password policies ---
Invoke-Check 'Custom password policies' 'Unsupported' {
    Add-Result 'Custom password policies' 'Unsupported' 'Manual' 'Custom (Windows/3rd-party) password policies cannot be detected via T-SQL. Review domain/local policy and any custom password filters.'
}

# --- Backing up to Azure Blob Storage ---
Invoke-Check 'Backup to Azure Blob Storage' 'Unsupported' {
    $q = "SELECT COUNT(*) FROM msdb.dbo.backupmediafamily WHERE device_type = 9 OR physical_device_name LIKE 'https://%'"
    $c = 0
    try { $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout } catch { $c = 0 }
    if ($c -gt 0) {
        Add-Result 'Backup to Azure Blob Storage' 'Unsupported' 'InUse' "$c backup(s) to URL/Azure detected in history."
    }
    else {
        Add-Result 'Backup to Azure Blob Storage' 'Unsupported' 'NotInUse' 'No URL/Azure backups found in backup history.'
    }
}

# --- Buffer pool extension ---
Invoke-Check 'Buffer pool extension' 'Unsupported' {
    $q = "SELECT COUNT(*) FROM sys.dm_os_buffer_pool_extension_configuration WHERE state_description <> 'BUFFER POOL EXTENSION DISABLED'"
    $c = 0
    try { $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout } catch { $c = 0 }
    if ($c -gt 0) {
        Add-Result 'Buffer pool extension' 'Unsupported' 'InUse' 'Buffer pool extension is enabled.'
    }
    else {
        Add-Result 'Buffer pool extension' 'Unsupported' 'NotInUse' 'Buffer pool extension disabled.'
    }
}

# --- Data Quality Services / Machine Learning & R / WCF Data Services ---
Invoke-Check 'Data Quality Services (DQS)' 'Unsupported' {
    $q = "SELECT COUNT(*) FROM sys.databases WHERE name IN ('DQS_MAIN','DQS_PROJECTS','DQS_STAGING_DATA')"
    $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout
    if ($c -gt 0) {
        Add-Result 'Data Quality Services (DQS)' 'Unsupported' 'InUse' 'DQS databases present (DQS_MAIN/PROJECTS/STAGING).'
    }
    else {
        Add-Result 'Data Quality Services (DQS)' 'Unsupported' 'NotInUse' 'No DQS databases found.'
    }
}

Invoke-Check 'Machine Learning / R Services' 'Unsupported' {
    $extQ = "SELECT CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'external scripts enabled'"
    $c = 0
    try { $c = Test-ScalarCount -Connection $conn -Query $extQ -Timeout $QueryTimeout } catch { $c = 0 }
    if ($c -gt 0) {
        Add-Result 'Machine Learning / R Services' 'Unsupported' 'InUse' "'external scripts enabled' is on (in-database ML/R/Python in use)."
    }
    else {
        Add-Result 'Machine Learning / R Services' 'Unsupported' 'NotInUse' 'External scripts not enabled.'
    }
}

Invoke-Check 'WCF Data Services' 'Unsupported' {
    Add-Result 'WCF Data Services' 'Unsupported' 'Manual' 'WCF Data Services is an application-layer feature; review application code/IIS, not detectable via T-SQL.'
}

# =====================================================================
# LIMITED SUPPORT FEATURES
# =====================================================================

# --- Linked servers / distributed queries ---
Invoke-Check 'Distributed queries / linked servers' 'LimitedSupport' {
    $q = "SELECT COUNT(*) FROM sys.servers WHERE is_linked = 1"
    $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout
    if ($c -gt 0) {
        $rows = Invoke-Sql -Connection $conn -Query "SELECT name, provider FROM sys.servers WHERE is_linked = 1" -Timeout $QueryTimeout
        $detail = ($rows | ForEach-Object { "$($_.name) [$($_.provider)]" }) -join ', '
        Add-Result 'Distributed queries / linked servers' 'LimitedSupport' 'InUse' "Linked servers: $detail"
    }
    else {
        Add-Result 'Distributed queries / linked servers' 'LimitedSupport' 'NotInUse' 'No linked servers defined.'
    }
}

# --- CLR integration ---
Invoke-Check 'CLR integration' 'LimitedSupport' {
    $cfgQ = "SELECT CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'clr enabled'"
    $cfg = 0
    try { $cfg = Test-ScalarCount -Connection $conn -Query $cfgQ -Timeout $QueryTimeout } catch { $cfg = 0 }
    $asmQuery = "SELECT COUNT(*) FROM sys.assemblies WHERE is_user_defined = 1"
    $asmHits = Invoke-PerDatabase -Connection $conn -Databases $userDbs -CountQuery $asmQuery -Timeout $QueryTimeout
    if ($cfg -gt 0 -or $asmHits.Count -gt 0) {
        $note = if ($majorVersion -ge 14) { ' NOTE: CLR is NOT supported on RDS for SQL Server 2017+.' } else { ' CLR limited to SAFE mode on RDS 2016 and lower.' }
        Add-Result 'CLR integration' 'LimitedSupport' 'InUse' ("clr enabled: $([bool]$cfg). User assemblies in: $($asmHits.Keys -join ', ')." + $note)
    }
    else {
        Add-Result 'CLR integration' 'LimitedSupport' 'NotInUse' 'CLR disabled and no user assemblies.'
    }
}

# --- Linked server with Oracle OLEDB ---
Invoke-Check 'Linked servers with Oracle OLEDB' 'LimitedSupport' {
    $q = "SELECT COUNT(*) FROM sys.servers WHERE is_linked = 1 AND (provider LIKE '%Ora%' OR provider LIKE '%MSDAORA%')"
    $c = Test-ScalarCount -Connection $conn -Query $q -Timeout $QueryTimeout
    if ($c -gt 0) {
        Add-Result 'Linked servers with Oracle OLEDB' 'LimitedSupport' 'InUse' "$c Oracle OLEDB linked server(s)."
    }
    else {
        Add-Result 'Linked servers with Oracle OLEDB' 'LimitedSupport' 'NotInUse' 'No Oracle OLEDB linked servers.'
    }
}

# =====================================================================
# SQL SERVER 2022-SPECIFIC UNSUPPORTED FEATURES
# =====================================================================

if ($majorVersion -ge 16) {
    Invoke-Check 'External Data Source (PolyBase/S3)' 'SQL2022Unsupported' {
        $q = "SELECT COUNT(*) FROM sys.external_data_sources"
        $hits = Invoke-PerDatabase -Connection $conn -Databases $userDbs -CountQuery $q -Timeout $QueryTimeout
        if ($hits.Count -gt 0) {
            Add-Result 'External Data Source (PolyBase/S3)' 'SQL2022Unsupported' 'InUse' "External data sources in: $($hits.Keys -join ', ')"
        }
        else {
            Add-Result 'External Data Source (PolyBase/S3)' 'SQL2022Unsupported' 'NotInUse' 'No external data sources defined.'
        }
    }

    Invoke-Check 'SSAS / Object store / QAT / TLS 1.3 (SQL 2022)' 'SQL2022Unsupported' {
        Add-Result 'SSAS / Object store / QAT / TLS 1.3 (SQL 2022)' 'SQL2022Unsupported' 'Manual' 'SQL 2022 items (SSAS, S3 object-store integration, backup to S3-compatible storage, QAT backup compression, TLS 1.3/MS-TDS 8.0, suspend-for-snapshot, mirroring on Multi-AZ) require manual/architecture review.'
    }
}
else {
    Add-Result 'SQL Server 2022-specific features' 'SQL2022Unsupported' 'NotInUse' "Instance is major version $majorVersion (< 16); SQL 2022-specific restrictions do not apply."
}

# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

try { $conn.Close() } catch { }

$ordered = $script:Results | Sort-Object `
    @{Expression = { switch ($_.Status) { 'InUse' { 0 } 'Error' { 1 } 'Manual' { 2 } 'NotInUse' { 3 } } } }, `
    Category, Feature

Write-Host ""
Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host " Amazon RDS for SQL Server - Migration Eligibility Report" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host (" Instance : {0}" -f $ServerInstance)
Write-Host (" Version  : {0} ({1})" -f $productVersion, $edition)
Write-Host (" Run at   : {0}" -f (Get-Date))
Write-Host ""

foreach ($r in $ordered) {
    $color = switch ($r.Status) {
        'InUse'    { 'Red' }
        'Error'    { 'DarkYellow' }
        'Manual'   { 'Yellow' }
        'NotInUse' { 'Green' }
    }
    $line = "[{0,-9}] {1,-18} {2}" -f $r.Status, $r.Category, $r.Feature
    Write-Host $line -ForegroundColor $color
    if ($r.Status -in @('InUse', 'Error', 'Manual') -and $r.Detail) {
        Write-Host ("              -> {0}" -f $r.Detail) -ForegroundColor Gray
    }
}

$inUse = @($script:Results | Where-Object { $_.Status -eq 'InUse' })
$manual = @($script:Results | Where-Object { $_.Status -eq 'Manual' })
$errors = @($script:Results | Where-Object { $_.Status -eq 'Error' })

Write-Host ""
Write-Host "-------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host (" Summary: {0} feature(s) IN USE, {1} need MANUAL review, {2} check error(s)." -f $inUse.Count, $manual.Count, $errors.Count)
if ($inUse.Count -eq 0) {
    Write-Host " No unsupported features detected via automated checks." -ForegroundColor Green
    Write-Host " Review 'Manual' items before concluding eligibility." -ForegroundColor Yellow
}
else {
    Write-Host " Unsupported/limited features are in use. Review blockers above." -ForegroundColor Red
}
Write-Host "-------------------------------------------------------------------" -ForegroundColor Cyan

# --- File output ---
if ($OutputPath) {
    $ext = [System.IO.Path]::GetExtension($OutputPath).ToLowerInvariant()
    switch ($ext) {
        '.csv' {
            $ordered | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
            Write-Host "CSV report written to: $OutputPath" -ForegroundColor Green
        }
        '.html' {
            $style = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; }
h1 { color: #232f3e; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #ddd; padding: 8px; text-align: left; vertical-align: top; }
th { background: #232f3e; color: #fff; }
tr.InUse td { background: #fdecea; }
tr.Error td { background: #fff4e5; }
tr.Manual td { background: #fffbe6; }
tr.NotInUse td { background: #eafaf1; }
.meta { color: #555; margin-bottom: 16px; }
</style>
"@
            $pre = "<h1>Amazon RDS for SQL Server - Eligibility Report</h1>" +
                   "<div class='meta'>Instance: $(ConvertTo-HtmlEncoded $ServerInstance)<br/>" +
                   "Version: $(ConvertTo-HtmlEncoded $productVersion) ($(ConvertTo-HtmlEncoded $edition))<br/>" +
                   "Generated: $(Get-Date)<br/>" +
                   "In use: $($inUse.Count) | Manual review: $($manual.Count) | Errors: $($errors.Count)</div>"
            $rowsHtml = ($ordered | ForEach-Object {
                "<tr class='$($_.Status)'><td>$($_.Status)</td><td>$($_.Category)</td><td>$(ConvertTo-HtmlEncoded $_.Feature)</td><td>$(ConvertTo-HtmlEncoded ([string]$_.Detail))</td></tr>"
            }) -join "`n"
            $html = "<html><head><meta charset='utf-8'>$style</head><body>$pre<table><tr><th>Status</th><th>Category</th><th>Feature</th><th>Detail</th></tr>$rowsHtml</table></body></html>"
            Set-Content -Path $OutputPath -Value $html -Encoding UTF8
            Write-Host "HTML report written to: $OutputPath" -ForegroundColor Green
        }
        default {
            $ordered | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
            Write-Host "Unrecognized extension '$ext'; wrote CSV to: $OutputPath" -ForegroundColor Yellow
        }
    }
}

# Emit objects to the pipeline so the script is composable.
$ordered

# Exit code: non-zero if any blockers (InUse) detected.
if ($inUse.Count -gt 0) { exit 2 } else { exit 0 }
