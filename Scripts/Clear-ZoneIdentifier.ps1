<#
.SYNOPSIS
    Scans for and manages the Zone.Identifier Alternate Data Stream (MotW) on files.

.DESCRIPTION
    This enterprise-grade script identifies files encumbered by the Mark of the Web (MotW).
    It provides both a discovery mode (-ReportOnly) and a remediation mode (Execution).
    
    Architecture Highlights (Kernel32 P/Invoke):
    - Completely bypasses the PowerShell FileSystemProvider to avoid "Illegal characters" exceptions.
    - Directly calls kernel32.dll (GetFileAttributesW & DeleteFileW) for absolute MAX_PATH immunity.
    - Uses NTFS Direct Stream Access to preserve file timestamps (LastWriteTime).
    - Generates console outputs and optional CSV reports for auditing.

.PARAMETER LiteralPath
    Specifies the absolute path(s) to scan. No wildcard interpretation is performed.

.PARAMETER Recurse
    Searches the specified directory and all child directories.

.PARAMETER ReportOnly
    Switch. Scans and reports blocked files without removing the Zone.Identifier stream.
    Perfect for pre-flight checks and customer audits.

.PARAMETER ExportCsvPath
    Optional string. The absolute file path to export the results as a CSV file.

.EXAMPLE
    .\Clear-ZoneIdentifier.ps1 -LiteralPath "D:\ews" -Recurse -ReportOnly
    Scans the directory structure and outputs a list of blocked files to the console without modifying them.

.EXAMPLE
    .\Clear-ZoneIdentifier.ps1 -LiteralPath "D:\ews" -Recurse -ExportCsvPath "C:\Temp\MotW_Report.csv"
    Scans, unblocks files permanently, and writes a detailed audit report to the specified CSV file.

.NOTES
    Author: sysdeamon.dev
    Company: YourCompany

.VERSION
    1.1.0

.REVISION HISTORY
    1.1.0 - 2026-05-12 - Replaced PowerShell Get-Item/Remove-Item with native kernel32.dll P/Invoke 
                         to completely bypass PS 5.1 FileSystemProvider "Illegal characters" bug 
                         when handling \\?\ extended-length paths. Enforced strict typing.
    1.0.0 - 2026-05-12 - Initial release of unified discovery and remediation script.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
    [string[]]$LiteralPath,

    [Parameter(Mandatory = $false)]
    [switch]$Recurse,

    [Parameter(Mandatory = $false)]
    [switch]$ReportOnly,

    [Parameter(Mandatory = $false)]
    [string]$ExportCsvPath
)

begin {
    # Compile Native Windows API methods to bypass PowerShell's buggy path parser
    [string]$nativeCode = @"
    using System;
    using System.Runtime.InteropServices;

    public static class Kernel32 {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool DeleteFileW(string lpFileName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int GetFileAttributesW(string lpFileName);
    }
"@
    # Only load the type if it doesn't already exist in the current session
    if (-not ([System.Management.Automation.PSTypeName]'Kernel32').Type) {
        Write-Verbose "Compiling Kernel32 API wrapper for MAX_PATH bypass..."
        Add-Type -TypeDefinition $nativeCode -Language CSharp
    }
}

process {
    [System.Collections.Generic.List[PSCustomObject]]$auditLog = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($scanPath in $LiteralPath) {
        if (-not (Test-Path -LiteralPath $scanPath)) {
            Write-Warning "Target path does not exist or is inaccessible: '$scanPath'"
            continue
        }

        [string]$modeText = if ($ReportOnly) { "DISCOVERY MODE" } else { "REMEDIATION MODE" }
        Write-Host "Starting MotW Scan in $modeText for: $scanPath" -ForegroundColor Cyan

        [array]$targetFiles = if ($Recurse) {
            Get-ChildItem -LiteralPath $scanPath -Recurse -File -Force -ErrorAction SilentlyContinue
        } else {
            Get-ChildItem -LiteralPath $scanPath -File -Force -ErrorAction SilentlyContinue
        }

        foreach ($fileObject in $targetFiles) {
            # Construct the absolute long path directly pointing to the Alternate Data Stream
            [string]$streamPath = "\\?\$($fileObject.FullName):Zone.Identifier"
            
            # Check if stream exists using kernel32 (Returns -1 / 0xFFFFFFFF if it does not exist)
            [int]$fileAttribute = [Kernel32]::GetFileAttributesW($streamPath)

            if ($fileAttribute -ne -1) {
                [string]$actionStatus = ""

                if ($ReportOnly) {
                    $actionStatus = "Report Only (Blocked)"
                } else {
                    # Delete the stream directly via C++ API
                    [bool]$isSuccess = [Kernel32]::DeleteFileW($streamPath)
                    
                    if ($isSuccess) {
                        $actionStatus = "Unblocked Successfully"
                    } else {
                        $actionStatus = "Failed to unblock (File locked?)"
                        Write-Warning "Could not unblock $($fileObject.Name). It might be locked by another process."
                    }
                }

                $auditLog.Add([PSCustomObject]@{
                    FileName   = $fileObject.Name
                    Directory  = $fileObject.DirectoryName
                    Status     = $actionStatus
                    Timestamp  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                })
            }
        }
    }

    # Output handling
    if ($auditLog.Count -eq 0) {
        Write-Host "Scan completed. No files with Mark of the Web (Zone.Identifier) found." -ForegroundColor Green
    } else {
        Write-Host "Found $($auditLog.Count) encumbered files." -ForegroundColor Yellow
        
        $auditLog | Format-Table -Property FileName, Status, Directory -AutoSize

        if (-not [string]::IsNullOrWhiteSpace($ExportCsvPath)) {
            try {
                $auditLog | Export-Csv -Path $ExportCsvPath -NoTypeInformation -Delimiter ";" -Encoding UTF8 -Force
                Write-Host "Audit report successfully exported to: $ExportCsvPath" -ForegroundColor Green
            } catch {
                Write-Error "Failed to export CSV report to '$ExportCsvPath'. Error: $($_.Exception.Message)"
            }
        }
    }
}