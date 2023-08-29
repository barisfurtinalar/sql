##Install-Module -Name AWSPowerShell 
##Set-ExecutionPolicy RemoteSigned 

$SQLMetric=Invoke-Sqlcmd -Query "SELECT * FROM sys.dm_os_wait_stats WHERE wait_type = 'PAGEIOLATCH_EX'"

$dimension= New-Object -TypeName Amazon.CloudWatch.Model.Dimension
$dimension.Name='SystemName'
$dimension.Value=[System.Environment]::MachineName.ToString() 

$Metric= New-Object -TypeName Amazon.CloudWatch.Model.MetricDatum
$Metric.Timestamp = [DateTime]::UtcNow
$Metric.MetricName = 'PAGEIOLATCH_EX'
$Metric.Value = $SQLMetric[2]
$Metric.Dimensions=  $dimension[0] 

Write-CWMetricData -Namespace SQLServers -MetricData $Metric

$SQLMetric2=Invoke-Sqlcmd -Query "SELECT counter_name, cntr_value FROM sys.dm_os_performance_counters WHERE [object_name]='SQLServer:Buffer Manager' AND [counter_name]='Buffer cache hit ratio'" 

$Metric2= New-Object -TypeName Amazon.CloudWatch.Model.MetricDatum
$Metric2.Timestamp = [DateTime]::UtcNow
$Metric2.MetricName = 'Page_Life_Expectancy'
$Metric2.Value = $SQLMetric2.cntr_value
$Metric2.Dimensions=$dimension[0]                                                                     

Write-CWMetricData -Namespace SQLServers -MetricData $Metric2,$Metric 
