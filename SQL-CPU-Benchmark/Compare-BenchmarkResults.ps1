<#
.SYNOPSIS
    Compare SQL Server CPU Benchmark results across multiple servers
.DESCRIPTION
    Reads benchmark results from CSV files and generates comparison report
.PARAMETER CsvPath
    Path to folder containing benchmark CSV files (or single CSV file)
.PARAMETER OutputReport
    Path to save HTML comparison report
.EXAMPLE
    .\Compare-BenchmarkResults.ps1 -CsvPath ".\Results"
.EXAMPLE
    .\Compare-BenchmarkResults.ps1 -CsvPath ".\Results\SqlCpuBenchmark_SERVER1_20240115.csv"
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$CsvPath = ".",
    
    [Parameter()]
    [string]$OutputReport = "BenchmarkComparison.html"
)

function Get-ResultsFromCsv {
    param([string]$Path)
    
    $files = if (Test-Path $Path -PathType Leaf) {
        Get-Item $Path
    } else {
        Get-ChildItem -Path $Path -Filter "SqlCpuBenchmark_*.csv"
    }
    
    $allResults = @()
    foreach ($file in $files) {
        $allResults += Import-Csv $file.FullName
    }
    
    return $allResults
}

function New-ComparisonReport {
    param([array]$Results, [string]$OutputPath)
    
    # Group by machine
    $byMachine = $Results | Group-Object MachineName
    
    # Get unique test names
    $testNames = $Results | Select-Object -ExpandProperty TestName -Unique | Sort-Object
    
    # Build comparison table
    $comparison = @{}
    foreach ($test in $testNames) {
        $comparison[$test] = @{}
        foreach ($machine in $byMachine) {
            $testResult = $machine.Group | Where-Object { $_.TestName -eq $test } | 
                          Sort-Object Timestamp -Descending | Select-Object -First 1
            
            if ($testResult) {
                $metric = if ($testResult.IterationsPerSec -and $testResult.IterationsPerSec -ne '') {
                    [decimal]$testResult.IterationsPerSec
                } elseif ($testResult.RowsPerSec -and $testResult.RowsPerSec -ne '') {
                    [decimal]$testResult.RowsPerSec
                } elseif ($testResult.ThroughputMBps -and $testResult.ThroughputMBps -ne '') {
                    [decimal]$testResult.ThroughputMBps
                } else {
                    [int]$testResult.SqlElapsedMs
                }
                $comparison[$test][$machine.Name] = $metric
            }
        }
    }
    
    # Generate HTML report
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>SQL Server CPU Benchmark Comparison</title>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        h1 { color: #333; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #0078d4; margin-top: 30px; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; background: white; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        th { background: #0078d4; color: white; padding: 12px; text-align: left; }
        td { padding: 10px; border-bottom: 1px solid #ddd; }
        tr:hover { background: #f0f7ff; }
        .best { background: #d4edda; font-weight: bold; }
        .worst { background: #f8d7da; }
        .server-info { background: white; padding: 15px; margin: 10px 0; border-radius: 5px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .metric-label { font-size: 0.8em; color: #666; }
        .chart-container { margin: 20px 0; }
    </style>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
</head>
<body>
    <h1>SQL Server CPU Benchmark Comparison</h1>
    <p>Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
    
    <h2>Server Hardware Summary</h2>
"@

    # Add server info cards
    foreach ($machine in $byMachine) {
        $latest = $machine.Group | Sort-Object Timestamp -Descending | Select-Object -First 1
        $html += @"
    <div class="server-info">
        <strong>$($machine.Name)</strong><br>
        CPU: $($latest.CpuModel)<br>
        Cores: $($latest.PhysicalCores) physical / $($latest.LogicalCPUs) logical | 
        Memory: $([Math]::Round([int]$latest.PhysicalMemoryMB / 1024, 1)) GB |
        SQL: $($latest.SqlVersion) ($($latest.SqlEdition))
    </div>
"@
    }
    
    # Add comparison table
    $html += @"
    <h2>Performance Comparison</h2>
    <table>
        <tr>
            <th>Test Name</th>
"@
    
    foreach ($machine in $byMachine) {
        $html += "            <th>$($machine.Name)</th>`n"
    }
    $html += "            <th>Best</th>`n        </tr>`n"
    
    foreach ($test in $testNames) {
        $html += "        <tr>`n            <td>$test</td>`n"
        
        $values = $comparison[$test]
        $maxVal = ($values.Values | Measure-Object -Maximum).Maximum
        $minVal = ($values.Values | Measure-Object -Minimum).Minimum
        $bestMachine = ($values.GetEnumerator() | Where-Object { $_.Value -eq $maxVal } | Select-Object -First 1).Key
        
        foreach ($machine in $byMachine) {
            $val = $values[$machine.Name]
            $class = ""
            if ($val -eq $maxVal -and $byMachine.Count -gt 1) { $class = "best" }
            elseif ($val -eq $minVal -and $byMachine.Count -gt 1 -and $maxVal -ne $minVal) { $class = "worst" }
            
            $formatted = if ($val) { "{0:N0}" -f $val } else { "N/A" }
            $html += "            <td class=`"$class`">$formatted</td>`n"
        }
        
        $html += "            <td><strong>$bestMachine</strong></td>`n        </tr>`n"
    }
    
    # Build labels string (PowerShell 5.1 compatible)
    # Separate throughput tests (MB/s) from operations tests (iter/sec, rows/sec)
    $throughputTests = @('Compression_Test', 'Memory_Bandwidth')
    $operationsTests = $testNames | Where-Object { $_ -notin $throughputTests }
    
    $operationsLabelsArray = $operationsTests | ForEach-Object { "'$_'" }
    $operationsLabelsString = $operationsLabelsArray -join ', '
    
    $throughputLabelsArray = $throughputTests | Where-Object { $_ -in $testNames } | ForEach-Object { "'$_'" }
    $throughputLabelsString = $throughputLabelsArray -join ', '
    
    $html += @"
    </table>
    
    <h2>Performance Chart (Operations/sec)</h2>
    <div class="chart-container">
        <canvas id="operationsChart" width="800" height="400"></canvas>
    </div>
    
    <h2>Throughput Chart (MB/s)</h2>
    <div class="chart-container">
        <canvas id="throughputChart" width="800" height="400"></canvas>
    </div>
    
    <script>
        // Operations Chart (iter/sec, rows/sec)
        const ctxOps = document.getElementById('operationsChart').getContext('2d');
        new Chart(ctxOps, {
            type: 'bar',
            data: {
                labels: [$operationsLabelsString],
                datasets: [
"@
    
    $colors = @('#0078d4', '#00a86b', '#ff6b6b', '#ffd93d', '#6c5ce7', '#a29bfe')
    $i = 0
    foreach ($machine in $byMachine) {
        $data = $operationsTests | ForEach-Object { 
            $val = $comparison[$_][$machine.Name]
            if ($val) { $val } else { 0 }
        }
        $color = $colors[$i % $colors.Count]
        $html += @"
                    {
                        label: '$($machine.Name)',
                        data: [$($data -join ', ')],
                        backgroundColor: '$color'
                    },
"@
        $i++
    }
    
    $html += @"
                ]
            },
            options: {
                responsive: true,
                plugins: {
                    title: {
                        display: true,
                        text: 'CPU, String, Hash, Parallel, Sort, Index Tests'
                    }
                },
                scales: {
                    y: { 
                        beginAtZero: true,
                        title: {
                            display: true,
                            text: 'Operations per Second'
                        }
                    }
                }
            }
        });
        
        // Throughput Chart (MB/s)
        const ctxThroughput = document.getElementById('throughputChart').getContext('2d');
        new Chart(ctxThroughput, {
            type: 'bar',
            data: {
                labels: [$throughputLabelsString],
                datasets: [
"@
    
    $i = 0
    foreach ($machine in $byMachine) {
        $throughputTestsInResults = $throughputTests | Where-Object { $_ -in $testNames }
        $data = $throughputTestsInResults | ForEach-Object { 
            $val = $comparison[$_][$machine.Name]
            if ($val) { $val } else { 0 }
        }
        $color = $colors[$i % $colors.Count]
        $html += @"
                    {
                        label: '$($machine.Name)',
                        data: [$($data -join ', ')],
                        backgroundColor: '$color'
                    },
"@
        $i++
    }
    
    $html += @"
                ]
            },
            options: {
                responsive: true,
                plugins: {
                    title: {
                        display: true,
                        text: 'Compression and Memory Bandwidth Tests'
                    }
                },
                scales: {
                    y: { 
                        beginAtZero: true,
                        title: {
                            display: true,
                            text: 'Throughput (MB/s)'
                        }
                    }
                }
            }
        });
    </script>
</body>
</html>
"@
    
    $html | Out-File -FilePath $OutputPath -Encoding UTF8
    Write-Host "Comparison report saved to: $OutputPath" -ForegroundColor Green
}

# Main execution
$results = Get-ResultsFromCsv -Path $CsvPath

if ($results.Count -eq 0) {
    Write-Host "No benchmark results found!" -ForegroundColor Red
    exit 1
}

Write-Host "Found $($results.Count) benchmark results from $(($results | Select-Object -ExpandProperty MachineName -Unique).Count) server(s)"
New-ComparisonReport -Results $results -OutputPath $OutputReport
