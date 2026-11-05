<#
.SYNOPSIS
Detects if specific network printers are mapped for the current user.

.DESCRIPTION
This script checks the user's currently mapped printers against a predefined array of required network printers. 
It is intended to be used as a Detection Script within Microsoft Intune Remediations.
The script must be executed in the user context (Setting: Run this script using the logged-on credentials = Yes).

.NOTES
Author: sysdeamon.dev
Date: 2026-07-06

.VERSION HISTORY
1.1.0 - 2026-11-04
 - Refactored variable names to match conventions.
 - Ensured English language throughout the script.
 - Anonymized author information.
1.0.0 - 2026-07-06 
 - Initial template creation.
 - Added try/catch block for better error handling in Intune.
 - Added Write-Output for compliant/non-compliant status tracking.

.EXAMPLE
.\Detect-NetworkPrinters.ps1
Executes the detection logic and exits with 1 (Non-Compliant) if any required printer is missing, or 0 (Compliant) if all are mapped.
#>

try {
    # Define the template placeholders for the required printers
    [string[]]$requiredPrinters = @(
        "\\%SERVERNAME%.%DOMAIN%\%PRINTERNAME1%",
        "\\%SERVERNAME%.%DOMAIN%\%PRINTERNAME2%"
    )

    # Get names of currently mapped printers for the logged-on user
    [string[]]$mappedPrinters = (Get-Printer).Name

    # Check if there are any printers in the list that the user does not currently have mapped
    $missingPrinters = $requiredPrinters | Where-Object { $mappedPrinters -notcontains $_ }

    # Evaluate missing printers and exit accordingly for Intune Remediations
    if ($null -ne $missingPrinters -and $missingPrinters.Count -gt 0) {
        Write-Output "Status: Non-Compliant. Missing printers detected: $($missingPrinters -join ', ')"
        exit 1 # Triggers the Remediation script
    } else {
        Write-Output "Status: Compliant. All required printers are already mapped."
        exit 0 # Does not trigger the Remediation script
    }
}
catch {
    Write-Output "Error during printer detection: $($_.Exception.Message)"
    exit 1 # Triggers remediation just in case
}