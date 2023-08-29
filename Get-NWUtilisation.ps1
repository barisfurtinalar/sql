$start = get-date
$end = $start.addMinutes(0.5)
$duration = new-timespan $start $end
$count = 0
$total = 0
while ($duration -gt 0) {
   $NetworkInterfaces = Get-CimInstance -class Win32_PerfFormattedData_Tcpip_NetworkInterface | Select-Object Name, BytesTotalPersec, CurrentBandwidth,PacketsPersec

   foreach ($interface in $NetworkInterfaces) {
      $bitsPerSec = $interface.BytesTotalPersec * 8
      $totalBits = $interface.CurrentBandwidth

      if ($totalBits -gt 0) {
         $count++
         $result = "{0:N2}" -f (( $bitsPerSec / $totalBits) * 100)
         if(( $bitsPerSec / $totalBits) -gt '0.8')
         {
            Write-Host "$($interface.Name) - Utilisation -->`t $result % <-- $(get-date)" -BackgroundColor Red
         }
         elseif(( $bitsPerSec / $totalBits) -ge '0.5' -and ( $bitsPerSec / $totalBits) -lt '0.8')
         {
            Write-Host "$($interface.Name) - Utilisation -->`t $result % <-- $(get-date)" -BackgroundColor DarkYellow
         }
         else
         {
            Write-Host "$($interface.Name) - Utilisation -->`t $result % <-- $(get-date)" -BackgroundColor DarkGreen
         }
         $total = $total + $result
         
         Add-Content -Path C:\NetworkUtilisationLogfile.txt -Value "$($interface.Name) - Utilisation -->`t $result % <-- $(get-date)"
      }
   }
   Start-Sleep -milliseconds 200
   $duration = new-timespan $(Get-Date) $end
}

$average = $total / $count
$value = "{0:N2}" -f $average
Write-Host "Average Network Utilisation -->`t $value %" -BackgroundColor DarkBlue 
