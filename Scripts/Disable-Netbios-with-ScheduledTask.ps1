<#
.SYNOPSIS
    Deploys a Scheduled Task to dynamically disable NetBIOS over TCP/IP.

.DESCRIPTION
    Since Intune Remediations are not available under certain licenses, this script acts as a deployment wrapper. 
    It drops a payload script to the local disk and creates a Windows Scheduled Task. 
    The task triggers on system startup and user logon to ensure any newly connected network interfaces 
    (e.g., USB docks) have NetBIOS disabled.

.EXAMPLE
    .\Install-NetBIOSScheduledTask.ps1
    Executes the deployment wrapper, creates the necessary directories, writes the worker payload, 
    and registers the scheduled task in the system.

.NOTES
    Author: sysdeamon.dev
    Company: YourCompany

.VERSION
    1.2.0

.REVISION HISTORY
    1.2.0 - 2026-07-14 - Redesigned for licensing limitation. Implemented Scheduled Task deployment. Applied strict typing.
    1.1.0 - 2026-07-14 - Added logging functionality to C:\Windows\Logs\Software.
    1.0.0 - 2026-07-14 - Initial creation. Disabled NetBIOS via CIM instance and Registry.
#>

function Install-NetBIOSScheduledTask {
    [CmdletBinding()]
    param()

    [string]$companyPath = "C:\ProgramData\YourCompany\NetBIOS"
    [string]$payloadScript = Join-Path -Path $companyPath -ChildPath "Worker-DisableNetBIOS.ps1"
    [string]$taskName = "YourCompany_DisableNetBIOS"

    # Create directory for the payload script
    if (-not (Test-Path -Path $companyPath)) {
        try {
            New-Item -Path $companyPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Error "Failed to create directory $companyPath. Error: $($_.Exception.Message)"
            return
        }
    }

    # Define the worker script payload
    [string]$scriptContent = @'
<#
.SYNOPSIS
    Worker script to disable NetBIOS on active network adapters.

.DESCRIPTION
    This script is triggered by a Scheduled Task. It queries all network adapters with an active 
    IP configuration using CIM and sets the TcpipNetbiosOptions to 2 (Disabled). 
    It also logs execution to C:\Windows\Logs\Software.
#>
function Disable-NetBIOSWorker {
    [CmdletBinding()]
    param()

    [string]$logDirectory = "C:\Windows\Logs\Software"
    [string]$logFile = Join-Path -Path $logDirectory -ChildPath "Disable-NetBIOS.log"

    function Write-Log {
        param (
            [string]$Message,
            [string]$Level = "INFO"
        )
        [string]$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        [string]$logLine = "[$timestamp] [$Level] $Message"
        
        try {
            Add-Content -Path $logFile -Value $logLine -ErrorAction SilentlyContinue
        } catch {}
    }

    if (-not (Test-Path -Path $logDirectory)) {
        New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
    }

    Write-Log -Message "Scheduled Task triggered (Logon/Startup): Checking active network adapters for NetBIOS." -Level "INFO"

    [uint32]$netBiosDisabledValue = 2
    [array]$networkAdapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True"

    foreach ($adapter in $networkAdapters) {
        if ($adapter.TcpipNetbiosOptions -ne $netBiosDisabledValue) {
            try {
                Invoke-CimMethod -InputObject $adapter -MethodName SetTcpipNetbios -Arguments @{TcpipNetbiosOptions = $netBiosDisabledValue} -ErrorAction Stop
                Write-Log -Message "Disabled NetBIOS for adapter: $($adapter.Description)" -Level "INFO"
            }
            catch {
                Write-Log -Message "Failed to disable NetBIOS for $($adapter.Description). Error: $($_.Exception.Message)" -Level "ERROR"
            }
        }
    }

    [string]$registryPath = "HKLM:\System\CurrentControlSet\Services\NetBT\Parameters\Interfaces\Tcpip_*"
    try {
        Set-ItemProperty -Path $registryPath -Name "NetbiosOptions" -Value $netBiosDisabledValue -ErrorAction Stop
    }
    catch {
        Write-Log -Message "Failed to update NetBT Registry keys. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}

Disable-NetBIOSWorker
'@

    # Write payload script to disk
    try {
        Set-Content -Path $payloadScript -Value $scriptContent -Force -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to write payload script to disk. Error: $($_.Exception.Message)"
        return
    }

    # Remove existing Scheduled Task if it exists to allow clean updates
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    # Define Scheduled Task parameters
    $taskAction = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$payloadScript`""
    
    # Triggers: Run on system startup and whenever a user logs on
    $triggerStartup = New-ScheduledTaskTrigger -AtStartup
    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn
    
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

    # Register the Scheduled Task
    try {
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger @($triggerStartup, $triggerLogon) -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
        Write-Output "Successfully deployed Scheduled Task: $taskName"
    }
    catch {
        Write-Error "Failed to deploy Scheduled Task: $($_.Exception.Message)"
    }
}

# Execute the main deployment function
Install-NetBIOSScheduledTask