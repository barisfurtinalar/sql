 <#
.SYNOPSIS
    Continuously tests SQL Server connection and reports response time in milliseconds.
.DESCRIPTION
    This script tests the connection to a SQL Server instance by executing a simple query
    and measures the response time in milliseconds. It runs continuously until stopped.
.PARAMETER ServerInstance
    The SQL Server instance name (e.g. 'localhost', 'server\instance').
.PARAMETER Database
    The database name to connect to (defaults to 'master' if not specified).
.PARAMETER Username
    The SQL Server username (leave empty for Windows Authentication).
.PARAMETER Password
    The SQL Server password (required if Username is specified).
.PARAMETER Interval
    The interval in seconds between tests (default is 1 second).
.EXAMPLE
    .\Test-SqlConnection.ps1 -ServerInstance "localhost" -Database "master"
.EXAMPLE
    .\Test-SqlConnection.ps1 -ServerInstance "sqlserver\instance" -Database "mydb" -Username "sa" -Password "mypassword" -Interval 2
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$ServerInstance,
    
    [string]$Database = "master",
    
    [string]$Username,
    
    [string]$Password,
    
    [int]$Interval = 1
)

# Load the SQL Server module if not already loaded
if (-not (Get-Module -Name SqlServer -ErrorAction SilentlyContinue)) {
    try {
        Import-Module SqlServer -ErrorAction Stop
    }
    catch {
        Write-Error "SqlServer module not found. Please install it using: Install-Module -Name SqlServer -Force -AllowClobber"
        exit 1
    }
}

# Prepare connection parameters
$connectionParams = @{
    ServerInstance = $ServerInstance
    Database = $Database
}

# Add credentials if provided
if ($Username -and $Password) {
    $connectionParams.Add("Username", $Username)
    $connectionParams.Add("Password", $Password)
}

# Test query (simple and lightweight)
$testQuery = "SELECT 1 AS TestValue"

# Header output
Write-Host "SQL Server Connection Test - Response Time Monitoring"
Write-Host "Server: $ServerInstance"
Write-Host "Database: $Database"
Write-Host "Press Ctrl+C to stop..."
Write-Host "----------------------------------------"
Write-Host "Date        Timestamp   | Response Time (ms)"
Write-Host "----------------------------------------"

try {
    # Continuous loop
    while ($true) {
        $startTime = Get-Date
        
        try {
            # Execute the query and measure time
            $result = Invoke-Sqlcmd @connectionParams -Query $testQuery -QueryTimeout 3 -ErrorAction Stop -TrustServerCertificate
            
            $endTime = Get-Date
            $responseTime = [math]::Round(($endTime - $startTime).TotalMilliseconds, 2)
            
            # Output the result with timestamp
            Write-Host "$($startTime.ToString('yyyy-MM-dd HH:mm:ss.fff')) | $responseTime ms"
        }
        catch {
            $endTime = Get-Date
            $responseTime = [math]::Round(($endTime - $startTime).TotalMilliseconds, 2)
            
            # Output error in red
            Write-Host "$($startTime.ToString('yyyy-MM-dd HH:mm:ss.fff')) | $responseTime ms (ERROR: $($_.Exception.Message))" -ForegroundColor Red
        }
        
        # Wait for the specified interval
        Start-Sleep -Seconds $Interval
    }
}
finally {
    Write-Host "`nMonitoring stopped." -ForegroundColor Yellow
} 
