$conn=Get-IscsiConnection | select ConnectionIdentifier, TargetAddress | Measure-Object
$targetIP=Get-IscsiConnection | select TargetAddress 
$mpioPolicy=Get-MSDSMGlobalDefaultLoadBalancePolicy

$targetIP = Get-IscsiConnection | select -ExpandProperty TargetAddress | Sort-Object | Get-Unique -AsString

if($conn.Count -gt 1){
    Write-Output "###########"
    Write-Output "OK - Number of iSCI sessions: $(($conn).Count)"
}
if((Get-IscsiTarget).IsConnected){
    Write-Output "###########"
    Write-Output "OK - iSCSI initiator is connected to target(s)"
}
if($targetIP.Count -gt 1){
    Write-Output "###########"
    Write-Output "OK - More than 2 iSCSI targets configured" 
    Write-Output "###########"
}
Write-Output "MPIO policy set to: $mpioPolicy"
Write-Output "###########" 

