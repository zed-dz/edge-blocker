<#
.SYNOPSIS
  Tells Windows not to bring Microsoft Edge (the browser) back.
  WebView2, which many apps need, stays allowed.

.DESCRIPTION
  Sets Microsoft's documented EdgeUpdate policy values and disables the Edge helper service.
  Before changing anything it saves the old values to
  %ProgramData%\EdgeBlocker\backup.json, so edge-unblock.ps1 can put every value back exactly.
  It does not uninstall Edge and does not delete any files.

  If an Edge channel is still installed, its updates are left ON, because an installed browser
  without security updates is a risk. Use -BlockUpdatesToo to change that.

.PARAMETER WhatIf
  Dry run. Prints every change it would make and changes nothing. Admin rights not needed.
  Add -Verbose to see the exact registry value behind each line.

.PARAMETER DryRun
  Same as -WhatIf.

.PARAMETER KeepService
  Leave the MicrosoftEdgeElevationService startup type as it is.

.PARAMETER BlockUpdatesToo
  Block updates even for an Edge channel that is still installed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\edge-block.ps1 -WhatIf
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\edge-block.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [switch]$DryRun,
  [switch]$KeepService,
  [switch]$BlockUpdatesToo
)
$ErrorActionPreference = 'Stop'
# Either switch makes it a dry run. -DryRun wins even next to -WhatIf:$false.
$dry = [bool]$DryRun -or [bool]$WhatIfPreference
$WhatIfPreference = $false

$PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
$UpdateKey = 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate'
$Service   = 'MicrosoftEdgeElevationService'
$BackupDir = Join-Path $env:ProgramData 'EdgeBlocker'
$Backup    = Join-Path $BackupDir 'backup.json'

# Edge browser channels, and the folder each one installs to.
$Browsers = @(
  [pscustomobject]@{ Id = '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'; Name = 'Stable'; Folder = 'Edge' }
  [pscustomobject]@{ Id = '{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}'; Name = 'Beta';   Folder = 'Edge Beta' }
  [pscustomobject]@{ Id = '{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}'; Name = 'Dev';    Folder = 'Edge Dev' }
  [pscustomobject]@{ Id = '{65C35B14-6C1D-4122-AC46-7148CC9D6497}'; Name = 'Canary'; Folder = 'Edge SxS' }
)
$WebView2 = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-Current($key, $name) {
  if (-not (Test-Path $key)) { return $null }
  $p = Get-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue
  if ($null -eq $p) { return $null }
  return $p.$name
}
function Get-Kind($key, $name) {
  if ($null -eq (Get-Current $key $name)) { return $null }
  return "$((Get-Item -Path $key).GetValueKind($name))"
}
function Test-Installed($folder) {
  foreach ($base in $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) {
    if ($base -and (Test-Path (Join-Path $base "Microsoft\$folder\Application\msedge.exe"))) { return $true }
  }
  return $false
}
# Every change goes through here. In a dry run the action is never run.
function Step([string]$Target, [string]$What, [scriptblock]$Action) {
  if ($dry) { Write-Output "What if: $What"; Write-Verbose "         $Target"; return }
  if ($PSCmdlet.ShouldProcess($Target, $What)) { & $Action }
}

if (-not $dry -and -not (Test-Admin)) {
  Write-Error 'Run this from an administrator PowerShell window (or add -WhatIf for a dry run).'
  exit 1
}
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
  Write-Error 'This is a 32-bit PowerShell. Open the normal 64-bit one, or the values go to the wrong place.'
  exit 1
}
if ($dry) { Write-Output 'DRY RUN: nothing will be changed.' }

$Values = @()
$stableInstalled = $false
foreach ($b in $Browsers) {
  $here = Test-Installed $b.Folder
  if ($here -and $b.Name -eq 'Stable') { $stableInstalled = $true }
  $keepUpdates = $here -and -not $BlockUpdatesToo
  if ($keepUpdates) {
    Write-Output "Edge $($b.Name) is still installed. Its updates stay on, so it keeps getting security fixes."
  }
  $Values += [pscustomobject]@{ Key = $PolicyKey; Name = "Install$($b.Id)"; Value = 0; Skip = $false; Note = "Edge $($b.Name): no install" }
  $Values += [pscustomobject]@{ Key = $PolicyKey; Name = "Update$($b.Id)";  Value = 0; Skip = $keepUpdates; Note = "Edge $($b.Name): no update" }
}
$Values += [pscustomobject]@{ Key = $PolicyKey; Name = "Install$WebView2"; Value = 1; Skip = $false; Note = 'WebView2: install allowed' }
$Values += [pscustomobject]@{ Key = $PolicyKey; Name = "Update$WebView2";  Value = 1; Skip = $false; Note = 'WebView2: update allowed' }
$Values += [pscustomobject]@{ Key = $PolicyKey; Name = 'CreateDesktopShortcutDefault'; Value = 0; Skip = $false; Note = 'No desktop shortcut' }
$Values += [pscustomobject]@{ Key = $UpdateKey; Name = 'DoNotUpdateToEdgeWithChromium'; Value = 1; Skip = $false; Note = 'Windows Update: do not deliver Edge' }

$svc = Get-Service -Name $Service -ErrorAction SilentlyContinue
$changeService = [bool]$svc -and -not $KeepService -and (-not $stableInstalled -or $BlockUpdatesToo)
$svcState = if ($changeService) { [ordered]@{ name = $Service; startType = "$($svc.StartType)" } } else { $null }

# 1. Save the old state once. A second run never overwrites the first backup.
if ((Test-Path $BackupDir) -and ((Get-Item -Path $BackupDir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
  Write-Error "$BackupDir is a link to another place. Nothing was changed."
  exit 1
}
if (-not (Test-Path $Backup)) {
  $state = [ordered]@{
    created = (Get-Date).ToString('s')
    keys    = @(@($PolicyKey, $UpdateKey) | ForEach-Object { [ordered]@{ key = $_; existed = [bool](Test-Path $_) } })
    values  = @($Values | ForEach-Object {
      $old = Get-Current $_.Key $_.Name
      [ordered]@{ key = $_.Key; name = $_.Name; existed = ($null -ne $old); old = $old; kind = (Get-Kind $_.Key $_.Name) }
    })
    service = $svcState
  }
  Step $Backup 'Save current values (backup for edge-unblock.ps1)' {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $Backup -Encoding UTF8
  }
} else {
  Write-Output "Backup already exists, keeping it: $Backup"
  $state = Get-Content -Path $Backup -Raw | ConvertFrom-Json
  if ($changeService -and -not $state.service) {
    # The first run used -KeepService. Remember the service now, or undo could not put it back.
    $state.service = $svcState
    Step $Backup 'Add the service startup type to the backup' {
      $state | ConvertTo-Json -Depth 5 | Set-Content -Path $Backup -Encoding UTF8
    }
  }
}

# 2. Policy values.
foreach ($v in $Values) {
  if ($v.Skip) { continue }
  $old = Get-Current $v.Key $v.Name
  $was = if ($null -eq $old) { 'not set' } else { "$old" }
  Step "$($v.Key)\$($v.Name)" "$($v.Note) (set $($v.Value), now: $was)" {
    if (-not (Test-Path $v.Key)) { New-Item -Path $v.Key -Force | Out-Null }
    New-ItemProperty -Path $v.Key -Name $v.Name -Value $v.Value -PropertyType DWord -Force | Out-Null
  }
}

# 3. The Edge helper service is not needed without Edge.
if ($changeService) {
  Step $Service "Set startup type to Disabled (now: $($svc.StartType))" {
    Set-Service -Name $Service -StartupType Disabled
  }
} elseif (-not $svc) {
  Write-Output "Service $Service not found, skipped."
} else {
  Write-Output "Service $Service left as it is."
}

if (-not $dry) {
  Write-Output ''
  Write-Output 'Done. Current values:'
  foreach ($v in $Values) { Write-Output ("  {0,-48} = {1}" -f $v.Name, (Get-Current $v.Key $v.Name)) }
  $svc = Get-Service -Name $Service -ErrorAction SilentlyContinue
  if ($svc) { Write-Output ("  {0,-48} = {1}" -f $Service, $svc.StartType) }
  Write-Output ''
  Write-Output "Backup of the old values: $Backup"
  Write-Output 'To undo: run edge-unblock.ps1 as administrator.'
}
