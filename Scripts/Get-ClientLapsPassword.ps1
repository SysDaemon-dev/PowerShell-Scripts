<#
.SYNOPSIS
    Interactive script to retrieve the local administrator password from Active Directory (LAPS).

.DESCRIPTION
    This script prompts the user for elevated Active Directory credentials and a target device name
    to query the LAPS password. It supports the Windows LAPS module (Get-LapsADPassword) and falls 
    back to Legacy LAPS (AdmPwd.PS) or direct AD attribute querying if required.
    Designed for helpdesk and engineering staff to run on demand.

.PARAMETER ComputerName
    Optional. The hostname of the target computer. If omitted, the script prompts interactively.

.PARAMETER Credential
    Optional. The administrative credentials used for the AD query. If omitted, a login dialog appears.

.EXAMPLE
    .\Get-ClientLapsPassword.ps1
    Launches the interactive prompts for Credentials and ComputerName.

.EXAMPLE
    .\Get-ClientLapsPassword.ps1 -ComputerName "Client01"
    Prompts only for credentials and queries the LAPS password for Client01.

.NOTES
    Author:  sysdeamon.dev
    Date:    2026-11-06
    Version: 1.1.0

    Version History:
    1.1.0 - (2026-11-06) Refactored to sysdeamon.dev enterprise standards. Enforced English language, strict typing, and camelCase variable naming conventions. Removed personal identifiers.
    1.0.0 - (2026-11-05) Initial release. Interactive credential and hostname prompts with Windows LAPS and Legacy LAPS support.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, HelpMessage = "Enter the target device hostname.")]
    [string]$ComputerName,

    [Parameter(Mandatory = $false, HelpMessage = "Enter the privileged AD credentials.")]
    [System.Management.Automation.PSCredential]$Credential
)

function Get-TargetLapsPassword {
    <#
    .SYNOPSIS
        Queries Active Directory for the LAPS password of a specific computer.

    .DESCRIPTION
        Uses Get-LapsADPassword to fetch the password. If the user actually meant Legacy LAPS 
        (ms-Mcs-AdmPwd) and only has the ActiveDirectory module, it provides a clean fallback.

    .PARAMETER TargetDevice
        The hostname of the client to query.

    .PARAMETER AuthCredential
        The PSCredential object used to authenticate against Active Directory.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetDevice,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]$AuthCredential
    )

    try {
        # Check if the modern Windows LAPS cmdlet is available
        if (Get-Command -Name "Get-LapsADPassword" -ErrorAction SilentlyContinue) {
            Write-Host "[INFO] Querying via Windows LAPS module..." -ForegroundColor Cyan
            [object]$lapsResult = Get-LapsADPassword -Identity $TargetDevice -Credential $AuthCredential -AsPlainText -ErrorAction Stop
            
            return [PSCustomObject]@{
                ComputerName   = [string]$lapsResult.ComputerName
                Account        = [string]$lapsResult.Account
                Password       = [string]$lapsResult.Password
                ExpirationTime = [string]$lapsResult.ExpirationTimestamp
                Source         = "Windows LAPS"
            }
        }
        # Fallback to ActiveDirectory module for Legacy LAPS (ms-Mcs-AdmPwd) because AdmPwd.PS lacks -Credential support
        elseif (Get-Command -Name "Get-ADComputer" -ErrorAction SilentlyContinue) {
            Write-Host "[INFO] Windows LAPS cmdlet not found. Falling back to Legacy LAPS (ms-Mcs-AdmPwd) via AD module..." -ForegroundColor Yellow
            [object]$adComputer = Get-ADComputer -Identity $TargetDevice -Properties "ms-Mcs-AdmPwd", "ms-Mcs-AdmPwdExpirationTime" -Credential $AuthCredential -ErrorAction Stop
            
            [string]$expirationTime = if ($adComputer.'ms-Mcs-AdmPwdExpirationTime') {
                ([datetime]::FromFileTime($adComputer.'ms-Mcs-AdmPwdExpirationTime')).ToString("yyyy-MM-dd HH:mm:ss")
            } else {
                "N/A"
            }

            return [PSCustomObject]@{
                ComputerName   = [string]$adComputer.Name
                Account        = "Local Admin (Legacy)"
                Password       = [string]$adComputer.'ms-Mcs-AdmPwd'
                ExpirationTime = $expirationTime
                Source         = "Legacy LAPS (AD Attribute)"
            }
        }
        else {
            throw "Neither the 'LAPS' module nor the 'ActiveDirectory' RSAT module is installed on this machine."
        }
    }
    catch {
        Write-Host "[ERROR] Failed to retrieve LAPS password for '$TargetDevice': $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# --- Main Execution Block ---

Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "           LAPS Password Retriever        " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# 1. Request Credentials if not passed via parameter
if (-not $Credential) {
    Write-Host "Please enter your privileged credentials for the LAPS query..." -ForegroundColor Yellow
    try {
        $Credential = Get-Credential -Message "Enter privileged AD credentials for LAPS" -ErrorAction Stop
    }
    catch {
        Write-Host "[ABORTED] Credential prompt was canceled by the user." -ForegroundColor Red
        exit
    }
}

# 2. Loop for querying devices so the user doesn't have to re-enter credentials for multiple hosts
do {
    if (-not $ComputerName) {
        Write-Host ""
        $ComputerName = (Read-Host -Prompt "Enter the Device Name (e.g., Client01)").Trim()
    }

    if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        Write-Host "[WARNING] Device name cannot be empty. Please try again." -ForegroundColor Yellow
        continue
    }

    # Execute the query
    [object]$queryResult = Get-TargetLapsPassword -TargetDevice $ComputerName -AuthCredential $Credential

    if ($queryResult -and $queryResult.Password) {
        Write-Host ""
        Write-Host "------------------------------------------" -ForegroundColor Green
        Write-Host " Device     : $($queryResult.ComputerName)" -ForegroundColor White
        Write-Host " Account    : $($queryResult.Account)" -ForegroundColor Gray
        Write-Host " Password   : $($queryResult.Password)" -ForegroundColor Green
        Write-Host " Expires on : $($queryResult.ExpirationTime)" -ForegroundColor Gray
        Write-Host " Source     : $($queryResult.Source)" -ForegroundColor DarkGray
        Write-Host "------------------------------------------" -ForegroundColor Green
        
        # Optional convenience: Copy directly to clipboard
        Set-Clipboard -Value $queryResult.Password
        Write-Host "[INFO] Password has been copied to your clipboard!" -ForegroundColor Cyan
    }
    elseif ($queryResult -and -not $queryResult.Password) {
        Write-Host "[WARNING] Device '$ComputerName' was found, but the password attribute is empty (either no LAPS applied or insufficient permissions)." -ForegroundColor Yellow
    }

    # Reset ComputerName for the next iteration if the user wants to query another client
    $ComputerName = $null
    Write-Host ""
    [string]$continueQuery = Read-Host -Prompt "Query another device? (y/n)"

} while ($continueQuery -match "^[yY]$")

Write-Host "Exiting script. Have a productive day!" -ForegroundColor Cyan
Start-Sleep -Seconds 1