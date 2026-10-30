<#
.SYNOPSIS
    Detects if the EFI system partition has sufficient free space.
    Designed for Intune Proactive Remediation.

.DESCRIPTION
    Checks the System partition (EFI System Partition / "System Reserved").
    If the free space is below the specified threshold ($MinimumFreeMB), 
    it exits with code 1 (non-compliant) to trigger the remediation script.
    If sufficient space is available, it exits with code 0 (compliant).

.EXAMPLE
    .\Detect-EfiSpace.ps1 -MinimumFreeMB 150
    Executes the detection script requiring at least 150 MB of free space on the EFI partition.

.NOTES
    Context: System Engineering / Maintenance / YourCompany
    Author: sysdeamon.dev
    Date: 2026-10-30
    Important: Runs as SYSTEM via Intune - no elevation prompt needed. 
               Do not add #Requires -RunAsAdministrator (it would break the detection run).

    History:
    Version 1.2 - 2026-10-30 - sysdeamon.dev
    - Applied SysDaemon coding standards: Updated author, enforced strict naming conventions, and added explicit typing.
    
    Version 1.1 - 2026-10-01 - sysdeamon.dev
    - Applied Coding standards (Synopsis, History, English structure).
    - Replaced Write-Host with Write-Output for reliable Intune transcript capture.
    - Improved logic flow and variable naming.

    Version 1.0 - 2026-09-30 - sysdeamon.dev
    - Initial creation.
#>

param(
    [int]$MinimumFreeMB = 100
)

# ---------------------------------------------------------------------------
# MAIN EXECUTION
# ---------------------------------------------------------------------------

try {
    # 1. Locate the System partition
    $systemPartition = Get-Partition -ErrorAction Stop | Where-Object { $_.IsSystem -eq $true } | Select-Object -First 1

    if (-not $systemPartition) {
        Write-Output "Detection failed: No System partition found."
        exit 1
    }

    # 2. Retrieve volume details
    $volumeInfo = $systemPartition | Get-Volume -ErrorAction SilentlyContinue
    [double]$totalMB = [math]::Round($systemPartition.Size / 1MB, 1)

    # 3. Check free space if volume is queryable
    if ($volumeInfo) {
        [double]$freeMB = [math]::Round($volumeInfo.SizeRemaining / 1MB, 1)
        
        if ($freeMB -lt $MinimumFreeMB) {
            Write-Output "Non-compliant: System partition low on space. $freeMB MB free (Target: $MinimumFreeMB MB), Total: $totalMB MB."
            exit 1
        }
        
        Write-Output "Compliant: System partition OK. $freeMB MB free."
        exit 0
    }

    # 4. Fallback if volume details are hidden but partition is generally too small
    if ($totalMB -lt ($MinimumFreeMB * 1.5)) {
        Write-Output "Non-compliant: System partition is too small overall to verify free space (Total: $totalMB MB)."
        exit 1
    }

    # 5. Fallback for unqueryable but sufficiently large partitions
    Write-Output "Compliant: System partition size OK (Total: $totalMB MB, exact free space not queryable)."
    exit 0

} catch {
    Write-Output "Detection encountered a critical error: $($_.Exception.Message)"
    exit 1
}