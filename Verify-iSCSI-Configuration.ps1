 <#
.SYNOPSIS
    Verifies iSCSI configuration, multipathing policy, MPIO settings, and iSCSI sessions.
.DESCRIPTION
    This script checks the following:
    - iSCSI initiator configuration
    - MPIO settings and status
    - Multipathing policy for iSCSI disks
    - Number of active iSCSI sessions
    - iSCSI connection status to targets
.NOTES
    File Name      : Verify-iSCSI-Configuration.ps1
    Author         : Your Name
    Prerequisite   : PowerShell 5.1 or later, MPIO feature installed
    Execution Policy: Should be run with administrative privileges
#>

#Requires -RunAsAdministrator

function Get-iSCSIConfiguration {
    Write-Host "`n=== iSCSI Initiator Configuration ===" -ForegroundColor Cyan
    
    # Check if iSCSI service is running
    $iscsiService = Get-Service -Name MSiSCSI
    if ($iscsiService.Status -ne "Running") {
        Write-Host "iSCSI Service is NOT running. Current status: $($iscsiService.Status)" -ForegroundColor Red
    } else {
        Write-Host "iSCSI Service is running." -ForegroundColor Green
    }
    
    # Get iSCSI initiator settings
    try {
        # Method 1: Using iscsicli command
        Write-Host "`niSCSI Initiator Name:" -ForegroundColor Yellow
        $initiatorName = iscsicli ListInitiatorNodeName
        if ($initiatorName) {
            $initiatorName | ForEach-Object {
                if ($_ -match "InitiatorName") {
                    $_.Trim()
                }
            }
        } else {
            Write-Host "Could not retrieve iSCSI Initiator Name" -ForegroundColor Yellow
        }

        # Method 2: Using WMI (alternative)
        try {
            $wmiInitiator = Get-WmiObject -Namespace root\wmi -Class MSiSCSIInitiator_MethodClass -ErrorAction SilentlyContinue
            if ($wmiInitiator) {
                Write-Host "`nInitiator IQN (from WMI): $($wmiInitiator.iSCSINodeName)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "WMI method failed: $_" -ForegroundColor Yellow
        }

        # Get iSCSI initiator port information (using iscsicli)
        Write-Host "`niSCSI Initiator Port Information:" -ForegroundColor Yellow
        $portInfo = iscsicli ListInitiatorPortals
        if ($portInfo) {
            $portInfo | ForEach-Object {
                if ($_ -match "Initiator Portal") {
                    $_.Trim()
                }
            }
        } else {
            Write-Host "Could not retrieve iSCSI port information" -ForegroundColor Yellow
        }

    } catch {
        Write-Host "Error retrieving iSCSI initiator information: $_" -ForegroundColor Red
    }
}

function Get-MPIOSettings {
    Write-Host "`n=== MPIO Configuration ===" -ForegroundColor Cyan
    
    # Check if MPIO is installed
    $mpioFeature = Get-WindowsFeature -Name Multipath-IO
    if (-not $mpioFeature.Installed) {
        Write-Host "MPIO feature is NOT installed." -ForegroundColor Red
        return
    } else {
        Write-Host "MPIO feature is installed." -ForegroundColor Green
    }
    
    # Check MPIO service status
    $mpioService = Get-Service -Name mpio
    if ($mpioService.Status -ne "Running") {
        Write-Host "MPIO Service is NOT running. Current status: $($mpioService.Status)" -ForegroundColor Red
    } else {
        Write-Host "MPIO Service is running." -ForegroundColor Green
    }
    
    # Get MPIO settings
    try {
        $mpioSettings = Get-MPIOSetting
        Write-Host "`nMPIO Settings:" -ForegroundColor Yellow
        $mpioSettings | Format-List *
        
        $mpioDiskCount = (Get-MSDSMSupportedHW).Count
        Write-Host "`nNumber of disks supporting MPIO: $mpioDiskCount" -ForegroundColor Yellow
    } catch {
        Write-Host "Error retrieving MPIO settings: $_" -ForegroundColor Red
    }
}

function Get-MultipathPolicy {
    Write-Host "`n=== Multipathing Policy ===" -ForegroundColor Cyan
    
    try {
        # Get global MPIO load balance policy
        $globalPolicy = Get-MSDSMGlobalDefaultLoadBalancePolicy
        Write-Host "`nGlobal MPIO Load Balance Policy: $globalPolicy" -ForegroundColor Yellow
        
        # Get iSCSI disks
        $mpioDisks = Get-Disk | Where-Object { $_.BusType -eq "iSCSI" }
        
        if ($mpioDisks.Count -eq 0) {
            Write-Host "No iSCSI disks found." -ForegroundColor Yellow
            return
        }
        
        foreach ($disk in $mpioDisks) {
            Write-Host "`nDisk Number: $($disk.Number) | Friendly Name: $($disk.FriendlyName) | Serial: $($disk.SerialNumber)" -ForegroundColor Yellow
            
            # Get disk paths using MPIO cmdlet
            $diskPaths = Get-MSDSMSupportedHW | Where-Object { $_.DeviceName -like "*$($disk.SerialNumber)*" }
            
            if ($diskPaths) {
                Write-Host "Number of paths: $($diskPaths.Count)"
                Write-Host "Path Details:"
                $diskPaths | Format-Table -AutoSize -Property DeviceName, PathId, State
                
                # Get the specific disk's load balance policy
                $diskPolicy = (Get-MSDSMAutomaticClaimSettings | Where-Object { $_.BusType -eq "iSCSI" }).LoadBalancePolicy
                Write-Host "Disk Load Balance Policy: $diskPolicy"
            } else {
                Write-Host "No MPIO paths found for this disk." -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "Error retrieving multipath policy: $_" -ForegroundColor Red
    }
}

function Get-iSCSISessions {
    Write-Host "`n=== iSCSI Sessions ===" -ForegroundColor Cyan
    
    try {
        $sessions = Get-IscsiSession
        $sessionCount = $sessions.Count
        
        Write-Host "Number of active iSCSI sessions: $sessionCount" -ForegroundColor Yellow
        
        if ($sessionCount -gt 0) {
            Write-Host "`nSession Details:" -ForegroundColor Yellow
            $sessions | Format-Table -AutoSize -Property InitiatorNodeAddress, TargetNodeAddress, SessionIdentifier, IsConnected, IsDiscovered
            
            Write-Host "`nConnection Details:" -ForegroundColor Yellow
            $connections = Get-IscsiConnection
            $connections | Format-Table -AutoSize -Property InitiatorAddress, TargetAddress, ConnectionIdentifier, State
        }
        
        $targets = Get-IscsiTarget
        Write-Host "`nConfigured iSCSI Targets ($($targets.Count)):" -ForegroundColor Yellow
        $targets | Format-Table -AutoSize -Property NodeAddress, IsConnected
    } catch {
        Write-Host "Error retrieving iSCSI session information: $_" -ForegroundColor Red
    }
}

function Get-NetworkAdaptersForiSCSI {
    Write-Host "`n=== Network Adapters Used for iSCSI ===" -ForegroundColor Cyan
    
    try {
        $iscsiAdapters = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*iSCSI*" -or $_.Name -like "*iSCSI*" }
        
        if ($iscsiAdapters.Count -eq 0) {
            Write-Host "No dedicated iSCSI network adapters found." -ForegroundColor Yellow
            return
        }
        
        foreach ($adapter in $iscsiAdapters) {
            Write-Host "`nAdapter Name: $($adapter.Name)" -ForegroundColor Yellow
            Write-Host "Status: $($adapter.Status)"
            Write-Host "Speed: $($adapter.LinkSpeed)"
            
            $ipConfig = Get-NetIPConfiguration -InterfaceIndex $adapter.InterfaceIndex
            $ipConfig | Format-Table -AutoSize -Property InterfaceAlias, IPv4Address, IPv6Address
        }
    } catch {
        Write-Host "Error retrieving network adapter information: $_" -ForegroundColor Red
    }
}

# Main execution
Clear-Host
Write-Host "=== iSCSI Configuration Verification Script ===" -ForegroundColor Magenta
Write-Host "Run time: $(Get-Date)`n"

Get-iSCSIConfiguration
Get-MPIOSettings
Get-MultipathPolicy
Get-iSCSISessions
Get-NetworkAdaptersForiSCSI

Write-Host "`n=== Verification Complete ===" -ForegroundColor Magenta 
