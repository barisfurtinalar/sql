<#
.SYNOPSIS
Creates and configures a Windows Server Failover Cluster (WSFC) with given cluster name, nodes, and IP addresses.
This script:
- Creates the cluster
- Renames IP address resources to match their IP
- Sets possible owners for each secondary IP exclusive to a single node (AWS compatible)
- Sets cluster name resource dependencies on the IP addresses
- Runs cluster validation tests

.PARAMETER WSFCClusterName
The name of the failover cluster to create.

.PARAMETER ClusterNodes
An array of cluster node names (computer names) to add to the cluster.

.PARAMETER ClusterIPs
An array of IP addresses corresponding to cluster IP address resources.

.EXAMPLE
.\Create-WSFC.ps1 -WSFCClusterName "WSFC.cobra.kai" -ClusterNodes @("Node1.cobra.kai","Node2.cobra.kai") -ClusterIPs @("172.16.0.10","172.32.0.20")
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$WSFCClusterName,

    [Parameter(Mandatory=$true)]
    [string[]]$ClusterNodes,

    [Parameter(Mandatory=$true)]
    [string[]]$ClusterIPs
)

# Validate input lengths
if ($ClusterNodes.Count -ne $ClusterIPs.Count) {
    Throw "ClusterNodes and ClusterIPs arrays must be the same length."
}

# Create the cluster with AD and DNS registration
Write-Host "Creating cluster $WSFCClusterName with nodes: $($ClusterNodes -join ', ') and IPs: $($ClusterIPs -join ', ')"
New-Cluster -Name $WSFCClusterName -Node $ClusterNodes -AdministrativeAccessPoint ActiveDirectoryAndDNS -StaticAddress $ClusterIPs

# Rename IP Address cluster resources to IP address string where needed
$ClusterIPResources = Get-ClusterResource -Cluster $WSFCClusterName | Where-Object { $_.ResourceType -eq "IP Address" }

foreach ($resource in $ClusterIPResources) {
    $currentName = $resource.Name
    $ipAddress = ($resource | Get-ClusterParameter -Name Address -ErrorAction Stop).Value

    if ($currentName -ne $ipAddress -and !(Get-ClusterResource -Name $ipAddress -Cluster $WSFCClusterName -ErrorAction SilentlyContinue)) {
        try {
            Write-Host "Renaming resource '$currentName' to '$ipAddress'"
            $resource.Name = $ipAddress
        }
        catch {
            Write-Warning "Error renaming $currentName to $ipAddress: $_"
        }
    }
}

# Rename cluster group and network name resource to Cluster name, if exists
try {
    $clusterGroup = Get-ClusterGroup -Name "Cluster Group" -Cluster $WSFCClusterName -ErrorAction Stop
    Write-Host "Renaming default cluster group 'Cluster Group' to '$WSFCClusterName'"
    $clusterGroup.Name = $WSFCClusterName

    $networkNameResource = Get-ClusterResource -Cluster $WSFCClusterName | Where-Object {
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

# Set possible owners for IP address resources - each IP owned by its respective node only
for ($i = 0; $i -lt $ClusterIPs.Count; $i++) {
    $ipResource = Get-ClusterResource -Name $ClusterIPs[$i] -Cluster $WSFCClusterName -ErrorAction Stop
    Write-Host "Setting possible owner of IP '$($ClusterIPs[$i])' to node '$($ClusterNodes[$i])'"
    $ipResource | Set-ClusterOwnerNode -Owners $ClusterNodes[$i]
}

# Set dependencies for cluster name resource to depend on any of the IP addresses
$dependencyString = ($ClusterIPs | ForEach-Object { "[$_]" }) -join " or "
Write-Host "Setting cluster name resource dependencies to: $dependencyString"
Set-ClusterResourceDependency -Resource $WSFCClusterName -Dependency $dependencyString

# Test the cluster configuration
Write-Host "Running cluster validation tests"
Test-Cluster -Cluster $WSFCClusterName
