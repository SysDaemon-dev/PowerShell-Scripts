<#
.SYNOPSIS
Automated Generator for Microsoft Intune Printer Mapping Detection and Remediation Scripts.

.DESCRIPTION
This script streamlines the creation of printer mapping scripts for Microsoft Intune 
Remediations. It reads a list of printer names from a designated text file (Printer.txt) 
and automatically generates the corresponding Detection and Remediation scripts.

Key Features:
- Bulk Processing: Reads line-by-line from a source text file.
- Sub-Printer Merging: Features a toggle ($mergeSubPrinters) to automatically group 
  sub-printers (e.g., 050-PRT-102-Farbe) into the same script array as their parent 
  printer (e.g., 050-PRT-102), reducing script sprawl in Intune.
- Dynamic Substitution: Automatically builds the PowerShell array and replaces the 
  %PRINTER_ARRAY% placeholder within the predefined templates.
- Organized Output: Creates a dedicated subfolder for each processed printer (or base 
  printer) and saves the newly generated scripts into their respective folders.
- Intune-Ready Naming Convention: Automatically applies standard naming formats.

Prerequisites:
- A valid 'Printer.txt' file located in the path defined by $printerListPath.
- Execution permissions to create directories and files in $outputDirectory.

.EXAMPLE
.\Generate-IntunePrinterScripts.ps1
Generates detection and remediation scripts based on the provided Printer.txt list.

.NOTES
Author: sysdeamon.dev
Date: 2026-07-27

VERSION HISTORY:
1.3.0 - 2026-07-27
 - Implemented $mergeSubPrinters toggle for intelligent grouping.
 - Replaced manual string variables with a dynamic %PRINTER_ARRAY% injector.
 - Added Regex parsing to identify base printers vs. sub-printers.
 - Polished according to sysdeamon.dev standards.
1.2.0 - 2026-07-27
 - Added dynamic subfolder creation per printer.
 - Expanded script synopsis and description for better team usability.
1.1.1 - 2026-07-27
 - Adjusted templates to retain explicit array structure.
1.1.0 - 2026-07-27 
 - Embedded templates as Here-Strings for standalone execution.
 - Defined Server and Domain variables dynamically.
1.0.0 - 2026-07-06
 - Initial manual templates provided.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Define paths and static variables
[string]$printerListPath = "C:\INTUNE\Printer\Printer.txt"
[string]$outputDirectory = "C:\INTUNE\Printer\Multi"
[string]$serverName = "%PRINTSERVER%"
[string]$domain = "%DOMAIN%"

# TOGGLE: Set to $true to bundle sub-printers into their parent's script. 
# Set to $false to create separate, standalone scripts for every single line.
[bool]$mergeSubPrinters = $true

<#
.SYNOPSIS
Creates a tailored Intune script file by replacing placeholders in a template.

.DESCRIPTION
Takes the template string, formats the printer list into a proper PowerShell array 
syntax, replaces the %PRINTER_ARRAY% placeholder, and outputs a formatted .ps1 file.

.PARAMETER BaseName
The name of the primary printer (used for file naming).

.PARAMETER PrinterList
An array of printer strings to be injected into the script.

.PARAMETER Template
The raw string template of the script (Detection or Remediation).

.PARAMETER OutputPath
The full file path where the generated script will be saved.

.EXAMPLE
New-IntunePrinterScript -BaseName "050-PRT-102" -PrinterList @("050-PRT-102") -Template $detectionTemplate -OutputPath "C:\Temp\Detect.ps1"
#>
function New-IntunePrinterScript {
    param (
        [Parameter(Mandatory=$true)]
        [string]$BaseName,

        [Parameter(Mandatory=$true)]
        [string[]]$PrinterList,

        [Parameter(Mandatory=$true)]
        [string]$Template,

        [Parameter(Mandatory=$true)]
        [string]$OutputPath
    )

    # Build the PowerShell array string dynamically with the Server and Domain
    [string[]]$arrayItems = foreach ($printerItem in $PrinterList) {
        "`"\\$serverName.$domain\$printerItem`""
    }
    
    # Join with a comma and a newline/indentation for clean code formatting
    [string]$arrayString = $arrayItems -join ",`n        "

    # Inject the generated array into the template
    [string]$content = $Template.Replace("%PRINTER_ARRAY%", $arrayString)

    Set-Content -Path $OutputPath -Value $content -Encoding UTF8
    Write-Output " - Created: $(Split-Path $OutputPath -Leaf) ($($PrinterList.Count) printer/s bundled)"
}

# Create base output directory if missing
if (-not (Test-Path -Path $outputDirectory)) {
    [void](New-Item -ItemType Directory -Path $outputDirectory)
    Write-Output "Created base output directory at $outputDirectory"
}

# --- TEMPLATES ---

[string]$detectionTemplate = @'
<#
.SYNOPSIS
Detects if specific network printers are mapped for the current user.

.DESCRIPTION
This script checks the user's mapped printers against a predefined array of required network printers. 
Intended to be used as a Detection Script in Microsoft Intune Remediations.
Must run in user context (Run this script using the logged-on credentials = Yes).

.EXAMPLE
.\DetectionScript.ps1
Runs the detection logic and exits with 0 (Compliant) or 1 (Non-Compliant).

.NOTES
Author: sysdeamon.dev
Date: 2026-07-27

VERSION HISTORY:
1.3.0 - 2026-07-27
 - Automated generation via generator script.
 - Supports dynamic array injection for multiple sub-printers.
1.0.0 - 2026-07-06 
 - Initial template creation.
#>

try {
    # Dynamically injected list of required printers
    [string[]]$printersToAdd = @(
        %PRINTER_ARRAY%
    )

    # Get names of currently mapped printers for the logged-on user
    [string[]]$currentPrinterList = (Get-Printer).Name

    # Check if there are any printers in the list that the user does not currently have mapped
    [string[]]$missingPrinters = $printersToAdd | Where-Object { $currentPrinterList -notcontains $_ }

    # Evaluate missing printers and exit accordingly for Intune Remediations
    if ($missingPrinters.Count -gt 0) {
        Write-Output "Status: Non-Compliant. Missing printers detected: $($missingPrinters -join ', ')"
        exit 1 # Triggers the Remediation script
    } else {
        Write-Output "Status: Compliant. All required printers are already mapped."
        exit 0 # Does not trigger the Remediation script
    }
}
catch {
    Write-Output "Error during printer detection: $($_.Exception.Message)"
    exit 1 
}
'@

[string]$remediationTemplate = @'
<#
.SYNOPSIS
Maps specific network printers for the current user.

.DESCRIPTION
This script maps a predefined array of network printers for the logged-on user.
It evaluates which printers are missing and attempts to add only those.
Intended to be used as a Remediation Script in Microsoft Intune Remediations.
Must run in user context (Run this script using the logged-on credentials = Yes).
Prerequisite: Point-to-Print restrictions must be handled via GPO or Intune Configuration Profile.

.EXAMPLE
.\RemediationScript.ps1
Maps the missing printers defined in the array.

.NOTES
Author: sysdeamon.dev
Date: 2026-07-27

VERSION HISTORY:
1.3.0 - 2026-07-27
 - Automated generation via generator script.
 - Supports dynamic array injection for multiple sub-printers.
1.0.0 - 2026-07-06 
 - Initial template creation.
 - Added Add-NetworkPrinter function with dedicated synopsis.
#>

<#
.SYNOPSIS
Adds a single network printer connection for the user.

.DESCRIPTION
Attempts to map a network printer using Add-Printer. It captures and logs specific errors, 
such as unreachable print servers or missing drivers, ensuring the main script continues.

.PARAMETER PrinterPath
The UNC path of the network printer to map.

.EXAMPLE
Add-NetworkPrinter -PrinterPath "\\printserver.domain.com\050-PRT-102"
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
    # Dynamically injected list of required printers (MUST exactly match the detection script)
    [string[]]$printersToAdd = @(
        %PRINTER_ARRAY%
    )

    # Get currently mapped printers
    [string[]]$currentPrinterList = (Get-Printer).Name
    
    # Identify which printers are actually missing to avoid redundant processing
    [string[]]$missingPrinters = $printersToAdd | Where-Object { $currentPrinterList -notcontains $_ }

    # Process each missing printer through the custom function
    if ($missingPrinters.Count -gt 0) {
        foreach ($printerItem in $missingPrinters) {
            Add-NetworkPrinter -PrinterPath $printerItem
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
'@

# --- EXECUTION ---

if (-not (Test-Path -Path $printerListPath)) {
    Write-Error "Printer list not found at $printerListPath. Please provide the file."
    return
}

# Read printers from file
[string[]]$printers = Get-Content -Path $printerListPath
Write-Output "Parsing $($printers.Count) entries from $printerListPath..."

# Grouping logic: Identify base printers and bundle their sub-printers
[hashtable]$groupedPrinters = @{}

foreach ($printerItem in $printers) {
    [string]$trimmedPrinter = $printerItem.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedPrinter)) { continue }

    # Regex checks for standard format (e.g., "050-PRT-102") to identify the base name
    [string]$baseName = ""
    if ($mergeSubPrinters -and $trimmedPrinter -match "^(\d{3}-PRT-\d{2,3})") {
        $baseName = $matches[1]
    } else {
        # If merging is disabled or format is completely unknown, treat line as standalone base
        $baseName = $trimmedPrinter
    }

    if (-not $groupedPrinters.ContainsKey($baseName)) {
        $groupedPrinters[$baseName] = [System.Collections.Generic.List[string]]::new()
    }
    $groupedPrinters[$baseName].Add($trimmedPrinter)
}

Write-Output "Consolidated into $($groupedPrinters.Count) script packages. Generating files..."

# Generate the script packages
foreach ($baseKey in $groupedPrinters.Keys) {
    Write-Output "Processing package: $baseKey"
    [string[]]$printerListArray = $groupedPrinters[$baseKey].ToArray()

    # Create dedicated subfolder for the base printer
    [string]$printerFolder = Join-Path -Path $outputDirectory -ChildPath $baseKey
    if (-not (Test-Path -Path $printerFolder)) {
        [void](New-Item -ItemType Directory -Path $printerFolder)
    }

    # Define strict naming convention inside the new subfolder based on the BaseName
    [string]$detectionFile = Join-Path -Path $printerFolder -ChildPath "ipr-WIN-PrinterMapping_$($baseKey)_user_detection_x64_01.ps1"
    [string]$remediationFile = Join-Path -Path $printerFolder -ChildPath "ipr-WIN-PrinterMapping_$($baseKey)_user_remediation_x64_01.ps1"

    # Generate scripts
    New-IntunePrinterScript -BaseName $baseKey -PrinterList $printerListArray -Template $detectionTemplate -OutputPath $detectionFile
    New-IntunePrinterScript -BaseName $baseKey -PrinterList $printerListArray -Template $remediationTemplate -OutputPath $remediationFile
}

Write-Output "Done. All scripts generated successfully under $outputDirectory."