$start = get-date
$end = $start.addMinutes(0.5)
$duration = new-timespan $start $end
$count = 0
$total = 0
while($duration -gt 0) {
$disks = Get-CimInstance -class Win32_PerfFormattedData_PerfDisk_LogicalDisk | Select-Object Name, DiskWritesPersec, DiskReadsPersec
    foreach ($disk in $disks) {
    $ReadsPerSec = $disk.DiskReadsPersec
    $WritesPerSec = $disk.DiskWritesPersec

      if ($disk.Name -ne '_Total' -and $disk.Name -ne 'C:' ) {
         $count++
         
        Write-Host "$($disk.Name) Writes/s: $WritesPerSec === Reads/s: $ReadsPerSec "
        Add-Content -Path C:\DiskUtilisationLogfile.txt -Value "$($disk.Name) Writes/s: $WritesPerSec === Reads/s: $ReadsPerSec <-- $(get-date)"
        }
    }

    Start-Sleep -milliseconds 100
    $duration = new-timespan $(Get-Date) $end
}


 
