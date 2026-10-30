#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Cleans up the EFI system partition to free up disk space.
    Designed for unattended execution via Intune to resolve low space compliance issues.

.DESCRIPTION
    1. Evaluates current free space against the required minimum (from Detection).
    2. Creates a backup directory at %SystemDrive%\EFI_Backup.
    3. Temporarily assigns a drive letter to the EFI partition.
    4. Moves specific bloat/logs (BIOS, DEVFW, SystemDiags) to the backup.
    5. Deletes unnecessary Microsoft Boot Fonts.
    6. Removes the drive letter assignment.
    7. Re-evaluates free space to confirm remediation success.
    8. Logs all actions to %SystemRoot%\Logs\YourCompany\EfiCleanupLog.txt.
    9. Returns standard output and exit codes (0/1) for Intune status tracking.

.EXAMPLE
    .\Remediate-EfiSpace.ps1 -MinimumFreeMB 150
    Executes the cleanup process, targeting a minimum of 150 MB free space post-cleanup.

.NOTES
    Context: System Engineering / Maintenance / YourCompany
    Author: sysdeamon.dev
    Date: 2026-10-30

    History:
    Version 1.5 - 2026-10-30 - sysdeamon.dev
    - Applied SysDaemon coding standards: Updated author, enforced camelCase for local variables, and added explicit typing.

    Version 1.4 - 2026-10-01 - sysdeamon.dev
    - Added Intune-compliant output (Write-Output) and exit codes (exit 0 / exit 1).
    - Structured final evaluation to properly flag success or failure to the Intune console.

    Version 1.3 - 2026-10-01 - sysdeamon.dev
    - Integrated logic from Detection Script (MinimumFreeMB and Space Calculation).
    - Added Get-EfiFreeSpace function with its own synopsis.
    - Implemented pre- and post-cleanup space verification in the main execution.

    Version 1.2 - 2026-02-03 - sysdeamon.dev
    - Replaced hardcoded paths ("C:\") with environment variables ($env:SystemDrive, $env:SystemRoot)
    - Minor code cleanup

    Version 1.1 - 2026-02-03 - sysdeamon.dev
    - Refactored code to English (Variables, Comments, Logs)
    - Implemented standard logging function with synopsis
    - Added versioning history block
    - Improved error handling structure

    Version 1.0 - 2025-XX-XX - sysdeamon.dev
    - Initial creation.
#>

# ---------------------------------------------------------------------------
# GLOBAL VARIABLES & PARAMETERS
# ---------------------------------------------------------------------------
param(
    [int]$MinimumFreeMB = 100
)

[string]$logDir      = Join-Path -Path $env:SystemRoot -ChildPath "Logs\YourCompany"
[string]$backupPath  = Join-Path -Path $env:SystemDrive -ChildPath "EFI_Backup"
[string]$mountLetter = "Y:" # Ensure this letter is free in your environment
[array]$hpFolders    = @("BIOS", "DEVFW", "SystemDiags")
[int]$exitCode       = 0    # Default to success, changed if errors or targets not met

# ---------------------------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------------------------

function Write-LogEntry {
    <#
    .SYNOPSIS
        Writes a message with a timestamp to the log file.
    
    .DESCRIPTION
        Logs standard output to the specified directory. If the directory is inaccessible,
        it falls back to the ProgramData directory.

    .PARAMETER Message
        The string message to log.
    
    .PARAMETER Severity
        Optional: Info, Warning, Error (Default: Info).

    .EXAMPLE
        Write-LogEntry -Message "Beginning cleanup process." -Severity "INFO"
        Writes an informational message to the log file.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO","WARNING","ERROR")]
        [string]$Severity = "INFO"
    )

    # Fallback if primary log dir fails
    if (-not (Test-Path -Path $logDir)) {
        try {
            $null = New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop
        } catch {
            # Fallback to ProgramData if SystemRoot is not writable
            $script:logDir = $env:ProgramData 
        }
    }
    
    [string]$logFile   = Join-Path -Path $logDir -ChildPath "EfiCleanupLog.txt"
    [string]$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    [string]$logLine   = "[$timestamp] [$Severity] $Message"
    
    try {
        Add-Content -Path $logFile -Value $logLine -ErrorAction SilentlyContinue
    } catch {
        # Silent fail if completely unable to log
    }
}

function Get-EfiFreeSpace {
    <#
    .SYNOPSIS
        Retrieves the free space of the EFI system partition.
    
    .DESCRIPTION
        Uses Get-Partition and Get-Volume to calculate the remaining free space in MB.
        This mirrors the space calculation logic from the Intune detection script.
    
    .OUTPUTS
        [double] The remaining free space in Megabytes. Returns -1 if not queryable.
    
    .EXAMPLE
        $space = Get-EfiFreeSpace
        Retrieves the current free space and stores it in the $space variable.
    #>
    try {
        $sysPartition = Get-Partition -ErrorAction Stop | Where-Object { $_.IsSystem -eq $true } | Select-Object -First 1
        if (-not $sysPartition) { return -1 }

        $volumeInfo = $sysPartition | Get-Volume -ErrorAction SilentlyContinue
        if ($volumeInfo) {
            return [math]::Round($volumeInfo.SizeRemaining / 1MB, 1)
        }
        return -1
    } catch {
        return -1
    }
}

# ---------------------------------------------------------------------------
# MAIN EXECUTION
# ---------------------------------------------------------------------------

Write-LogEntry -Message "===== EFI Cleanup Script Started (v1.5) ====="
Write-LogEntry -Message "Target Minimum Free Space: $MinimumFreeMB MB"

try {
    # 0. Check initial space
    [double]$initialSpace = Get-EfiFreeSpace
    if ($initialSpace -ge 0) {
        Write-LogEntry -Message "Pre-cleanup free space: $initialSpace MB"
    } else {
        Write-LogEntry -Message "Pre-cleanup free space could not be determined." -Severity "WARNING"
    }

    # 1. Identify EFI Partition
    Write-LogEntry -Message "Searching for EFI system partition..."
    $efiPartition = Get-Partition | Where-Object { $_.IsSystem -eq $true } | Select-Object -First 1
    
    if (-not $efiPartition) {
        throw "No EFI system partition found on this system."
    }

    # 2. Create Backup Directory
    Write-LogEntry -Message "Ensuring backup directory exists: $backupPath"
    if (-not (Test-Path -Path $backupPath)) {
        $null = New-Item -Path $backupPath -ItemType Directory
    }

    # 3. Mount Partition
    if (Test-Path -Path $mountLetter) {
        Write-LogEntry -Message "Drive letter $mountLetter is already in use. Attempting to clear..." -Severity "WARNING"
        $null = Get-Partition | Where-Object { $_.DriveLetter -eq ($mountLetter.Trim(':')) } | Remove-PartitionAccessPath -AccessPath $mountLetter -ErrorAction SilentlyContinue
    }

    Write-LogEntry -Message "Assigning temporary drive letter '$mountLetter'..."
    $null = $efiPartition | Set-Partition -NewDriveLetter ($mountLetter.Trim(':'))
    Start-Sleep -Seconds 2 

    # 4. Process Folders (Move to Backup)
    foreach ($folder in $hpFolders) {
        [string]$sourcePath = Join-Path -Path $mountLetter -ChildPath "EFI\HP\$folder"
        
        if (Test-Path -Path $sourcePath) {
            [string]$destPath = Join-Path -Path $backupPath -ChildPath $folder
            
            if (-not (Test-Path -Path $destPath)) { 
                $null = New-Item -Path $destPath -ItemType Directory 
            }
            
            Move-Item -Path "$sourcePath\*" -Destination $destPath -Force
            Write-LogEntry -Message "Moved content from '$sourcePath' to backup."
        }
    }

    # 5. Clean up Microsoft Fonts (Delete)
    [string]$fontPath = Join-Path -Path $mountLetter -ChildPath "EFI\Microsoft\Boot\Fonts"
    if (Test-Path -Path $fontPath) {
        $files = Get-ChildItem -Path $fontPath
        if ($files.Count -gt 0) {
            Remove-Item -Path "$fontPath\*" -Force
            Write-LogEntry -Message "Deleted $($files.Count) files in fonts directory."
        }
    }
    
    Write-LogEntry -Message "Cleanup operations completed."

} catch {
    [string]$errorMessage = $_.Exception.Message
    Write-LogEntry -Message "CRITICAL ERROR: $errorMessage" -Severity "ERROR"
    Write-Output "Remediation failed due to critical error: $errorMessage"
    $exitCode = 1
} finally {
    # 6. Cleanup / Unmount
    Write-LogEntry -Message "Removing temporary drive letter..."
    
    $part = Get-Partition | Where-Object { $_.DriveLetter -eq ($mountLetter.Trim(':')) }
    if ($part) {
        try {
            $null = $part | Remove-PartitionAccessPath -AccessPath $mountLetter -ErrorAction Stop
        } catch {
            Write-LogEntry -Message "Failed to remove drive letter: $($_.Exception.Message)" -Severity "ERROR"
        }
    }

    # 7. Verify post-cleanup space and set Intune Output/Exit Codes
    [double]$finalSpace = Get-EfiFreeSpace
    if ($finalSpace -ge 0) {
        Write-LogEntry -Message "Post-cleanup free space: $finalSpace MB"
        
        if ($finalSpace -ge $MinimumFreeMB) {
            Write-LogEntry -Message "SUCCESS: Target of $MinimumFreeMB MB reached."
            Write-Output "Remediation successful. EFI free space is now $finalSpace MB (Target: $MinimumFreeMB MB)."
            $exitCode = 0
        } else {
            Write-LogEntry -Message "WARNING: Target of $MinimumFreeMB MB NOT reached despite cleanup." -Severity "WARNING"
            Write-Output "Remediation incomplete. Only $finalSpace MB free. Target of $MinimumFreeMB MB not reached."
            $exitCode = 1
        }
    } else {
        Write-LogEntry -Message "Post-cleanup free space could not be determined." -Severity "WARNING"
        Write-Output "Remediation verification failed: Could not determine final free space."
        $exitCode = 1
    }

    Write-LogEntry -Message "===== EFI Cleanup Script Finished with ExitCode: $exitCode ====="
    
    exit $exitCode
}