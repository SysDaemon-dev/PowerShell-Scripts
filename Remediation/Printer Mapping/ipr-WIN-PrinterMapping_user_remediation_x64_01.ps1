<#
.SYNOPSIS
Maps specific network printers for the current user.

.DESCRIPTION
This script maps a predefined array of network printers for the logged-on user.
It evaluates which printers are currently missing and attempts to add only those.
It is intended to be used as a Remediation Script within Microsoft Intune Remediations.
The script must be executed in the user context (Setting: Run this script using the logged-on credentials = Yes).
Prerequisite: Point-to-Print restrictions must be handled via GPO or an Intune Configuration Profile beforehand.

.NOTES
Author: sysdeamon.dev
Date: 2026-07-06

.VERSION HISTORY
1.1.0 - 2026-11-04
 - Refactored variable names for consistency (camelCase for locals).
 - Translated all outputs and comments to English.
 - Anonymized author information.
 - Ensured explicit typing for parameters.
1.0.0 - 2026-07-06 
 - Initial template creation.
 - Added Add-NetworkPrinter function with dedicated synopsis.
 - Implemented try/catch blocks for granular error logging on a per-printer basis.

.EXAMPLE
.\Remediate-NetworkPrinters.ps1
Executes the remediation logic, checking for missing printers and mapping them individually.
#>

<#
.SYNOPSIS
Adds a single network printer connection for the user.

.DESCRIPTION
Attempts to map a network printer using the Add-Printer cmdlet. It captures and logs specific errors, 
such as unreachable print servers or missing drivers, ensuring the main script execution continues.

.PARAMETER PrinterPath
The UNC path of the network printer to map.
#>
function Add-NetworkPrinter {
    param (
        [Parameter(Mandatory=$true)]
        [string]$PrinterPath
    )
    try {
        Write-Output "Attempting to map printer: $PrinterPath"
        Add-Printer -ConnectionName $PrinterPath -ErrorAction Stop
        Write-Output "Successfully mapped: $PrinterPath"
    }
    catch {
        Write-Output "Failed to map $PrinterPath. Reason: $($_.Exception.Message)"
    }
}

try {
    # Define the template placeholders (MUST exactly match the detection script)
    [string[]]$requiredPrinters = @(
        "\\%SERVERNAME%.%DOMAIN%\%PRINTERNAME1%",
        "\\%SERVERNAME%.%DOMAIN%\%PRINTERNAME2%"
    )

    # Get currently mapped printers
    [string[]]$mappedPrinters = (Get-Printer).Name
    
    # Identify which printers are actually missing to avoid redundant processing
    $missingPrinters = $requiredPrinters | Where-Object { $mappedPrinters -notcontains $_ }

    # Process each missing printer through the custom function
    if ($null -ne $missingPrinters -and $missingPrinters.Count -gt 0) {
        foreach ($printer in $missingPrinters) {
            Add-NetworkPrinter -PrinterPath $printer
        }
        exit 0
    } else {
        Write-Output "No missing printers found during remediation phase. Script finished."
        exit 0
    }
}
catch {
    Write-Output "Critical error in remediation wrapper: $($_.Exception.Message)"
    exit 1
}