$path = 'C:\logfolder'
$logFile = "$path\Configlog.txt"
$evalpath = Test-Path $path
$evalfile = Test-Path $logfile
$timestamp =(Get-Date).ToString("MM-dd-yy-hh-mm")

if($evalpath -eq $false){

    New-Item $path -ItemType Directory 
    New-Item -ItemType File -Path $logFile 
    
}

$clusterinfo1=Get-Cluster | Select-Object Name, DynamicQuorum, WitnessDynamicWeight, QuarantineThreshold, QuarantineDuration, PreventQuorum | Format-List | Out-String
$clusterinfo2=Get-ClusterQuorum | Select-Object QuorumType, QuorumResource | Format-Table | Out-String
$clusterinfo3=Get-ClusterNode  | Get-ClusterResource | Select-Object OwnerNode, OwnerGroup, Name, State | Format-Table | Out-String
$clusterinfo4=Get-Cluster | Get-ClusterResource | Get-ClusterOwnerNode | Format-Table | Out-String

Add-Content -Path $logFile -Value "#### Cluster Overview #### Generated at $timestamp"
Add-Content -Path $logFile -Value $clusterinfo1
Add-Content -Path $logFile -Value "#### Cluster Quorum Info #### Generated at $timestamp"
Add-Content -Path $logFile -Value $clusterinfo2
Add-Content -Path $logFile -Value "#### Cluster Resources Overview #### Generated at $timestamp"
Add-Content -Path $logFile -Value $clusterinfo3
Add-Content -Path $logFile -Value "#### Cluster Resources Owners #### Generated at $timestamp"
Add-Content -Path $logFile -Value $clusterinfo4

$CNO = Get-ClusterResource | ?{$_.ResourceType -eq 'Network Name'} 
$resources = $CNO | foreach{Get-ClusterResource $_.Name | Get-ClusterParameter Name, HostRecordTTL, RegisterAllProvidersIP } | Format-Table | Out-String
$dependencies = $CNO | foreach{Get-ClusterResourceDependency -Resource $_.Name} | Format-Table | Out-String

Add-Content -Path $logFile -Value "#### Cluster Resources Detail #### Generated at $timestamp"
Add-Content -Path $logFile -Value $resources
Add-Content -Path $logFile -Value "#### Cluster Dependencies #### Generated at $timestamp"
Add-Content -Path $logFile -Value $dependencies

##Exports Cluster Log for last 60m
Get-ClusterLog -TimeSpan 60 -Destination $path 
