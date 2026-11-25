<#
  Tests for edge-blocker.  powershell -ExecutionPolicy Bypass -File tests\run.ps1

  Parts 1 to 3 change nothing on your PC:
    1. the scripts parse,
    2. static proof: every command that can change something sits inside a Step block,
       and Step never runs its block in a dry run,
    3. both scripts run against a pretend registry, service and file kept in memory.
  Part 4 (-RealMachine) runs them for real and compares the registry before and after.
  It only runs on a throwaway GitHub Actions machine.
#>
param([switch]$RealMachine)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scripts = @{ block = (Join-Path $root 'edge-block.ps1'); undo = (Join-Path $root 'edge-unblock.ps1') }
$script:fail = 0
$script:pass = 0
function Check([string]$name, [bool]$ok) {
  if ($ok) { $script:pass++; Write-Output "ok    $name" } else { $script:fail++; Write-Output "FAIL  $name" }
}

$Changing = 'New-Item', 'New-ItemProperty', 'Remove-Item', 'Remove-ItemProperty', 'Set-Content', 'Move-Item', 'Set-Service'
$Reading = 'Join-Path', 'New-Object', 'Test-Path', 'Get-ItemProperty', 'Get-Item', 'Get-Service', 'Get-Content', 'Get-Date',
           'ConvertTo-Json', 'ConvertFrom-Json', 'ForEach-Object', 'Where-Object', 'Select-Object', 'Out-Null',
           'Write-Output', 'Write-Error', 'Write-Warning', 'Write-Verbose'
$Own = 'Step', 'Test-Admin', 'Get-Current', 'Get-Kind', 'Test-Installed'
$Methods = 'GetCurrent', 'IsInRole', 'GetValueKind', 'ToString', 'ShouldProcess'

# ---- 1 and 2
foreach ($name in 'block', 'undo') {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($scripts[$name], [ref]$tokens, [ref]$errors)
  Check "$name parses" ($errors.Count -eq 0)
  $bad = @()
  foreach ($c in $ast.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true)) {
    $cmd = $c.GetCommandName()
    $inStep = $false
    for ($p = $c.Parent; $p; $p = $p.Parent) {
      if ($p -is [Management.Automation.Language.ScriptBlockExpressionAst] -and
          $p.Parent -is [Management.Automation.Language.CommandAst] -and $p.Parent.GetCommandName() -eq 'Step') { $inStep = $true }
    }
    if ($null -eq $cmd) {
      if ($c.Extent.Text -ne '& $Action') { $bad += "line $($c.Extent.StartLineNumber): $($c.Extent.Text)" }
    } elseif ($cmd -in $Changing) {
      if (-not $inStep) { $bad += "line $($c.Extent.StartLineNumber): $cmd outside Step" }
    } elseif ($cmd -notin $Reading -and $cmd -notin $Own) { $bad += "line $($c.Extent.StartLineNumber): unknown command $cmd" }
  }
  foreach ($m in $ast.FindAll({ $args[0] -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
    if ("$($m.Member)" -notin $Methods) { $bad += "line $($m.Extent.StartLineNumber): method $($m.Member)" }
  }
  foreach ($r in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FileRedirectionAst] }, $true)) { $bad += "redirect: $($r.Extent.Text)" }
  Check "$name changes things only inside Step: $($bad -join '; ')" ($bad.Count -eq 0)
  $step = $ast.Find({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Step' }, $true)
  $first = $step.Body.EndBlock.Statements[0].Extent.Text
  Check "$name Step leaves first in a dry run" ($first -match '^if \(\$dry\) \{ Write-Output .*; return \}$')
  Check "$name Step runs its action once, after that" (([regex]::Matches($step.Extent.Text, '& \$Action')).Count -eq 1)
}

# ---- 3. a pretend machine: these functions hide the real commands from the scripts
$script:reg = @{}; $script:file = @{}; $script:svcStart = 'Manual'; $script:svcExists = $true; $script:edge = $false
$P = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
$U = 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate'
function Test-Path($Path) {
  if ($Path -like '*msedge.exe') { return ($script:edge -and $Path -like '*\Edge\Application\*') }
  return ($script:reg.ContainsKey($Path) -or $script:file.ContainsKey($Path))
}
function Get-ItemProperty($Path, $Name, $ErrorAction) {
  if ($script:reg[$Path].ContainsKey($Name)) { [pscustomobject]@{ $Name = $script:reg[$Path][$Name].v } }
}
function Get-Item($Path, [switch]$Force) {
  if ($Path -notlike 'HKLM:*') { return [pscustomobject]@{ Attributes = [IO.FileAttributes]::Directory } }
  $vals = $script:reg[$Path]
  $o = [pscustomobject]@{ ValueCount = $vals.Count; SubKeyCount = 0; vals = $vals }
  $o | Add-Member -MemberType ScriptMethod -Name GetValueKind -Value { param($n) $this.vals[$n].k } -PassThru
}
function New-Item($Path, $ItemType, [switch]$Force) {
  if ($Path -like 'HKLM:*') { $script:reg[$Path] = @{} } else { $script:file[$Path] = '' }
}
function New-ItemProperty($Path, $Name, $Value, $PropertyType, [switch]$Force) { $script:reg[$Path][$Name] = @{ v = $Value; k = "$PropertyType" } }
function Remove-ItemProperty($Path, $Name) { $script:reg[$Path].Remove($Name) }
function Remove-Item($Path) { if ($script:reg[$Path].Count) { throw 'not empty' }; $script:reg.Remove($Path) }
function Get-Service($Name, $ErrorAction) { if ($script:svcExists) { [pscustomobject]@{ Name = $Name; StartType = $script:svcStart } } }
function Set-Service($Name, $StartupType) { if ($Name -ne 'MicrosoftEdgeElevationService') { throw "wrong service $Name" }; $script:svcStart = $StartupType }
function Set-Content([Parameter(ValueFromPipeline = $true)]$Value, $Path, $Encoding) { process { $script:file[$Path] = $Value } }
function Get-Content($Path, [switch]$Raw) { $script:file[$Path] }
function Move-Item($Path, $Destination) { $script:file[$Destination] = $script:file[$Path]; $script:file.Remove($Path) }

foreach ($c in $Changing + 'Test-Path', 'Get-ItemProperty', 'Get-Item', 'Get-Service', 'Get-Content') {
  if ((Get-Command $c).CommandType -ne 'Function') { throw "$c is not the pretend one. Stopping before anything runs." }
}

$code = @{}
foreach ($name in 'block', 'undo') {
  $text = [IO.File]::ReadAllText($scripts[$name])
  $new = [regex]::Replace($text, '(?s)function Test-Admin \{.*?\n\}', 'function Test-Admin { $true }')
  if ($new -eq $text) { throw 'could not replace the admin check' }
  $code[$name] = [scriptblock]::Create($new)
}
function Reset-Machine { $script:reg = @{}; $script:file = @{}; $script:svcStart = 'Manual'; $script:svcExists = $true; $script:edge = $false }
function Snap {
  $o = @("svc=$script:svcStart")
  foreach ($k in $script:reg.Keys) { $o += $k; foreach ($n in $script:reg[$k].Keys) { $o += "$k $n=$($script:reg[$k][$n].v)/$($script:reg[$k][$n].k)" } }
  ($o | Sort-Object) -join "`n"
}
function Files { (($script:file.Keys | Sort-Object) -join ',') }
$bk = Join-Path (Join-Path $env:ProgramData 'EdgeBlocker') 'backup.json'
$S = 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
$SU = 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'

foreach ($how in @{ WhatIf = $true }, @{ DryRun = $true }, @{ DryRun = $true; WhatIf = $false }) {
  foreach ($name in 'block', 'undo') {
    Reset-Machine
    $script:reg[$P] = @{ $S = @{ v = 0; k = 'DWord' } }
    $before = Snap
    $out = & $code[$name] @how
    $label = ($how.Keys | ForEach-Object { "-${_}:$($how[$_])" }) -join ' '
    Check "$name $label changes nothing" ((Snap) -eq $before -and -not (Files))
    Check "$name $label says so" (($out -join "`n") -match 'DRY RUN' -and ($out -join "`n") -match 'What if: ')
  }
}

Reset-Machine
$before = Snap
& $code.block | Out-Null
Check 'block sets 12 values' ($script:reg[$P].Count + $script:reg[$U].Count -eq 12)
Check 'block: Edge off, WebView2 on' ($script:reg[$P][$S].v -eq 0 -and $script:reg[$P]['Install{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'].v -eq 1)
Check 'block disables the service' ($script:svcStart -eq 'Disabled')
& $code.block | Out-Null
& $code.undo | Out-Null
Check 'block twice, undo once: back to the start' ((Snap) -eq $before)
Check 'the used backup is kept under another name' (-not $script:file.ContainsKey($bk) -and (Files) -match 'restored-')

Reset-Machine
$script:reg[$P] = @{ $S = @{ v = 5; k = 'DWord' }; 'SomethingElse' = @{ v = 9; k = 'DWord' }; $SU = @{ v = 'text'; k = 'String' } }
$script:svcStart = 'Automatic'
$before = Snap
& $code.block | Out-Null
& $code.undo | Out-Null
Check 'undo brings back old values, their types and the service' ((Snap) -eq $before)

Reset-Machine
$before = Snap
& $code.block -KeepService | Out-Null
Check '-KeepService leaves the service' ($script:svcStart -eq 'Manual')
& $code.block | Out-Null
& $code.undo | Out-Null
Check '-KeepService first, service later: undo still restores it' ((Snap) -eq $before)

Reset-Machine
$script:edge = $true
$out = (& $code.block) -join "`n"
Check 'installed Edge keeps its updates and its service' (-not $script:reg[$P].ContainsKey($SU) -and $script:svcStart -eq 'Manual' -and $out -match 'still installed')
& $code.block -BlockUpdatesToo | Out-Null
Check '-BlockUpdatesToo blocks them' ($script:reg[$P][$SU].v -eq 0 -and $script:svcStart -eq 'Disabled')

Reset-Machine
$script:reg['HKLM:\SOFTWARE\Evil'] = @{ Run = @{ v = 1; k = 'DWord' } }
$script:file[$bk] = '{"created":"x","keys":[{"key":"HKLM:\\SOFTWARE\\Evil","existed":false}],"values":[{"key":"HKLM:\\SOFTWARE\\Evil","name":"Run","existed":true,"old":666,"kind":"DWord"},{"key":"HKLM:\\SOFTWARE\\Evil2","name":"x","existed":true,"old":1}],"service":{"name":"WinDefend","startType":"Disabled"}}'
& $code.undo | Out-Null
Check 'a planted backup cannot touch other keys or services' ($script:reg['HKLM:\SOFTWARE\Evil']['Run'].v -eq 1 -and -not $script:reg.ContainsKey('HKLM:\SOFTWARE\Evil2'))

Reset-Machine
$script:svcExists = $false
& $code.block | Out-Null
& $code.undo | Out-Null
Check 'works without the service' ((Snap) -eq 'svc=Manual')

Reset-Machine
& $code.block | Out-Null
$script:file.Remove($bk)
& $code.undo | Out-Null
Check 'undo without a backup removes only our values' ($script:reg[$P].Count -eq 0 -and $script:reg[$U].Count -eq 0 -and $script:svcStart -eq 'Manual')

Get-ChildItem function: | Where-Object { $_.Name -in ($Changing + 'Test-Path', 'Get-ItemProperty', 'Get-Item', 'Get-Service', 'Get-Content') } |
  ForEach-Object { Microsoft.PowerShell.Management\Remove-Item "function:$($_.Name)" }

# ---- 4. the real thing, on a throwaway machine only
if ($RealMachine) {
  if ($env:GITHUB_ACTIONS -ne 'true') { throw '-RealMachine only runs on GitHub Actions.' }
  function Read-Real {
    $o = @()
    foreach ($k in $P, $U) {
      if (Test-Path $k) { $o += $k; $i = Get-Item $k; foreach ($n in $i.GetValueNames()) { $o += "$k $n=$($i.GetValue($n))" } }
    }
    $s = Get-Service MicrosoftEdgeElevationService -ErrorAction SilentlyContinue
    if ($s) { $o += "svc=$($s.StartType)" }
    ($o | Sort-Object) -join "`n"
  }
  $before = Read-Real
  foreach ($f in 'block', 'undo') { powershell -NoProfile -ExecutionPolicy Bypass -File $scripts[$f] -WhatIf | Out-Null }
  Check 'real: -WhatIf changes nothing' ((Read-Real) -eq $before -and -not (Test-Path $bk))
  powershell -NoProfile -ExecutionPolicy Bypass -File $scripts.block -BlockUpdatesToo
  Check 'real: block sets the value' ((Get-ItemProperty $P).$S -eq 0)
  powershell -NoProfile -ExecutionPolicy Bypass -File $scripts.undo
  Check 'real: undo is exact' ((Read-Real) -eq $before)
}

Write-Output ''
Write-Output "$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
