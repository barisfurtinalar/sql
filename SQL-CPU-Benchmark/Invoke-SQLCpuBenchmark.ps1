<#
.SYNOPSIS
    SQL Server CPU Benchmark Tool
.DESCRIPTION
    Benchmarks SQL Server CPU performance across different servers.
    Collects hardware/software metadata and runs CPU-intensive T-SQL workloads.
    Results are stored for cross-server comparison.
.PARAMETER ServerInstance
    SQL Server instance name (default: localhost)
.PARAMETER Database
    Database to use for benchmarks (default: tempdb)
.PARAMETER DurationSeconds
    Total benchmark duration in seconds (default: 60)
.PARAMETER OutputPath
    Path to save results CSV (default: current directory)
.PARAMETER SkipWarmup
    Skip the warmup phase before running benchmarks
.PARAMETER IncludeSortTest
    Include in-memory sort benchmark (numeric, string, and multi-key sorts)
.PARAMETER IncludeIndexTest
    Include index seek/scan benchmark (clustered seeks, non-clustered seeks, range scans, full scans)
.EXAMPLE
    .\Invoke-SqlCpuBenchmark.ps1 -ServerInstance "SERVER1" -DurationSeconds 120
.EXAMPLE
    .\Invoke-SqlCpuBenchmark.ps1 -ServerInstance "SERVER1\INST1" -OutputPath "C:\Results"
.EXAMPLE
    .\Invoke-SqlCpuBenchmark.ps1 -ServerInstance "SERVER1" -IncludeSortTest -IncludeIndexTest
.EXAMPLE
    .\Invoke-SqlCpuBenchmark.ps1 -ServerInstance "SERVER1" -DurationSeconds 180 -IncludeSortTest -IncludeIndexTest -SkipWarmup
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ServerInstance = "localhost",
    
    [Parameter()]
    [string]$Database = "tempdb",
    
    [Parameter()]
    [int]$DurationSeconds = 60,
    
    [Parameter()]
    [string]$OutputPath = ".",
    
    [Parameter()]
    [switch]$SkipWarmup,
    
    [Parameter()]
    [switch]$IncludeSortTest,
    
    [Parameter()]
    [switch]$IncludeIndexTest
)

#region Helper Functions

function Write-BenchmarkLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"    { "Cyan" }
        "SUCCESS" { "Green" }
        "WARNING" { "Yellow" }
        "ERROR"   { "Red" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Invoke-SqlQuery {
    param(
        [string]$Query,
        [string]$Server = $ServerInstance,
        [string]$Db = $Database,
        [int]$Timeout = 300
    )
    try {
        Invoke-Sqlcmd -ServerInstance $Server -Database $Db -Query $Query -QueryTimeout $Timeout -ErrorAction Stop
    }
    catch {
        Write-BenchmarkLog "SQL Error: $_" -Level "ERROR"
        throw
    }
}

#endregion

#region Data Collection Functions

function Get-ServerHardwareInfo {
    Write-BenchmarkLog "Collecting hardware information..."
    
    # Get CPU info directly from OS using PowerShell
    $osCpuInfo = @{
        CpuName = "Unknown"
        CpuCores = 0
        CpuClockSpeedMHz = 0
    }
    try {
        $cpus = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop
        $osCpuInfo.CpuName = ($cpus | Select-Object -First 1).Name
        $osCpuInfo.CpuCores = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum
        $osCpuInfo.CpuClockSpeedMHz = ($cpus | Select-Object -First 1).MaxClockSpeed
    }
    catch {
        Write-BenchmarkLog "Could not get CPU info from OS: $_" -Level "WARNING"
    }
    
    # Get Windows OS info via SQL Server
    $osInfo = Invoke-SqlQuery -Query @"
        SELECT 
            SERVERPROPERTY('MachineName') AS MachineName,
            SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS PhysicalHostName,
            (SELECT value_in_use FROM sys.configurations WHERE name = 'max degree of parallelism') AS MAXDOP,
            (SELECT value_in_use FROM sys.configurations WHERE name = 'cost threshold for parallelism') AS CostThreshold
"@

    # Get CPU info from SQL Server DMVs
    $cpuInfo = Invoke-SqlQuery -Query @"
        SELECT 
            cpu_count AS LogicalCPUs,
            hyperthread_ratio AS HyperthreadRatio,
            cpu_count / hyperthread_ratio AS PhysicalCores,
            socket_count AS Sockets,
            cores_per_socket AS CoresPerSocket,
            numa_node_count AS NumaNodes,
            scheduler_count AS SchedulerCount,
            max_workers_count AS MaxWorkers,
            physical_memory_kb / 1024 AS PhysicalMemoryMB,
            committed_kb / 1024 AS CommittedMemoryMB,
            committed_target_kb / 1024 AS TargetMemoryMB
        FROM sys.dm_os_sys_info
"@

    # Get processor description
    $procDesc = Invoke-SqlQuery -Query @"
        SELECT TOP 1 
            record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS SqlCpuUtilization,
            record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemIdle
        FROM (
            SELECT CONVERT(xml, record) AS record 
            FROM sys.dm_os_ring_buffers 
            WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
            AND record LIKE '%<SystemHealth>%'
        ) AS x
"@

    return @{
        MachineName      = $osInfo.MachineName
        PhysicalHostName = $osInfo.PhysicalHostName
        CpuModel         = $osCpuInfo.CpuName
        CpuCores         = $osCpuInfo.CpuCores
        CpuClockSpeedMHz = $osCpuInfo.CpuClockSpeedMHz
        LogicalCPUs      = $cpuInfo.LogicalCPUs
        PhysicalCores    = $cpuInfo.PhysicalCores
        HyperthreadRatio = $cpuInfo.HyperthreadRatio
        Sockets          = $cpuInfo.Sockets
        CoresPerSocket   = $cpuInfo.CoresPerSocket
        NumaNodes        = $cpuInfo.NumaNodes
        SchedulerCount   = $cpuInfo.SchedulerCount
        MaxWorkers       = $cpuInfo.MaxWorkers
        PhysicalMemoryMB = $cpuInfo.PhysicalMemoryMB
        CommittedMemoryMB = $cpuInfo.CommittedMemoryMB
        TargetMemoryMB   = $cpuInfo.TargetMemoryMB
        MAXDOP           = $osInfo.MAXDOP
        CostThreshold    = $osInfo.CostThreshold
    }
}

function Get-SqlServerInfo {
    Write-BenchmarkLog "Collecting SQL Server information..."
    
    $sqlInfo = Invoke-SqlQuery -Query @"
        SELECT 
            SERVERPROPERTY('ProductVersion') AS ProductVersion,
            SERVERPROPERTY('ProductLevel') AS ProductLevel,
            SERVERPROPERTY('ProductUpdateLevel') AS UpdateLevel,
            SERVERPROPERTY('Edition') AS Edition,
            SERVERPROPERTY('EngineEdition') AS EngineEdition,
            SERVERPROPERTY('ProductMajorVersion') AS MajorVersion,
            SERVERPROPERTY('ProductMinorVersion') AS MinorVersion,
            SERVERPROPERTY('BuildClrVersion') AS ClrVersion,
            SERVERPROPERTY('Collation') AS Collation,
            SERVERPROPERTY('IsHadrEnabled') AS IsHadrEnabled,
            SERVERPROPERTY('IsClustered') AS IsClustered,
            @@VERSION AS FullVersion
"@

    return @{
        ProductVersion = $sqlInfo.ProductVersion
        ProductLevel   = $sqlInfo.ProductLevel
        UpdateLevel    = $sqlInfo.UpdateLevel
        Edition        = $sqlInfo.Edition
        EngineEdition  = $sqlInfo.EngineEdition
        MajorVersion   = $sqlInfo.MajorVersion
        MinorVersion   = $sqlInfo.MinorVersion
        ClrVersion     = $sqlInfo.ClrVersion
        Collation      = $sqlInfo.Collation
        IsHadrEnabled  = $sqlInfo.IsHadrEnabled
        IsClustered    = $sqlInfo.IsClustered
        FullVersion    = $sqlInfo.FullVersion
    }
}

#endregion

#region Benchmark Functions

function Get-ScaledIterations {
    param(
        [int]$BaseDurationSeconds,
        [int]$LogicalCPUs,
        [int]$PhysicalCores
    )
    
    # Scale iterations based on duration and core count
    # Base: 1 million iterations per 10 seconds on single core
    $baseIterations = 100000
    $scaleFactor = [Math]::Max(1, $BaseDurationSeconds / 10)
    
    return @{
        SingleThread = [int]($baseIterations * $scaleFactor)
        MultiThread  = [int]($baseIterations * $scaleFactor * [Math]::Min($PhysicalCores, 8))
        ParallelTest = [int]($baseIterations * $scaleFactor / 2)
    }
}

function Invoke-CpuIntegerBenchmark {
    param([int]$Iterations, [string]$TestName = "CPU_Integer_SingleThread")
    
    Write-BenchmarkLog "Running $TestName benchmark ($Iterations iterations)..."
    
    $query = @"
        SET NOCOUNT ON;
        DECLARE @start DATETIME2 = SYSDATETIME();
        DECLARE @i BIGINT = 0;
        DECLARE @result BIGINT = 0;
        DECLARE @iterations INT = $Iterations;
        
        WHILE @i < @iterations
        BEGIN
            SET @result = @result + (@i * 17) % 1000000007;
            SET @result = @result - (@i / 3);
            SET @result = @result ^ (@i & 0xFFFF);
            SET @i = @i + 1;
        END
        
        SELECT 
            '$TestName' AS TestName,
            @iterations AS Iterations,
            DATEDIFF(MILLISECOND, @start, SYSDATETIME()) AS ElapsedMs,
            @result AS CheckSum;
"@
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-SqlQuery -Query $query
    $stopwatch.Stop()
    
    return @{
        TestName        = $TestName
        Iterations      = $Iterations
        SqlElapsedMs    = $result.ElapsedMs
        ClientElapsedMs = $stopwatch.ElapsedMilliseconds
        IterationsPerSec = [Math]::Round($Iterations / ($result.ElapsedMs / 1000), 2)
        CheckSum        = $result.CheckSum
    }
}

function Invoke-CpuFloatBenchmark {
    param([int]$Iterations, [string]$TestName = "CPU_Float_SingleThread")
    
    Write-BenchmarkLog "Running $TestName benchmark ($Iterations iterations)..."
    
    $query = @"
        SET NOCOUNT ON;
        DECLARE @start DATETIME2 = SYSDATETIME();
        DECLARE @i BIGINT = 0;
        DECLARE @result FLOAT = 0.0;
        DECLARE @iterations INT = $Iterations;
        
        WHILE @i < @iterations
        BEGIN
            SET @result = @result + SIN(CAST(@i AS FLOAT) * 0.001);
            SET @result = @result + COS(CAST(@i AS FLOAT) * 0.001);
            SET @result = @result + SQRT(CAST(@i AS FLOAT) + 1.0);
            SET @i = @i + 1;
        END
        
        SELECT 
            '$TestName' AS TestName,
            @iterations AS Iterations,
            DATEDIFF(MILLISECOND, @start, SYSDATETIME()) AS ElapsedMs,
            @result AS CheckSum;
"@
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-SqlQuery -Query $query
    $stopwatch.Stop()
    
    return @{
        TestName        = $TestName
        Iterations      = $Iterations
        SqlElapsedMs    = $result.ElapsedMs
        ClientElapsedMs = $stopwatch.ElapsedMilliseconds
        IterationsPerSec = [Math]::Round($Iterations / ($result.ElapsedMs / 1000), 2)
        CheckSum        = $result.CheckSum
    }
}


function Invoke-HashAggregateBenchmark {
    param([int]$RowCount, [string]$TestName = "Hash_Aggregate")
    
    Write-BenchmarkLog "Running $TestName benchmark ($RowCount rows)..."
    
    $query = @"
        SET NOCOUNT ON;
        DECLARE @start DATETIME2 = SYSDATETIME();
        
        ;WITH Numbers AS (
            SELECT TOP ($RowCount) 
                ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
            FROM sys.all_objects a
            CROSS JOIN sys.all_objects b
        )
        SELECT 
            n % 1000 AS GroupKey,
            COUNT(*) AS Cnt,
            SUM(n) AS Total,
            AVG(CAST(n AS BIGINT)) AS AvgVal,
            CHECKSUM_AGG(CAST(n AS INT)) AS ChkSum
        INTO #temp
        FROM Numbers
        GROUP BY n % 1000
        OPTION (MAXDOP 1);
        
        DECLARE @grpcount INT = @@ROWCOUNT;
        DROP TABLE #temp;
        
        SELECT 
            '$TestName' AS TestName,
            $RowCount AS TotalRows,
            DATEDIFF(MILLISECOND, @start, SYSDATETIME()) AS ElapsedMs,
            @grpcount AS GroupCount;
"@
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-SqlQuery -Query $query
    $stopwatch.Stop()
    
    return @{
        TestName        = $TestName
        RowCount        = $RowCount
        SqlElapsedMs    = $result.ElapsedMs
        ClientElapsedMs = $stopwatch.ElapsedMilliseconds
        RowsPerSec      = [Math]::Round($RowCount / ($result.ElapsedMs / 1000), 2)
        GroupCount      = $result.GroupCount
    }
}

function Invoke-ParallelQueryBenchmark {
    param([int]$RowCount, [int]$MaxDop, [string]$TestName = "Parallel_Query")
    
    $actualTestName = "${TestName}_MAXDOP${MaxDop}"
    Write-BenchmarkLog "Running $actualTestName benchmark ($RowCount rows, MAXDOP $MaxDop)..."
    
    $query = @"
        SET NOCOUNT ON;
        DECLARE @start DATETIME2 = SYSDATETIME();
        
        ;WITH Numbers AS (
            SELECT TOP ($RowCount) 
                ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
            FROM sys.all_objects a
            CROSS JOIN sys.all_objects b
            CROSS JOIN sys.all_objects c
        )
        SELECT 
            n % 10000 AS GroupKey,
            COUNT(*) AS Cnt,
            SUM(n * n) AS SumSquares,
            AVG(CAST(n AS BIGINT)) AS AvgVal
        INTO #temp
        FROM Numbers
        GROUP BY n % 10000
        OPTION (MAXDOP $MaxDop);
        
        DECLARE @grpcount INT = @@ROWCOUNT;
        DROP TABLE #temp;
        
        SELECT 
            '$actualTestName' AS TestName,
            $RowCount AS TotalRows,
            DATEDIFF(MILLISECOND, @start, SYSDATETIME()) AS ElapsedMs,
            @grpcount AS GroupCount;
"@
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-SqlQuery -Query $query
    $stopwatch.Stop()
    
    return @{
        TestName        = $actualTestName
        RowCount        = $RowCount
        MaxDop          = $MaxDop
        SqlElapsedMs    = $result.ElapsedMs
        ClientElapsedMs = $stopwatch.ElapsedMilliseconds
        RowsPerSec      = [Math]::Round($RowCount / ($result.ElapsedMs / 1000), 2)
        GroupCount      = $result.GroupCount
    }
}

function Invoke-StringManipulationBenchmark {
    param([int]$Iterations, [string]$TestName = "String_Manipulation")
    
    Write-BenchmarkLog "Running $TestName benchmark ($Iterations iterations)..."
    
    $query = @"
        SET NOCOUNT ON;
        DECLARE @start DATETIME2 = SYSDATETIME();
        DECLARE @i INT = 0;
        DECLARE @result NVARCHAR(MAX) = N'';
        DECLARE @iterations INT = $Iterations;
        DECLARE @len INT = 0;
        
        WHILE @i < @iterations
        BEGIN
            SET @result = CONCAT(
                REPLICATE(N'X', @i % 10 + 1),
                REVERSE(CAST(@i AS NVARCHAR(20))),
                UPPER(SUBSTRING(N'abcdefghij', (@i % 10) + 1, 3))
            );
            SET @len = @len + LEN(@result);
            SET @i = @i + 1;
        END
        
        SELECT 
            '$TestName' AS TestName,
            @iterations AS Iterations,
            DATEDIFF(MILLISECOND, @start, SYSDATETIME()) AS ElapsedMs,
            @len AS TotalLength;
"@
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-SqlQuery -Query $query
    $stopwatch.Stop()
    
    return @{
        TestName        = $TestName
        Iterations      = $Iterations
        SqlElapsedMs    = $result.ElapsedMs
        ClientElapsedMs = $stopwatch.ElapsedMilliseconds
        IterationsPerSec = [Math]::Round($Iterations / ($result.ElapsedMs / 1000), 2)
        TotalLength     = $result.TotalLength
    }
}

function Invoke-CompressionBenchmark {
    param([int]$DataSizeKB, [string]$TestName = "Compression_Test")
    
    Write-BenchmarkLog "Running $TestName benchmark (${DataSizeKB}KB data)..."
    
    $query = @"
        SET NOCOUNT ON;
        DECLARE @start DATETIME2 = SYSDATETIME();
        DECLARE @data VARBINARY(MAX);
        DECLARE @compressed VARBINARY(MAX);
        DECLARE @decompressed VARBINARY(MAX);
        
        -- Generate test data
        SET @data = CAST(REPLICATE(CAST(N'TestDataForCompression123456789' AS NVARCHAR(MAX)), $DataSizeKB * 16) AS VARBINARY(MAX));
        
        -- Compress
        SET @compressed = COMPRESS(@data);
        
        -- Decompress
        SET @decompressed = DECOMPRESS(@compressed);
        
        SELECT 
            '$TestName' AS TestName,
            DATEDIFF(MILLISECOND, @start, SYSDATETIME()) AS ElapsedMs,
            DATALENGTH(@data) AS OriginalSize,
            DATALENGTH(@compressed) AS CompressedSize,
            CAST(100.0 * (1.0 - CAST(DATALENGTH(@compressed) AS FLOAT) / DATALENGTH(@data)) AS DECIMAL(5,2)) AS CompressionRatio;
"@
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-SqlQuery -Query $query
    $stopwatch.Stop()
    
    return @{
        TestName         = $TestName
        DataSizeKB       = $DataSizeKB
        SqlElapsedMs     = $result.ElapsedMs
        ClientElapsedMs  = $stopwatch.ElapsedMilliseconds
        OriginalSize     = $result.OriginalSize
        CompressedSize   = $result.CompressedSize
        CompressionRatio = $result.CompressionRatio
        ThroughputMBps   = [Math]::Round(($DataSizeKB / 1024) / ($result.ElapsedMs / 1000), 2)
    }
}

function Invoke-MemoryBandwidthBenchmark {
    param([int]$RowCount, [string]$TestName = "Memory_Bandwidth")
    
    Write-BenchmarkLog "Running $TestName benchmark ($RowCount rows)..."
    
    $query = @"
        SET NOCOUNT ON;
        
        -- Create temp table with data
        CREATE TABLE #BenchData (
            ID INT NOT NULL,
            Val1 BIGINT NOT NULL,
            Val2 BIGINT NOT NULL,
            Val3 FLOAT NOT NULL,
            Padding CHAR(100) NOT NULL DEFAULT ''
        );
        
        -- Insert test data
        ;WITH Numbers AS (
            SELECT TOP ($RowCount) 
                ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
            FROM sys.all_objects a
            CROSS JOIN sys.all_objects b
        )
        INSERT INTO #BenchData (ID, Val1, Val2, Val3)
        SELECT n, n * 17, n * 31, CAST(n AS FLOAT) * 1.5
        FROM Numbers;
        
        DECLARE @start DATETIME2 = SYSDATETIME();
        DECLARE @sum1 BIGINT, @sum2 BIGINT, @sum3 FLOAT;
        
        -- Full table scan
        SELECT 
            @sum1 = SUM(Val1),
            @sum2 = SUM(Val2),
            @sum3 = SUM(Val3)
        FROM #BenchData
        OPTION (MAXDOP 1);
        
        DECLARE @elapsed INT = DATEDIFF(MILLISECOND, @start, SYSDATETIME());
        
        DROP TABLE #BenchData;
        
        SELECT 
            '$TestName' AS TestName,
            $RowCount AS TotalRows,
            @elapsed AS ElapsedMs,
            @sum1 AS Sum1,
            @sum2 AS Sum2;
"@
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-SqlQuery -Query $query
    $stopwatch.Stop()
    
    # Estimate data size: ~124 bytes per row
    $dataSizeMB = ($RowCount * 124) / (1024 * 1024)
    
    return @{
        TestName        = $TestName
        RowCount        = $RowCount
        SqlElapsedMs    = $result.ElapsedMs
        ClientElapsedMs = $stopwatch.ElapsedMilliseconds
        DataSizeMB      = [Math]::Round($dataSizeMB, 2)
        ThroughputMBps  = [Math]::Round($dataSizeMB / ($result.ElapsedMs / 1000), 2)
    }
}

function Invoke-SortBenchmark {
    param([int]$RowCount, [string]$TestName = "Sort_InMemory")
    
    Write-BenchmarkLog "Running $TestName benchmark ($RowCount rows)..."
    
    # Use MIN_GRANT_PERCENT to ensure adequate memory, avoid spills
    $query = @"
        SET NOCOUNT ON;
        
        -- Create source data in temp table (stays in memory)
        CREATE TABLE #SortSource (
            ID INT NOT NULL,
            SortKey1 BIGINT NOT NULL,
            SortKey2 NVARCHAR(50) NOT NULL,
            Val1 BIGINT NOT NULL
        );
        
        ;WITH Numbers AS (
            SELECT TOP ($RowCount) 
                ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
            FROM sys.all_objects a
            CROSS JOIN sys.all_objects b
        )
        INSERT INTO #SortSource (ID, SortKey1, SortKey2, Val1)
        SELECT 
            n,
            ABS(CHECKSUM(NEWID())) % 1000000,  -- Random sort key
            RIGHT(REPLICATE('0', 10) + CAST(ABS(CHECKSUM(NEWID())) % 100000 AS NVARCHAR(10)), 10),
            n * 17
        FROM Numbers;
        
        -- Warmup: ensure data is in buffer pool
        DECLARE @dummy BIGINT;
        SELECT @dummy = SUM(SortKey1) FROM #SortSource;
        
        DECLARE @start DATETIME2 = SYSDATETIME();
        
        -- Sort by numeric key
        SELECT ID, SortKey1, SortKey2, Val1
        INTO #Sorted1
        FROM #SortSource
        ORDER BY SortKey1
        OPTION (MAXDOP 1, MIN_GRANT_PERCENT = 25);
        
        DECLARE @elapsed1 INT = DATEDIFF(MILLISECOND, @start, SYSDATETIME());
        DROP TABLE #Sorted1;
        
        -- Sort by string key
        SET @start = SYSDATETIME();
        
        SELECT ID, SortKey1, SortKey2, Val1
        INTO #Sorted2
        FROM #SortSource
        ORDER BY SortKey2
        OPTION (MAXDOP 1, MIN_GRANT_PERCENT = 25);
        
        DECLARE @elapsed2 INT = DATEDIFF(MILLISECOND, @start, SYSDATETIME());
        DROP TABLE #Sorted2;
        
        -- Sort by multiple keys
        SET @start = SYSDATETIME();
        
        SELECT ID, SortKey1, SortKey2, Val1
        INTO #Sorted3
        FROM #SortSource
        ORDER BY SortKey1, SortKey2 DESC
        OPTION (MAXDOP 1, MIN_GRANT_PERCENT = 25);
        
        DECLARE @elapsed3 INT = DATEDIFF(MILLISECOND, @start, SYSDATETIME());
        DROP TABLE #Sorted3;
        
        DROP TABLE #SortSource;
        
        SELECT 
            '$TestName' AS TestName,
            $RowCount AS TotalRows,
            @elapsed1 AS NumericSortMs,
            @elapsed2 AS StringSortMs,
            @elapsed3 AS MultiKeySortMs,
            @elapsed1 + @elapsed2 + @elapsed3 AS TotalElapsedMs;
"@
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-SqlQuery -Query $query
    $stopwatch.Stop()
    
    return @{
        TestName        = $TestName
        RowCount        = $RowCount
        SqlElapsedMs    = $result.TotalElapsedMs
        NumericSortMs   = $result.NumericSortMs
        StringSortMs    = $result.StringSortMs
        MultiKeySortMs  = $result.MultiKeySortMs
        ClientElapsedMs = $stopwatch.ElapsedMilliseconds
        RowsPerSec      = [Math]::Round(($RowCount * 3) / ($result.TotalElapsedMs / 1000), 2)
    }
}

function Invoke-IndexSeekScanBenchmark {
    param([int]$RowCount, [int]$SeekIterations = 10000, [string]$TestName = "Index_SeekScan")
    
    Write-BenchmarkLog "Running $TestName benchmark ($RowCount rows, $SeekIterations seeks)..."
    
    $query = @"
        SET NOCOUNT ON;
        
        -- Create temp table with clustered and non-clustered indexes
        CREATE TABLE #IndexTest (
            ID INT NOT NULL PRIMARY KEY CLUSTERED,
            LookupKey INT NOT NULL,
            Category INT NOT NULL,
            Val1 BIGINT NOT NULL,
            Val2 BIGINT NOT NULL,
            Padding CHAR(50) NOT NULL DEFAULT ''
        );
        
        -- Create non-clustered indexes
        CREATE NONCLUSTERED INDEX IX_LookupKey ON #IndexTest (LookupKey) INCLUDE (Val1);
        CREATE NONCLUSTERED INDEX IX_Category ON #IndexTest (Category) INCLUDE (Val1, Val2);
        
        -- Insert test data
        ;WITH Numbers AS (
            SELECT TOP ($RowCount) 
                ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
            FROM sys.all_objects a
            CROSS JOIN sys.all_objects b
        )
        INSERT INTO #IndexTest (ID, LookupKey, Category, Val1, Val2)
        SELECT 
            n,
            ABS(CHECKSUM(NEWID())) % $RowCount,  -- Random lookup key
            n % 100,  -- 100 categories
            n * 17,
            n * 31
        FROM Numbers;
        
        -- Warmup: ensure indexes are in buffer pool
        DECLARE @dummy BIGINT;
        SELECT @dummy = SUM(Val1) FROM #IndexTest WITH (INDEX(IX_LookupKey));
        SELECT @dummy = SUM(Val1) FROM #IndexTest WITH (INDEX(IX_Category));
        SELECT @dummy = SUM(Val1) FROM #IndexTest;
        
        DECLARE @start DATETIME2;
        DECLARE @i INT = 0;
        DECLARE @result BIGINT = 0;
        DECLARE @seekIterations INT = $SeekIterations;
        DECLARE @maxKey INT = $RowCount;
        
        -- Test 1: Clustered Index Seeks (point lookups)
        SET @start = SYSDATETIME();
        SET @i = 0;
        
        WHILE @i < @seekIterations
        BEGIN
            SELECT @result = @result + ISNULL(Val1, 0)
            FROM #IndexTest
            WHERE ID = (@i % @maxKey) + 1;
            SET @i = @i + 1;
        END
        
        DECLARE @clusteredSeekMs INT = DATEDIFF(MILLISECOND, @start, SYSDATETIME());
        
        -- Test 2: Non-Clustered Index Seeks
        SET @start = SYSDATETIME();
        SET @i = 0;
        
        WHILE @i < @seekIterations
        BEGIN
            SELECT @result = @result + ISNULL(Val1, 0)
            FROM #IndexTest
            WHERE LookupKey = (@i % @maxKey);
            SET @i = @i + 1;
        END
        
        DECLARE @ncSeekMs INT = DATEDIFF(MILLISECOND, @start, SYSDATETIME());
        
        -- Test 3: Index Range Scan (category lookup - ~1% of rows each)
        SET @start = SYSDATETIME();
        SET @i = 0;
        
        WHILE @i < 100  -- 100 categories
        BEGIN
            SELECT @result = @result + ISNULL(SUM(Val1 + Val2), 0)
            FROM #IndexTest
            WHERE Category = @i;
            SET @i = @i + 1;
        END
        
        DECLARE @rangeScanMs INT = DATEDIFF(MILLISECOND, @start, SYSDATETIME());
        
        -- Test 4: Full Clustered Index Scan
        SET @start = SYSDATETIME();
        
        SELECT @result = SUM(Val1 + Val2)
        FROM #IndexTest
        OPTION (MAXDOP 1);
        
        DECLARE @fullScanMs INT = DATEDIFF(MILLISECOND, @start, SYSDATETIME());
        
        DROP TABLE #IndexTest;
        
        SELECT 
            '$TestName' AS TestName,
            $RowCount AS TotalRows,
            @seekIterations AS SeekIterations,
            @clusteredSeekMs AS ClusteredSeekMs,
            @ncSeekMs AS NonClusteredSeekMs,
            @rangeScanMs AS RangeScanMs,
            @fullScanMs AS FullScanMs,
            @clusteredSeekMs + @ncSeekMs + @rangeScanMs + @fullScanMs AS TotalElapsedMs;
"@
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-SqlQuery -Query $query
    $stopwatch.Stop()
    
    return @{
        TestName           = $TestName
        RowCount           = $RowCount
        SeekIterations     = $SeekIterations
        SqlElapsedMs       = $result.TotalElapsedMs
        ClusteredSeekMs    = $result.ClusteredSeekMs
        NonClusteredSeekMs = $result.NonClusteredSeekMs
        RangeScanMs        = $result.RangeScanMs
        FullScanMs         = $result.FullScanMs
        ClientElapsedMs    = $stopwatch.ElapsedMilliseconds
        SeeksPerSec        = [Math]::Round(($SeekIterations * 2) / (($result.ClusteredSeekMs + $result.NonClusteredSeekMs) / 1000), 2)
    }
}

#endregion


#region Results Storage

function Save-ResultsToCsv {
    param(
        [hashtable]$HardwareInfo,
        [hashtable]$SqlInfo,
        [array]$BenchmarkResults,
        [string]$OutputPath
    )
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $fileName = "SqlCpuBenchmark_$($HardwareInfo.MachineName)_$timestamp.csv"
    $fullPath = Join-Path $OutputPath $fileName
    
    $results = foreach ($result in $BenchmarkResults) {
        [PSCustomObject]@{
            Timestamp        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            MachineName      = $HardwareInfo.MachineName
            CpuModel         = $HardwareInfo.CpuModel
            LogicalCPUs      = $HardwareInfo.LogicalCPUs
            PhysicalCores    = $HardwareInfo.PhysicalCores
            Sockets          = $HardwareInfo.Sockets
            HyperthreadRatio = $HardwareInfo.HyperthreadRatio
            NumaNodes        = $HardwareInfo.NumaNodes
            PhysicalMemoryMB = $HardwareInfo.PhysicalMemoryMB
            SqlVersion       = $SqlInfo.ProductVersion
            SqlEdition       = $SqlInfo.Edition
            MAXDOP           = $HardwareInfo.MAXDOP
            TestName         = $result.TestName
            Iterations       = $result.Iterations
            RowCount         = $result.RowCount
            SqlElapsedMs     = $result.SqlElapsedMs
            ClientElapsedMs  = $result.ClientElapsedMs
            IterationsPerSec = $result.IterationsPerSec
            RowsPerSec       = $result.RowsPerSec
            ThroughputMBps   = $result.ThroughputMBps
            DurationSeconds  = $script:DurationSeconds
        }
    }
    
    $results | Export-Csv -Path $fullPath -NoTypeInformation
    Write-BenchmarkLog "Results saved to: $fullPath" -Level "SUCCESS"
    return $fullPath
}

#endregion

#region Main Execution

function Start-Benchmark {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "   SQL Server CPU Benchmark Tool v1.0" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""
    
    Write-BenchmarkLog "Connecting to $ServerInstance..."
    
    # Collect system information
    $hardwareInfo = Get-ServerHardwareInfo
    $sqlInfo = Get-SqlServerInfo
    
    # Display collected info
    Write-Host ""
    Write-Host "Hardware Information:" -ForegroundColor Yellow
    Write-Host "  Machine Name:     $($hardwareInfo.MachineName)"
    Write-Host "  CPU Model:        $($hardwareInfo.CpuModel)"
    Write-Host "  CPU Clock Speed:  $($hardwareInfo.CpuClockSpeedMHz) MHz"
    Write-Host "  Logical CPUs:     $($hardwareInfo.LogicalCPUs)"
    Write-Host "  Physical Cores:   $($hardwareInfo.PhysicalCores)"
    Write-Host "  Sockets:          $($hardwareInfo.Sockets)"
    Write-Host "  Cores/Socket:     $($hardwareInfo.CoresPerSocket)"
    Write-Host "  Hyperthread:      $(if ($hardwareInfo.HyperthreadRatio -gt 1) { 'Enabled' } else { 'Disabled' }) (Ratio: $($hardwareInfo.HyperthreadRatio))"
    Write-Host "  NUMA Nodes:       $($hardwareInfo.NumaNodes)"
    Write-Host "  Physical Memory:  $([Math]::Round($hardwareInfo.PhysicalMemoryMB / 1024, 1)) GB"
    Write-Host ""
    Write-Host "SQL Server Information:" -ForegroundColor Yellow
    Write-Host "  Version:          $($sqlInfo.ProductVersion) ($($sqlInfo.ProductLevel))"
    Write-Host "  Edition:          $($sqlInfo.Edition)"
    Write-Host "  MAXDOP:           $($hardwareInfo.MAXDOP)"
    Write-Host "  Cost Threshold:   $($hardwareInfo.CostThreshold)"
    Write-Host ""
    
    # Calculate scaled iterations based on duration and cores
    $scaledIterations = Get-ScaledIterations -BaseDurationSeconds $DurationSeconds `
                                              -LogicalCPUs $hardwareInfo.LogicalCPUs `
                                              -PhysicalCores $hardwareInfo.PhysicalCores
    
    Write-BenchmarkLog "Benchmark duration: $DurationSeconds seconds"
    Write-BenchmarkLog "Scaled iterations - Single: $($scaledIterations.SingleThread), Multi: $($scaledIterations.MultiThread)"
    if ($IncludeSortTest) { Write-BenchmarkLog "Optional test enabled: Sort Benchmark" }
    if ($IncludeIndexTest) { Write-BenchmarkLog "Optional test enabled: Index Seek/Scan Benchmark" }
    Write-Host ""
    
    # Warmup
    if (-not $SkipWarmup) {
        Write-BenchmarkLog "Running warmup..."
        $null = Invoke-CpuIntegerBenchmark -Iterations 10000 -TestName "Warmup"
        Start-Sleep -Seconds 2
    }
    
    # Run benchmarks
    $benchmarkResults = @()
    
    Write-Host ""
    Write-Host "Running Benchmarks..." -ForegroundColor Yellow
    Write-Host "---------------------------------------------"
    
    # 1. CPU Integer (Single Thread)
    $benchmarkResults += Invoke-CpuIntegerBenchmark -Iterations $scaledIterations.SingleThread -TestName "CPU_Integer_SingleThread"
    
    # 2. CPU Float (Single Thread)
    $benchmarkResults += Invoke-CpuFloatBenchmark -Iterations $scaledIterations.SingleThread -TestName "CPU_Float_SingleThread"
    
    # 3. String Manipulation
    $benchmarkResults += Invoke-StringManipulationBenchmark -Iterations ([int]($scaledIterations.SingleThread / 2)) -TestName "String_Manipulation"
    
    # 4. Hash Aggregate (Single Thread)
    $rowCount = [Math]::Min(5000000, $scaledIterations.MultiThread * 10)
    $benchmarkResults += Invoke-HashAggregateBenchmark -RowCount $rowCount -TestName "Hash_Aggregate_MAXDOP1"
    
    # 5. Parallel Query Tests (MAXDOP variations)
    $parallelRowCount = [Math]::Min(10000000, $scaledIterations.MultiThread * 20)
    
    # Test with different MAXDOP values based on core count
    $maxDopValues = @(1)
    if ($hardwareInfo.PhysicalCores -ge 2) { $maxDopValues += 2 }
    if ($hardwareInfo.PhysicalCores -ge 4) { $maxDopValues += 4 }
    if ($hardwareInfo.PhysicalCores -ge 8) { $maxDopValues += 8 }
    if ($hardwareInfo.LogicalCPUs -ge 16) { $maxDopValues += 0 } # 0 = unlimited
    
    foreach ($maxdop in $maxDopValues) {
        $benchmarkResults += Invoke-ParallelQueryBenchmark -RowCount $parallelRowCount -MaxDop $maxdop
    }
    
    # 6. Compression Test
    $compressionSizeKB = [Math]::Min(10240, $DurationSeconds * 100)
    $benchmarkResults += Invoke-CompressionBenchmark -DataSizeKB $compressionSizeKB -TestName "Compression_Test"
    
    # 7. Memory Bandwidth Test
    $memoryRowCount = [Math]::Min(2000000, $scaledIterations.MultiThread * 5)
    $benchmarkResults += Invoke-MemoryBandwidthBenchmark -RowCount $memoryRowCount -TestName "Memory_Bandwidth"
    
    # 8. Sort Benchmark (optional)
    if ($IncludeSortTest) {
        $sortRowCount = [Math]::Min(500000, $scaledIterations.MultiThread)
        $benchmarkResults += Invoke-SortBenchmark -RowCount $sortRowCount -TestName "Sort_InMemory"
    }
    
    # 9. Index Seek/Scan Benchmark (optional)
    if ($IncludeIndexTest) {
        $indexRowCount = [Math]::Min(1000000, $scaledIterations.MultiThread * 2)
        $seekIterations = [Math]::Min(50000, $scaledIterations.SingleThread / 10)
        $benchmarkResults += Invoke-IndexSeekScanBenchmark -RowCount $indexRowCount -SeekIterations $seekIterations -TestName "Index_SeekScan"
    }
    
    Write-Host ""
    Write-Host "---------------------------------------------"
    Write-Host ""
    
    # Display results summary
    Write-Host "Benchmark Results Summary:" -ForegroundColor Green
    Write-Host ""
    
    $benchmarkResults | ForEach-Object {
        $metric = if ($_.IterationsPerSec) { "$($_.IterationsPerSec) iter/sec" }
                  elseif ($_.RowsPerSec) { "$($_.RowsPerSec) rows/sec" }
                  elseif ($_.ThroughputMBps) { "$($_.ThroughputMBps) MB/s" }
                  elseif ($_.SeeksPerSec) { "$($_.SeeksPerSec) seeks/sec" }
                  else { "$($_.SqlElapsedMs) ms" }
        
        Write-Host "  $($_.TestName.PadRight(30)) : $metric" -ForegroundColor White
        
        # Show sub-metrics for Sort and Index tests
        if ($_.NumericSortMs) {
            Write-Host "    - Numeric Sort: $($_.NumericSortMs) ms | String Sort: $($_.StringSortMs) ms | Multi-Key: $($_.MultiKeySortMs) ms" -ForegroundColor Gray
        }
        if ($_.ClusteredSeekMs) {
            Write-Host "    - Clustered Seek: $($_.ClusteredSeekMs) ms | NC Seek: $($_.NonClusteredSeekMs) ms | Range: $($_.RangeScanMs) ms | Full Scan: $($_.FullScanMs) ms" -ForegroundColor Gray
        }
    }
    
    Write-Host ""
    
    # Save results
    $csvPath = Save-ResultsToCsv -HardwareInfo $hardwareInfo -SqlInfo $sqlInfo `
                                  -BenchmarkResults $benchmarkResults -OutputPath $OutputPath
    
    Write-Host ""
    Write-BenchmarkLog "Benchmark completed successfully!" -Level "SUCCESS"
    Write-Host ""
    
    return @{
        HardwareInfo = $hardwareInfo
        SqlInfo      = $sqlInfo
        Results      = $benchmarkResults
        CsvPath      = $csvPath
    }
}

# Execute
$script:DurationSeconds = $DurationSeconds
Start-Benchmark

#endregion
