  Function Get-SQLInstances {
  Param(
      $Server = $env:ComputerName
      )
    $SQLservicesHash=@{}
    Get-WmiObject win32_service -computerName $Server | ?{$_.Caption -match "SQL Server*" -and $_.PathName -match "sqlservr.exe"} | %{$SQLservicesHash.Add($_.Name,$_.Status)}
    return $SQLservicesHash 
} 

##Put the statement you want to run in all instances inside speech marks below
$statement=@"
    WITH reads_and_writes AS (
	SELECT db.name AS database_name,
		SUM(user_seeks + user_scans + user_lookups) AS reads,
		SUM(user_updates) AS writes,
		SUM(user_seeks + user_scans + user_lookups + user_updates) AS all_activity
	FROM sys.dm_db_index_usage_stats us
	INNER JOIN sys.databases db ON us.database_id = db.database_id
	GROUP BY db.name)
    SELECT database_name, reads, 
		FORMAT(((reads * 1.0) / all_activity),'P')  AS reads_percent,
		writes,
		FORMAT(((writes * 1.0) / all_activity),'P')  AS writes_percent
	FROM reads_and_writes rw
	ORDER BY database_name;

"@

$SQLinstances = (Get-SQLInstances).Keys
$SQLinstancesName = $SQLinstances.Split("$") 

foreach($sqli in $SQLinstancesName){
    if($sqli -match 'MSSQLSERVER'){
    
       Write-Output $sqli
       Invoke-Sqlcmd -ServerInstance "$env:COMPUTERNAME" -Query $statement | fl
       }
    
    elseif($sqli -match "MSSQL"){
       ## 
    }
    else{
        
         Write-Output $sqli
         Invoke-Sqlcmd -ServerInstance "$env:COMPUTERNAME\$sqli" -Query $statement | fl

        }
    }
 
