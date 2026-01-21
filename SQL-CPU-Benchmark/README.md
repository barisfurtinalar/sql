# SQL Server CPU Benchmark Tool

A PowerShell-based tool to benchmark SQL Server CPU performance across different servers and compare results.

## Features

- **Hardware Detection**: Automatically detects CPU model, cores, clock speed, hyperthreading, NUMA nodes (via PowerShell CIM and SQL Server DMVs)
- **SQL Server Info**: Collects version, edition, MAXDOP settings
- **Scaled Benchmarks**: Automatically scales test iterations based on duration and core count
- **Multiple Test Types**:
  - CPU Integer operations (single-threaded)
  - CPU Float operations (trigonometry, sqrt)
  - String manipulation
  - Hash aggregation
  - Parallel query execution (various MAXDOP)
  - Compression/decompression
  - Memory bandwidth
- **CSV Output**: Save results to CSV files for easy sharing and comparison
- **Comparison Reports**: Generate HTML reports comparing multiple servers

## Requirements

- PowerShell 5.1 or later
- SQL Server PowerShell module (`SqlServer` or `SQLPS`)
- SQL Server 2016 or later (for COMPRESS/DECOMPRESS functions)

## Installation

```powershell
# Install SQL Server module if needed
Install-Module -Name SqlServer -Scope CurrentUser

# Clone or download the scripts
git clone <repo-url>
cd sql-cpu-benchmark
```

## Usage

### Basic Benchmark

```powershell
# Run 60-second benchmark on local instance
.\Invoke-SqlCpuBenchmark.ps1

# Run 120-second benchmark on remote server
.\Invoke-SqlCpuBenchmark.ps1 -ServerInstance "SERVER1\SQLEXPRESS" -DurationSeconds 120

# Save results to specific folder
.\Invoke-SqlCpuBenchmark.ps1 -ServerInstance "SERVER1" -OutputPath "C:\BenchmarkResults"
```

### Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-ServerInstance` | SQL Server instance name | localhost |
| `-Database` | Database for temp objects | tempdb |
| `-DurationSeconds` | Total benchmark duration | 60 |
| `-OutputPath` | Path for CSV output | Current directory |
| `-SkipWarmup` | Skip warmup phase | False |
| `-IncludeSortTest` | Include in-memory sort benchmark | False |
| `-IncludeIndexTest` | Include index seek/scan benchmark | False |

### Compare Results

```powershell
# Compare results from CSV files in a folder
.\Compare-BenchmarkResults.ps1 -CsvPath ".\Results"

# Compare a single CSV file
.\Compare-BenchmarkResults.ps1 -CsvPath ".\Results\SqlCpuBenchmark_SERVER1_20250120.csv"

# Custom output path
.\Compare-BenchmarkResults.ps1 -CsvPath ".\Results" -OutputReport "MyComparison.html"
```

## Benchmark Tests Explained

### CPU_Integer_SingleThread
Tests raw integer computation speed using loops with multiplication, division, and XOR operations. Good indicator of single-thread CPU performance.

### CPU_Float_SingleThread
Tests floating-point performance using SIN, COS, and SQRT functions. Important for scientific/analytical workloads.

### String_Manipulation
Tests string operations (CONCAT, REVERSE, UPPER, SUBSTRING). Relevant for ETL and text processing workloads.

### Hash_Aggregate_MAXDOP1
Tests hash-based GROUP BY operations on a single thread. Measures CPU efficiency for aggregation workloads.

### Parallel_Query_MAXDOPn
Tests parallel query execution with different MAXDOP settings. Shows how well the CPU scales with parallelism.

### Compression_Test
Tests COMPRESS/DECOMPRESS functions. Measures CPU efficiency for data compression workloads.

### Memory_Bandwidth
Tests memory throughput by scanning large tables. Important for in-memory analytics workloads.

### Sort_InMemory (optional: -IncludeSortTest)
Tests in-memory sort performance with three variations:
- Numeric key sort
- String key sort  
- Multi-key sort

Uses `MIN_GRANT_PERCENT` hint to ensure sorts stay in memory (no tempdb spills). All data is in temp tables to avoid disk I/O.

### Index_SeekScan (optional: -IncludeIndexTest)
Tests B-tree index operations:
- Clustered index point seeks
- Non-clustered index seeks
- Range scans (category lookups)
- Full clustered index scan

Uses temp tables with warmup pass to ensure all data is in buffer pool (no disk I/O).

## Output

### CSV Output
Each run creates a CSV file: `SqlCpuBenchmark_<MachineName>_<Timestamp>.csv`

Contains server metadata (CPU, cores, memory, SQL version), test results (elapsed time, iterations/sec, rows/sec, throughput), and timestamps.

### HTML Comparison Report
The comparison tool generates an interactive HTML report with:
- Server hardware summary cards
- Side-by-side performance table (best/worst highlighted)
- Bar chart visualization

## Example Output

```
=============================================
   SQL Server CPU Benchmark Tool v1.0
=============================================

[2025-01-20 10:30:15] [INFO] Connecting to SERVER1...
[2025-01-20 10:30:15] [INFO] Collecting hardware information...
[2025-01-20 10:30:16] [INFO] Collecting SQL Server information...

Hardware Information:
  Machine Name:     SERVER1
  CPU Model:        Intel(R) Xeon(R) Platinum 8375C CPU @ 2.90GHz
  CPU Clock Speed:  2900 MHz
  Logical CPUs:     96
  Physical Cores:   48
  Sockets:          2
  Hyperthread:      Enabled (Ratio: 2)
  NUMA Nodes:       2
  Physical Memory:  384.0 GB

SQL Server Information:
  Version:          16.0.4135.4 (RTM-CU14)
  Edition:          Enterprise Edition (64-bit)
  MAXDOP:           8
  Cost Threshold:   50

Running Benchmarks...
---------------------------------------------
[2025-01-20 10:30:18] [INFO] Running CPU_Integer_SingleThread benchmark...
[2025-01-20 10:30:25] [INFO] Running CPU_Float_SingleThread benchmark...
...

Benchmark Results Summary:

  CPU_Integer_SingleThread       : 1,245,678 iter/sec
  CPU_Float_SingleThread         : 456,789 iter/sec
  String_Manipulation            : 234,567 iter/sec
  Hash_Aggregate_MAXDOP1         : 2,345,678 rows/sec
  Parallel_Query_MAXDOP1         : 1,234,567 rows/sec
  Parallel_Query_MAXDOP4         : 4,567,890 rows/sec
  Parallel_Query_MAXDOP8         : 7,890,123 rows/sec
  Compression_Test               : 245.67 MB/s
  Memory_Bandwidth               : 1,234.56 MB/s

[2025-01-20 10:32:45] [SUCCESS] Results saved to: .\SqlCpuBenchmark_SERVER1_20250120_103015.csv
[2025-01-20 10:32:45] [SUCCESS] Benchmark completed successfully!
```

## Tips

1. **Run during low activity**: For accurate results, run benchmarks during maintenance windows
2. **Multiple runs**: Run benchmarks multiple times and compare for consistency
3. **Same duration**: Use the same `-DurationSeconds` when comparing servers
4. **Check MAXDOP**: Ensure MAXDOP settings are appropriate for your hardware
5. **Memory pressure**: Ensure SQL Server has adequate memory before running

## License

MIT License
