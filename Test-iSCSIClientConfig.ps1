 # Get iSCSI connection details
$connections = Get-IscsiConnection
if (!$connections) {
    throw "No iSCSI connections found"
}

$connectionCount = ($connections | Measure-Object).Count
$uniqueTargets = $connections | Select-Object -ExpandProperty TargetAddress | Sort-Object -Unique
$targetCount = ($uniqueTargets | Measure-Object).Count

# Check iSCSI target connection status
$targetStatus = Get-IscsiTarget

# Validate connections
if ($connectionCount -ge 2) {
    Write-Output "Multiple iSCSI sessions detected: $connectionCount session(s)"
} else {
    Write-Output "WARNING: Only $connectionCount iSCSI session(s) detected. Recommend multiple sessions for redundancy"
}

# Validate target connectivity
if ($targetStatus.IsConnected) {
    Write-Output "iSCSI initiator successfully connected to target(s)"
} else {
    Write-Output "ERROR: iSCSI initiator not connected to any targets"
}

# Validate target count
if ($targetCount -ge 2) {
    Write-Output "Multiple iSCSI targets configured: $targetCount targets"
    Write-Output " Target IPs: $($uniqueTargets -join ', ')"
} else {
    Write-Output "WARNING: Only $targetCount iSCSI target(s) detected. Recommend multiple targets for redundancy"
}

# Check MPIO policy
try {
    $mpioPolicy = Get-MSDSMGlobalDefaultLoadBalancePolicy
    Write-Output "MPIO Load Balance Policy: $mpioPolicy"
} catch {
    Write-Output "MPIO policy check skipped - MPIO may not be installed"
}  
