<#
.SYNOPSIS
Creates and configures a Windows Server Failover Cluster (WSFC) instance with the specified cluster name, domain, cluster nodes, and IP addresses.

This script performs the following actions in order:
- Creates the WSFC with Active Directory and DNS registration using provided cluster name and IP addresses.
- Waits for the cluster to become accessible and stable before continuing.
- Renames IP Address resources to the actual IP address values for clarity.
- Renames the default cluster group and the cluster Network Name resource to the specified cluster name.
- Ensures each IP address resource is owned exclusively by its corresponding cluster node, matching the order of the provided node and IP lists (important for AWS multi-IP configurations).
- Sets the cluster name resource dependencies on all IP address resources (logical OR).
- Runs cluster validation tests to confirm correct configuration.

IMPORTANT:
- The order of nodes and their corresponding IP addresses must match exactly. For example, the first node is owner of the first IP, second node owner of second IP, and so on.
- The script assumes all nodes are online, reachable, domain joined, and have the Failover Clustering feature installed.
- Intermittent sleep commands allow for cluster and resource state stabilization and should not be removed without adjusting for your environment.

.PARAMETER WSFCClusterName
The short name of the WSFC to create (without domain name).

.PARAMETER DomainName
The Active Directory domain name for fully-qualified cluster name construction.

.PARAMETER ClusterNodes
An array of fully qualified domain names of nodes to add to the cluster.

.PARAMETER ClusterIPs
An array of IP addresses corresponding to cluster IP address resources, aligned in order with the nodes.

.EXAMPLE
.\Create-WSFC.ps1 -WSFCClusterName "WSFC1" -DomainName "cobra.kai" `
  -ClusterNodes @("Node1.cobra.kai","Node2.cobra.kai") `
  -ClusterIPs @("172.16.0.10","172.32.0.20")

This creates a two-node failover cluster with specified node domain names and IP addresses,
renames resources accordingly, sets IP ownerships, updates dependencies, and validates the cluster.
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$WSFCClusterName,

    [Parameter(Mandatory=$true)]
    [string]$DomainName,

    [Parameter(Mandatory=$true)]
    [string[]]$ClusterNodes,

    [Parameter(Mandatory=$true)]
    [string[]]$ClusterIPs
)

# Validate input lengths
if ($ClusterNodes.Count -ne $ClusterIPs.Count) {
    Throw "ClusterNodes and ClusterIPs arrays must be the same length."
}

$FQDN = $WSFCClusterName + "." + $DomainName

# Create the cluster with AD and DNS registration
Write-Host "Creating cluster $WSFCClusterName with nodes: $($ClusterNodes -join ', ') and IPs: $($ClusterIPs -join ', ')"
New-Cluster -Name $WSFCClusterName -Node $ClusterNodes -AdministrativeAccessPoint ActiveDirectoryAndDNS -StaticAddress $ClusterIPs

Write-Host "Hang tight, this will take a while..."
Start-Sleep -Seconds 10
# Wait until the cluster is stable and accessible, retrying every 5 seconds, up to 1 minute
$maxRetries = 12
$retryIntervalSeconds = 5
$clusterReady = $false
for ($i = 0; $i -lt $maxRetries; $i++) {
    try {
        Get-ClusterGroup -Name "Cluster Group" -ErrorAction Stop  | Out-Null
        Write-Host "Cluster $WSFCClusterName is accessible."
        $clusterReady = $true
        break
    }
    catch {
        Write-Verbose "Cluster $WSFCClusterName not accessible yet. Retrying in $retryIntervalSeconds seconds..."
        Start-Sleep -Seconds $retryIntervalSeconds
    }
}

if (-not $clusterReady) {
    Throw "Cluster $WSFCClusterName not reachable after $($maxRetries * $retryIntervalSeconds) seconds. Aborting script."
}

# Rename IP Address cluster resources to IP address string where needed
$ClusterIPResources = Get-ClusterResource -Cluster $FQDN | Where-Object { $_.ResourceType -eq "IP Address" }

foreach ($resource in $ClusterIPResources) {
    $currentName = $resource.Name
    $ipAddress = ($resource | Get-ClusterParameter -Name Address -ErrorAction Stop).Value

    if ($currentName -ne $ipAddress -and !(Get-ClusterResource -Name $ipAddress -Cluster $FQDN -ErrorAction SilentlyContinue)) {
        try {
            Write-Host "Renaming resource '$currentName' to '$ipAddress'"
            $resource.Name = $ipAddress
        }
        catch {
            Write-Warning "Error renaming $currentName to $ipAddress $_"
        }
    }
}
Start-Sleep -Seconds 5
# Rename cluster group and network name resource to Cluster name, if exists
try {
    $clusterGroup = Get-ClusterGroup -Name "Cluster Group" -Cluster $FQDN -ErrorAction Stop
    Write-Host "Renaming default cluster group 'Cluster Group' to '$WSFCClusterName'"
    $clusterGroup.Name = $WSFCClusterName

    $networkNameResource = Get-ClusterResource -Cluster $FQDN | Where-Object {
        $_.ResourceType -eq "Network Name" -and $_.OwnerGroup -eq $WSFCClusterName
    }
    if ($networkNameResource) {
        Write-Host "Renaming Network Name resource to '$WSFCClusterName'"
        $networkNameResource.Name = $WSFCClusterName
    }
}
catch {
    Write-Warning "Unable to rename cluster group or network name resource: $_"
}
Start-Sleep -Seconds 15
# Set possible owners for IP address resources - each IP owned by its respective node only
# Get the cluster name resource
$clusterNameResource = Get-ClusterResource -Name $WSFCClusterName -Cluster $FQDN -ErrorAction Stop
$ClusterNodeNames=Get-ClusterNode
if ($clusterNameResource.State -eq 'Online') {
    Write-Host "Now configuring '$WSFCClusterName' with proper IP Address ownerships"
    Start-Sleep -Seconds 5 
}
else {
    Write-Host "Looks like ClusterName is Offline. Trying to bring '$WSFCClusterName' Online"
    $clusterNameResource | Start-ClusterResource
    Start-Sleep -Seconds 5
}
for ($i = 0; $i -lt $ClusterIPs.Count; $i++) {
    $ipResource = Get-ClusterResource -Name $ClusterIPs[$i] -Cluster $FQDN -ErrorAction Stop

    if ($ipResource.State -eq 'Online') {
        Write-Host "IP resource '$($ClusterIPs[$i])' is Online"
    
    }
    else {
         Write-Host "IP resource '$($ClusterIPs[$i])' is Offline - This is normal do not worry!"
    }
    Write-Host "Setting possible owner of IP '$($ClusterIPs[$i])' to node '$($ClusterNodes[$i])'"
    $ipResource | Set-ClusterOwnerNode -Owners ($ClusterNodeNames[$i]).Name
    Start-Sleep -Seconds 2
}

Write-Host "'$WSFCClusterName' is Online with correct IP Address ownership"

# Set dependencies for cluster name resource to depend on any of the IP addresses
$dependencyString = ($ClusterIPs | ForEach-Object { "[$_]" }) -join " or "
Write-Host "Setting cluster name resource dependencies to: $dependencyString"
Set-ClusterResourceDependency -Resource $WSFCClusterName -Dependency $dependencyString

Start-Sleep -Seconds 2
# Test the cluster configuration
Write-Host "Running cluster validation tests"
Test-Cluster -Cluster $FQDN 
