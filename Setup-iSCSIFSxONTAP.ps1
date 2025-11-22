 <#
.SYNOPSIS
Configures iSCSI client on Windows Server to connect to Amazon FSx for NetApp ONTAP with MPIO enabled.
This script:
- Starts and sets the iSCSI Initiator Service to automatic.
- Adds iSCSI target portals for specified IPs.
- Registers MPIO hardware support for iSCSI.
- Establishes multiple iSCSI sessions per target portal with multipath enabled and persistent connections.
- Sets the MPIO load balance policy to Round Robin.

.PARAMETER TargetPortalAddresses
An array of IP addresses of the iSCSI target portals. Must include at least two addresses.

.PARAMETER LocaliSCSIAddress
The local iSCSI Initiator IP address to use for the connection.

.PARAMETER ConnectionCount
The number of iSCSI sessions to establish per target portal. Default is 8.

.EXAMPLE
.\Setup-iSCSIFSxONTAP.ps1 -TargetPortalAddresses @("172.16.0.10","172.32.0.20") -LocaliSCSIAddress "172.16.0.100" -ConnectionCount 8
#>

param (
    [Parameter(Mandatory = $true)]
    [string[]]$TargetPortalAddresses,

    [Parameter(Mandatory = $true)]
    [string]$LocaliSCSIAddress,

    [Parameter(Mandatory = $false)]
    [int]$ConnectionCount = 8
)

# Start and configure iSCSI Initiator Service
Write-Host "Starting iSCSI Initiator Service..."
Start-Service MSiSCSI
Set-Service -Name msiscsi -StartupType Automatic
Start-Sleep -Seconds 5
# Confirm service started before continuing
$service = Get-Service MSiSCSI
if ($service.Status -ne 'Running') {
    Write-Error "MSiSCSI service failed to start. Exiting script."
    exit 1
}

# Validate minimum target portal count
if ($TargetPortalAddresses.Count -lt 2) {
    Write-Error "At least two TargetPortalAddresses must be provided. Exiting script."
    exit 1
}

Write-Host "Starting iSCSI client configuration..."

# Create iSCSI Target Portals if they do not already exist
foreach ($TargetPortalAddress in $TargetPortalAddresses) {
    if (-not (Get-IscsiTargetPortal -TargetPortalAddress $TargetPortalAddress -ErrorAction SilentlyContinue)) {
        Write-Host "Adding iSCSI Target Portal: $TargetPortalAddress"
        New-IscsiTargetPortal -TargetPortalAddress $TargetPortalAddress -TargetPortalPortNumber 3260 -InitiatorPortalAddress $LocaliSCSIAddress
    } else {
        Write-Host "iSCSI Target Portal $TargetPortalAddress already exists"
    }
}

# Add MPIO support for iSCSI
if (-not (Get-MSDSMSupportedHW | Where-Object { $_.VendorId -eq "MSFT2005" -and $_.ProductId -eq "iSCSIBusType_0x9" })) {
    Write-Host "Adding MPIO support for iSCSI"
    New-MSDSMSupportedHW -VendorId MSFT2005 -ProductId iSCSIBusType_0x9
} else {
    Write-Host "MPIO support for iSCSI already configured"
}

# Establish multiple iSCSI connections per target portal based on ConnectionCount parameter
foreach ($TargetPortalAddress in $TargetPortalAddresses) {
    $targets = Get-IscsiTarget | Where-Object { $_.TargetPortalAddress -eq $TargetPortalAddress }
    foreach ($target in $targets) {
        Write-Host "Establishing up to $ConnectionCount connections to target portal $TargetPortalAddress"
        1..$ConnectionCount | ForEach-Object {
            if ($target.ConnectionState -ne "Connected") {
                Write-Host "Connecting to iSCSI target: $($target.NodeAddress) (Session $_)"
                Connect-IscsiTarget -NodeAddress $target.NodeAddress -IsMultipathEnabled $true `
                    -TargetPortalAddress $TargetPortalAddress -InitiatorPortalAddress $LocaliSCSIAddress -IsPersistent $true
            }
        }
    }
}

# Set the MPIO Load Balance Policy to Round Robin
Write-Host "Setting MPIO load balancing policy to Round Robin"
Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy RR

Write-Host "iSCSI client configuration completed."
 
