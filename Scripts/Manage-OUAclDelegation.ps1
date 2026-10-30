<#
.SYNOPSIS
    Checks, sets, or cleans AD delegation rights for computer objects on an AD Organizational Unit.

.DESCRIPTION
    Version 6.0 introduces a dedicated 'Clean' action for full rollbacks and a unified 
    purge logic. The 'Set' action now guarantees a completely blank slate by purging all 
    legacy (V4) and current (V5) rules for the specified identity before applying the new 
    NetUserSetInfo SAM-RPC baseline.

.PARAMETER OuDistinguishedName
    The Distinguished Name of the target OU, e.g., 'OU=Clients,DC=domain,DC=local'.

.PARAMETER IdentityReference
    The security identity. Defaults to 'NT AUTHORITY\SELF'.

.PARAMETER Action
    The action to execute: 
    'Test'  - Validates current permissions.
    'Set'   - Purges existing rules and applies the required baseline.
    'Clean' - Completely removes all configured rules for the identity on this OU.

.EXAMPLE
    .\Set-OUDelegation.ps1 -OuDistinguishedName "OU=Workstations,DC=yourdomain,DC=com" -Action Test
    Tests if the required baseline permissions are present for 'NT AUTHORITY\SELF'.

.EXAMPLE
    .\Set-OUDelegation.ps1 -OuDistinguishedName "OU=Workstations,DC=yourdomain,DC=com" -Action Set
    Purges old rules and sets the required V6.0 baseline permissions.

.NOTES
    Author: sysdeamon.dev
    Company: YourCompany

.VERSION
    6.0

.REVISION HISTORY
    6.0 - 2026-10-30 - Added 'Clean' action for full rollback. Unified purge logic for true idempotency. Refactored variables and types.
    5.0 - 2026-09-24 - Reverted to generic "Write/Read All Properties" to satisfy SAM-RPC limits. Added auto-cleanup.
    4.3 - 2026-09-24 - Added explicit semicolons to variable declarations to prevent copy-paste parsing errors.
    4.2 - 2026-09-24 - Hardened type casting in test function.
    4.1 - 2026-09-24 - Added 'Read All Properties' to satisfy Netlogon pre-checks.
    4.0 - 2026-09-24 - Upgraded test logic to verify specific Enum flags using bitwise operators.
    3.0 - 2026-09-23 - Merged Set and Test scripts into a single unified tool.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, HelpMessage="The Distinguished Name of the OU")]
    [string]$OuDistinguishedName,

    [Parameter(Mandatory=$false)]
    [string]$IdentityReference = "NT AUTHORITY\SELF",

    [Parameter(Mandatory=$false)]
    [ValidateSet("Test", "Set", "Clean")]
    [string]$Action = "Test"
)

$ErrorActionPreference = 'Stop'

# Explicitly load required .NET assembly
Add-Type -AssemblyName System.DirectoryServices

# Require RSAT AD-Tools
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "The ActiveDirectory module is missing. Please install RSAT tools."
    Exit 1
}
Import-Module ActiveDirectory
Set-Location AD:

# Verify if the target OU exists
if (-not (Get-ADOrganizationalUnit -Identity $OuDistinguishedName -ErrorAction SilentlyContinue)) {
    Write-Error "The OU '$OuDistinguishedName' could not be found."
    Exit 1
}

# Resolve the target Security Identifier (SID)
[System.Security.Principal.SecurityIdentifier]$targetSid = $null
if ($IdentityReference -eq "NT AUTHORITY\SELF") {
    $targetSid = [System.Security.Principal.SecurityIdentifier]"S-1-5-10"
} else {
    $identityObject = Get-ADObject -Filter "Name -eq '$IdentityReference'" -ErrorAction SilentlyContinue
    if ($null -eq $identityObject) { throw "Identity '$IdentityReference' could not be found in AD." }
    $targetSid = [System.Security.Principal.SecurityIdentifier]$identityObject.ObjectSid
}

[System.Guid]$computerClassGuid = [System.Guid]"bf967a86-0de6-11d0-a285-00aa003049e2"

# Define the V5/V6 Baseline (Sledgehammer for RPC + Validated Writes for AD consistency)
[array]$ruleDefinitions = @(
    @{ Name = "Read All Properties";           Guid = [System.Guid]::Empty; Right = "ReadProperty" },
    @{ Name = "Write All Properties";          Guid = [System.Guid]::Empty; Right = "WriteProperty" },
    @{ Name = "Validated Write to DNS";        Guid = [System.Guid]"72e39547-7b18-11d1-adef-00c04fd8d5cd"; Right = "ExtendedRight" },
    @{ Name = "Validated Write to SPN";        Guid = [System.Guid]"f3a64788-5306-11d1-a9c5-0000f80367c1"; Right = "ExtendedRight" }
)

<#
.SYNOPSIS
    Evaluates the Access Control List (ACL) against required delegation rules.
#>
function Test-OUDelegationStatus {
    param(
        [Parameter(Mandatory=$true)]
        [System.Security.AccessControl.ObjectSecurity]$AclObject, 
        
        [Parameter(Mandatory=$true)]
        [System.Security.Principal.SecurityIdentifier]$TargetSid, 
        
        [Parameter(Mandatory=$true)]
        [array]$Definitions
    )
    
    foreach ($requirement in $Definitions) {
        [string]$reqName = $requirement.Name;
        [string]$reqRightStr = $requirement.Right;
        
        if ([string]::IsNullOrWhiteSpace($reqRightStr)) { continue; }

        [bool]$isFound = $false;
        [int]$reqRightInt = [int][System.DirectoryServices.ActiveDirectoryRights]$reqRightStr;
        [int]$accumulatedRights = 0;

        foreach ($accessRule in $AclObject.Access) {
            if ($accessRule.AccessControlType -eq 'Allow' -and $accessRule.ObjectType -eq $requirement.Guid) {
                try {
                    [System.Security.Principal.SecurityIdentifier]$ruleSid = $accessRule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]);
                    if ($ruleSid -eq $TargetSid) {
                        if ($null -ne $accessRule.ActiveDirectoryRights) {
                            $accumulatedRights = $accumulatedRights -bor [int]$accessRule.ActiveDirectoryRights;
                        }
                    }
                } catch {}
            }
        }
        
        if (($accumulatedRights -band $reqRightInt) -eq $reqRightInt) {
            $isFound = $true;
        }
        
        [PSCustomObject]@{
            Permission = $reqName;
            Status     = if ($isFound) { "OK (Set)" } else { "MISSING!" };
        }
    }
}

# Retrieve current ACL from target OU
$currentAcl = Get-Acl -Path "AD:\$OuDistinguishedName"

if ($Action -eq "Test") {
    Write-Host "--- MODE: TEST (ACL Validation) ---" -ForegroundColor Cyan
    Write-Host "Evaluating OU: $OuDistinguishedName`n"
    
    $testResults = Test-OUDelegationStatus -AclObject $currentAcl -TargetSid $targetSid -Definitions $ruleDefinitions
    $testResults | Format-Table -AutoSize
    
    if ($testResults.Status -contains "MISSING!") {
        Write-Host "Result: Required permissions are missing. Run the script with '-Action Set' to apply them." -ForegroundColor Yellow
    } else {
        Write-Host "Result: All required permissions are correctly configured." -ForegroundColor Green
    }
}
elseif ($Action -match "^(Set|Clean)$") {
    Write-Host "--- MODE: $($Action.ToUpper()) ---" -ForegroundColor Cyan
    
    # --- UNIVERSAL PURGE LOGIC ---
    Write-Host "Scanning for existing rules assigned to '$IdentityReference' on Computer Objects..." -ForegroundColor Yellow
    [System.Collections.Generic.List[Object]]$rulesToRemove = [System.Collections.Generic.List[Object]]::new()
    
    foreach ($accessRule in $currentAcl.Access) {
        try {
            [System.Security.Principal.SecurityIdentifier]$ruleSid = $accessRule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])
            if ($ruleSid -eq $targetSid -and $accessRule.InheritedObjectType -eq $computerClassGuid) {
                $rulesToRemove.Add($accessRule)
            }
        } catch {}
    }

    if ($rulesToRemove.Count -gt 0) {
        Write-Host "Found $($rulesToRemove.Count) rule(s). Purging them from ACL..." -ForegroundColor Yellow
        foreach ($ruleToRemove in $rulesToRemove) {
            $currentAcl.RemoveAccessRule($ruleToRemove) | Out-Null
        }
    } else {
        Write-Host "No existing rules found. ACL is clean." -ForegroundColor Green
    }

    # --- APPLY NEW RULES (ONLY IF ACTION IS 'SET') ---
    if ($Action -eq "Set") {
        Write-Host "Applying new V6.0 baseline rules for '$IdentityReference'..."
        
        foreach ($definition in $ruleDefinitions) {
            $newRule = New-Object -TypeName System.DirectoryServices.ActiveDirectoryAccessRule -ArgumentList (
                $targetSid, 
                $definition.Right, 
                "Allow", 
                $definition.Guid, 
                "Descendents", 
                $computerClassGuid
            )
            $currentAcl.AddAccessRule($newRule)
        }
    }

    # Write changes to AD
    Set-Acl -Path "AD:\$OuDistinguishedName" -AclObject $currentAcl
    
    if ($Action -eq "Set") {
        Write-Host "ACLs successfully written to Active Directory. Validating results...`n" -ForegroundColor Green
    } else {
        Write-Host "Cleanup completed successfully. Validating results...`n" -ForegroundColor Green
    }

    # Perform immediate re-test to verify successful application or cleanup
    $validatedAcl = Get-Acl -Path "AD:\$OuDistinguishedName"
    $validationResults = Test-OUDelegationStatus -AclObject $validatedAcl -TargetSid $targetSid -Definitions $ruleDefinitions
    $validationResults | Format-Table -AutoSize
}