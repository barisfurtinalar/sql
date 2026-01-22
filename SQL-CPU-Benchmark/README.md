# SQL Server CPU Benchmark Tool

A PowerShell-based tool to benchmark SQL Server CPU performance across different servers and compare results.

## Features

- **Hardware Detection**: Automatically detects CPU model, cores, clock speed, SMT/Hyperthreading status, NUMA nodes (via PowerShell CIM and SQL Server DMVs)
- **EC2 Support**: Automatically detects EC2 instance type when running on AWS
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
  EC2 Instance:     r6i.4xlarge
  CPU Model:        Intel(R) Xeon(R) Platinum 8375C CPU @ 2.90GHz
  CPU Clock Speed:  2900 MHz
  Logical CPUs:     96
  Physical Cores:   48
  Sockets:          2
  Cores/Socket:     24
  SMT (HT):         Enabled
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
=======
# sqlserver



## Getting started

To make it easy for you to get started with GitLab, here's a list of recommended next steps.

Already a pro? Just edit this README.md and make it your own. Want to make it easy? [Use the template at the bottom](#editing-this-readme)!

## Add your files

- [ ] [Create](https://docs.gitlab.com/ee/user/project/repository/web_editor.html#create-a-file) or [upload](https://docs.gitlab.com/ee/user/project/repository/web_editor.html#upload-a-file) files
- [ ] [Add files using the command line](https://docs.gitlab.com/topics/git/add_files/#add-files-to-a-git-repository) or push an existing Git repository with the following command:

```
cd existing_repo
git remote add origin https://gitlab.aws.dev/barisd/sqlserver.git
git branch -M main
git push -uf origin main
```

## Integrate with your tools

- [ ] [Set up project integrations](https://gitlab.aws.dev/barisd/sqlserver/-/settings/integrations)

## Collaborate with your team

- [ ] [Invite team members and collaborators](https://docs.gitlab.com/ee/user/project/members/)
- [ ] [Create a new merge request](https://docs.gitlab.com/ee/user/project/merge_requests/creating_merge_requests.html)
- [ ] [Automatically close issues from merge requests](https://docs.gitlab.com/ee/user/project/issues/managing_issues.html#closing-issues-automatically)
- [ ] [Enable merge request approvals](https://docs.gitlab.com/ee/user/project/merge_requests/approvals/)
- [ ] [Set auto-merge](https://docs.gitlab.com/user/project/merge_requests/auto_merge/)

## Test and Deploy

Use the built-in continuous integration in GitLab.

- [ ] [Get started with GitLab CI/CD](https://docs.gitlab.com/ee/ci/quick_start/)
- [ ] [Analyze your code for known vulnerabilities with Static Application Security Testing (SAST)](https://docs.gitlab.com/ee/user/application_security/sast/)
- [ ] [Deploy to Kubernetes, Amazon EC2, or Amazon ECS using Auto Deploy](https://docs.gitlab.com/ee/topics/autodevops/requirements.html)
- [ ] [Use pull-based deployments for improved Kubernetes management](https://docs.gitlab.com/ee/user/clusters/agent/)
- [ ] [Set up protected environments](https://docs.gitlab.com/ee/ci/environments/protected_environments.html)

***

# Editing this README

When you're ready to make this README your own, just edit this file and use the handy template below (or feel free to structure it however you want - this is just a starting point!). Thanks to [makeareadme.com](https://www.makeareadme.com/) for this template.

## Suggestions for a good README

Every project is different, so consider which of these sections apply to yours. The sections used in the template are suggestions for most open source projects. Also keep in mind that while a README can be too long and detailed, too long is better than too short. If you think your README is too long, consider utilizing another form of documentation rather than cutting out information.

## Name
Choose a self-explaining name for your project.

## Description
Let people know what your project can do specifically. Provide context and add a link to any reference visitors might be unfamiliar with. A list of Features or a Background subsection can also be added here. If there are alternatives to your project, this is a good place to list differentiating factors.

## Badges
On some READMEs, you may see small images that convey metadata, such as whether or not all the tests are passing for the project. You can use Shields to add some to your README. Many services also have instructions for adding a badge.

## Visuals
Depending on what you are making, it can be a good idea to include screenshots or even a video (you'll frequently see GIFs rather than actual videos). Tools like ttygif can help, but check out Asciinema for a more sophisticated method.

## Installation
Within a particular ecosystem, there may be a common way of installing things, such as using Yarn, NuGet, or Homebrew. However, consider the possibility that whoever is reading your README is a novice and would like more guidance. Listing specific steps helps remove ambiguity and gets people to using your project as quickly as possible. If it only runs in a specific context like a particular programming language version or operating system or has dependencies that have to be installed manually, also add a Requirements subsection.

## Usage
Use examples liberally, and show the expected output if you can. It's helpful to have inline the smallest example of usage that you can demonstrate, while providing links to more sophisticated examples if they are too long to reasonably include in the README.

## Support
Tell people where they can go to for help. It can be any combination of an issue tracker, a chat room, an email address, etc.

## Roadmap
If you have ideas for releases in the future, it is a good idea to list them in the README.

## Contributing
State if you are open to contributions and what your requirements are for accepting them.

For people who want to make changes to your project, it's helpful to have some documentation on how to get started. Perhaps there is a script that they should run or some environment variables that they need to set. Make these steps explicit. These instructions could also be useful to your future self.

You can also document commands to lint the code or run tests. These steps help to ensure high code quality and reduce the likelihood that the changes inadvertently break something. Having instructions for running tests is especially helpful if it requires external setup, such as starting a Selenium server for testing in a browser.

## Authors and acknowledgment
Show your appreciation to those who have contributed to the project.

## License
For open source projects, say how it is licensed.

## Project status
If you have run out of energy or time for your project, put a note at the top of the README saying that development has slowed down or stopped completely. Someone may choose to fork your project or volunteer to step in as a maintainer or owner, allowing your project to keep going. You can also make an explicit request for maintainers.
>>>>>>> 15d9f37f99d122d318f551beae89728c62fe1ba4
