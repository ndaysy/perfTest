param(
    [string]$Out = "perf_windows.csv",
    [string]$EnvName = "windows",
    [string]$PolicyId = "",
    [string]$CrawlerPattern = "wcb_comspnew",
    [int]$IntervalSeconds = 2
)

$ErrorActionPreference = "SilentlyContinue"

function Escape-CsvValue {
    param([object]$Value)
    if ($null -eq $Value) {
        return ""
    }
    $Text = [string]$Value
    if ($Text.Contains('"') -or $Text.Contains(',') -or $Text.Contains("`n") -or $Text.Contains("`r")) {
        return '"' + $Text.Replace('"', '""') + '"'
    }
    return $Text
}

function Write-PerfRow {
    param([object[]]$Values)
    (($Values | ForEach-Object { Escape-CsvValue $_ }) -join ",") | Out-File -FilePath $Out -Append -Encoding utf8
}

function Get-ProcessStats {
    param([string]$Regex)

    $procs = @(Get-Process | Where-Object { $_.ProcessName -match $Regex })
    $memMb = 0
    $cpuSeconds = 0

    foreach ($proc in $procs) {
        $memMb += $proc.WorkingSet64 / 1MB
        if ($null -ne $proc.CPU) {
            $cpuSeconds += $proc.CPU
        }
    }

    return [pscustomobject]@{
        Count = $procs.Count
        MemMb = [math]::Round($memMb, 2)
        CpuSeconds = [math]::Round($cpuSeconds, 2)
    }
}

$headers = @(
    "timestamp",
    "env",
    "policy_id",
    "cpu_percent",
    "mem_used_mb",
    "mem_percent",
    "disk_read_bps",
    "disk_write_bps",
    "net_sent_bps",
    "net_recv_bps",
    "crawler_proc_count",
    "crawler_mem_mb",
    "crawler_cpu_seconds",
    "browser_proc_count",
    "browser_mem_mb",
    "browser_cpu_seconds",
    "driver_proc_count",
    "driver_mem_mb",
    "driver_cpu_seconds"
)

($headers -join ",") | Out-File -FilePath $Out -Encoding utf8

Write-Host "Collecting Windows Server performance metrics to $Out"
Write-Host "Press Ctrl+C to stop."

while ($true) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $os = Get-CimInstance Win32_OperatingSystem
    $cpuLoad = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    if ($null -eq $cpuLoad) {
        $cpuLoad = 0
    }

    $totalMemMb = [math]::Round($os.TotalVisibleMemorySize / 1024, 2)
    $freeMemMb = [math]::Round($os.FreePhysicalMemory / 1024, 2)
    $usedMemMb = [math]::Round($totalMemMb - $freeMemMb, 2)
    if ($totalMemMb -gt 0) {
        $memPercent = [math]::Round($usedMemMb * 100 / $totalMemMb, 2)
    } else {
        $memPercent = 0
    }

    $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_LogicalDisk |
        Where-Object { $_.Name -eq "_Total" } |
        Select-Object -First 1
    if ($null -eq $disk) {
        $diskReadBps = 0
        $diskWriteBps = 0
    } else {
        $diskReadBps = [int64]$disk.DiskReadBytesPersec
        $diskWriteBps = [int64]$disk.DiskWriteBytesPersec
    }

    $netAdapters = @(Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface)
    $netSentBps = [int64](($netAdapters | Measure-Object -Property BytesSentPersec -Sum).Sum)
    $netRecvBps = [int64](($netAdapters | Measure-Object -Property BytesReceivedPersec -Sum).Sum)

    $crawlerStats = Get-ProcessStats -Regex $CrawlerPattern
    $browserStats = Get-ProcessStats -Regex "chrome|chromium|cloakbrowser"
    $driverStats = Get-ProcessStats -Regex "chromedriver"

    Write-PerfRow @(
        $timestamp,
        $EnvName,
        $PolicyId,
        [math]::Round($cpuLoad, 2),
        $usedMemMb,
        $memPercent,
        $diskReadBps,
        $diskWriteBps,
        $netSentBps,
        $netRecvBps,
        $crawlerStats.Count,
        $crawlerStats.MemMb,
        $crawlerStats.CpuSeconds,
        $browserStats.Count,
        $browserStats.MemMb,
        $browserStats.CpuSeconds,
        $driverStats.Count,
        $driverStats.MemMb,
        $driverStats.CpuSeconds
    )

    Start-Sleep -Seconds $IntervalSeconds
}
