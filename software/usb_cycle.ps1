#
# This file is part of CamLink 4K.
#
# SPDX-License-Identifier: BSD-2-Clause

<#
.SYNOPSIS
Software replug of the Cam Link on Windows: disables the USB host controller it is attached to,
waits, enables it again and waits for the device to come back.

.DESCRIPTION
On the AMD xHCI controller this was tested on, disabling the controller cuts the port power, so
the FX3 and the FPGA reboot as on a real replug (`camlink.py stats` shows main_loops back near 0).
Other boards may keep VBUS on, which only re-enumerates the device: check main_loops after a
cycle. Every other device on the same controller drops for the off time too, so plug the Cam Link
into a port whose controller carries nothing important. -List shows them without cycling.

Close any app that has the Cam Link's video or audio open first (a capture app, or the card
selected as a microphone). Windows vetoes the disable for it and queues the disable for the
next reboot. The script refuses to run while any app uses a microphone or camera, unless -Force.

Needs an elevated PowerShell (pnputil /disable-device).

.EXAMPLE
.\usb_cycle.ps1 -List
.\usb_cycle.ps1 -OffSeconds 3
#>

param(
    [int]$OffSeconds = 3,
    [int]$WaitSeconds = 30,
    [string]$Match = 'VID_1209&PID_0001',
    [switch]$List,
    [switch]$Force
)

function Get-CaptureUsers {
    # Apps using a microphone or camera right now: Windows records LastUsedTimeStop = 0 for them.
    # One of them holding the Cam Link makes audiodg.exe or the camera stack veto the disable, and
    # Windows then queues the disable for the next reboot instead of failing.
    $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
    foreach ($cap in 'microphone', 'webcam') {
        Get-ChildItem "$root\$cap" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.LastUsedTimeStart -and $p.LastUsedTimeStop -eq 0) {
                "{0} ({1})" -f ($_.PSChildName -replace '#', '\'), $cap
            }
        }
    }
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $List -and -not $admin) { Write-Error 'Run from an elevated PowerShell (or use -List).'; exit 1 }

$present = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)

# Each parent lookup is a separate WMI query, so cache them: USB devices share hubs on the way up.
# (Passing every instance id in one call fails with a WMI quota error.)
$parents = @{}
function Get-Parent($id) {
    if (-not $parents.ContainsKey($id)) {
        $parents[$id] = (Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_Parent -ErrorAction SilentlyContinue).Data
    }
    $parents[$id]
}

function Get-Controller($id) {
    # Walk up the device tree to the PCI host controller.
    while ($id -and $id -notmatch '^PCI\\') { $id = Get-Parent $id }
    $id
}

function Find-CamLink {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match [regex]::Escape($Match) -and $_.InstanceId -notmatch '&MI_' } |
        Select-Object -First 1
}

$dev = Find-CamLink
if (-not $dev) { Write-Error "No present USB device matches '$Match'."; exit 1 }
$ctrl = Get-Controller $dev.InstanceId
if (-not $ctrl) { Write-Error "No PCI host controller found above $($dev.InstanceId)."; exit 1 }

Write-Host "Device:     $($dev.InstanceId)"
Write-Host "Controller: $((Get-PnpDevice -InstanceId $ctrl).FriendlyName)"
Write-Host "            $ctrl"

# Other devices on the same controller (dropped during the cycle).
$others = $present |
    Where-Object { $_.InstanceId -match '^USB\\' -and $_.InstanceId -notmatch [regex]::Escape($Match) -and
        $_.InstanceId -notmatch '^USB\\ROOT_HUB' -and (Get-Controller $_.InstanceId) -eq $ctrl }
if ($others) {
    Write-Host "Also on this controller:"
    $others | ForEach-Object { Write-Host "            $($_.FriendlyName)  $($_.InstanceId)" }
} else {
    Write-Host "Nothing else on this controller."
}
$users = @(Get-CaptureUsers)
if ($users) {
    Write-Host "Using a microphone or camera now (close them first, or pass -Force):"
    $users | ForEach-Object { Write-Host "            $_" }
}
if ($List) { exit 0 }
if ($users -and -not $Force) {
    Write-Error 'An app is using a microphone or camera. A disable vetoed by it stays queued until reboot.'
    exit 1
}

$t0 = Get-Date
pnputil /disable-device "$ctrl" | Out-Null
$rc = $LASTEXITCODE
if ($rc -eq 3010) {
    # Vetoed: the controller keeps running, but it comes up disabled after the next reboot and
    # pnputil refuses to touch it until then.
    Write-Warning 'An application blocked the disable, and Windows queued it for the next reboot.'
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-PnP'; Id = 225; StartTime = $t0.AddSeconds(-5) } -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Warning $_.Message }
    Write-Warning "After the reboot, run: pnputil /enable-device `"$ctrl`""
    Write-Warning 'Or set ConfigFlags to 0 under HKLM\SYSTEM\CurrentControlSet\Enum\<controller id> before rebooting.'
    exit 1
}
if ($rc) { Write-Error "pnputil /disable-device failed ($rc)."; exit 1 }
Write-Host "Controller disabled, waiting $OffSeconds s."
Start-Sleep -Seconds $OffSeconds
pnputil /enable-device "$ctrl" | Out-Null
if ($LASTEXITCODE) { Write-Error "pnputil /enable-device failed ($LASTEXITCODE)."; exit 1 }

$t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt $WaitSeconds) {
    if (Find-CamLink) {
        Write-Host ("Device back after {0:N1} s." -f ((Get-Date) - $t0).TotalSeconds)
        exit 0
    }
    Start-Sleep -Milliseconds 250
}
Write-Error "Device not back after $WaitSeconds s."
exit 1
