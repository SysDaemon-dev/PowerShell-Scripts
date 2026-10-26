<#
.SYNOPSIS
    Schneller Gesundheitscheck für einen Windows-Client oder -Server.
.DESCRIPTION
    Zeigt Betriebssystem, Laufzeit, freien Speicherplatz und gestoppte automatische Dienste an.
    Nur lesend – es werden keine Änderungen am System vorgenommen.
.EXAMPLE
    .\Get-SysDaemonHealth.ps1
.NOTES
    Autor: SysDaemon.dev
    Tags: Monitoring, Windows, Support
    Module: CimCmdlets
#>
[CmdletBinding()]
param()

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$uptime = (Get-Date) - $os.LastBootUpTime

[PSCustomObject]@{
    Computer = $env:COMPUTERNAME
    System   = $os.Caption
    Laufzeit = '{0}d {1}h {2}m' -f $uptime.Days, $uptime.Hours, $uptime.Minutes
} | Format-List

Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' |
    Select-Object DeviceID,
        @{ Name = 'Frei (GB)'; Expression = { [math]::Round($_.FreeSpace / 1GB, 1) } },
        @{ Name = 'Frei (%)';  Expression = { [math]::Round($_.FreeSpace / $_.Size * 100) } } |
    Format-Table -AutoSize

Get-CimInstance -ClassName Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" |
    Select-Object Name, DisplayName, State |
    Format-Table -AutoSize
