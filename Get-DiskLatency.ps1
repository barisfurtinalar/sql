<#
.SYNOPSIS
    Collects disk latency metrics for a specified drive letter.
.DESCRIPTION
    This script measures disk latency (read, write, and total) for a specified drive letter
    using performance counters and outputs the results.
.PARAMETER DriveLetter
    The drive letter to monitor (without colon, e.g., "C").
.PARAMETER SampleInterval
    The interval in seconds between samples (default: 5 seconds).
.PARAMETER SampleCount
    The number of samples to collect (default: 6).
.EXAMPLE
    .\Get-DiskLatency.ps1 -DriveLetter C
.EXAMPLE
    .\Get-DiskLatency.ps1 -DriveLetter D -SampleInterval 2 -SampleCount 10
#>

param (
    [Parameter(Mandatory=$true, HelpMessage="Drive letter to monitor (e.g., 'C')")]
    [ValidatePattern("^[A-Za-z]$")]
    [string]$DriveLetter,
    
    [Parameter(HelpMessage="Sample interval in seconds")]
    [int]$SampleInterval = 5,
    
    [Parameter(HelpMessage="Number of samples to collect")]
    [int]$SampleCount = 6
)

# Initialize performance counters
$counters = @(
    "\LogicalDisk($DriveLetter`:)\Avg. Disk sec/Read",    # Average read latency
    "\LogicalDisk($DriveLetter`:)\Avg. Disk sec/Write",   # Average write latency
    "\LogicalDisk($DriveLetter`:)\Avg. Disk sec/Transfer" # Average total latency
)

try {
    # Get the counters
    $perfCounters = Get-Counter -Counter $counters -ErrorAction Stop
    
    Write-Host "Collecting disk latency metrics for drive $DriveLetter`:"
    Write-Host "Sampling every $SampleInterval seconds for $SampleCount samples`n"
    
    # Format header
    $header = @"
Timestamp               Drive ReadLatency(ms) WriteLatency(ms) TotalLatency(ms)
--------               ----- -------------- --------------- ---------------
"@
    Write-Host $header
    
    # Collect samples
    for ($i = 0; $i -lt $SampleCount; $i++) {
        $sample = Get-Counter -Counter $counters
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        
        $readLatency = [math]::Round($sample.CounterSamples[0].CookedValue * 1000, 2)
        $writeLatency = [math]::Round($sample.CounterSamples[1].CookedValue * 1000, 2)
        $totalLatency = [math]::Round($sample.CounterSamples[2].CookedValue * 1000, 2)
        
        # Format output
        $output = "{0} {1}:     {2,10:N2} {3,15:N2} {4,16:N2}" -f $timestamp, $DriveLetter, $readLatency, $writeLatency, $totalLatency
        Write-Host $output
        
        if ($i -lt $SampleCount - 1) {
            Start-Sleep -Seconds $SampleInterval
        }
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host "Available logical disks:" -ForegroundColor Yellow
    Get-Counter -ListSet "LogicalDisk" | Select-Object -ExpandProperty Counter | Where-Object { $_ -like "*Avg. Disk sec*" } | ForEach-Object {
        $disk = ($_ -split "\\|\)")[2]
        if ($disk -notlike "_Total") {
            Write-Host "  $disk"
        }
    }
    exit 1
}
