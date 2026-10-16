# Offline tests: dot-source functions; mock ALL power/task operations. No elevation needed.
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-awake.ps1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\awake.ps1"
function Assert($Value, [string]$Message) { if (!$Value) { throw "FAIL: $Message" } }
$script:Root = Join-Path ([IO.Path]::GetTempPath()) ('awake-test-' + [guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $script:Root)
$script:StatePath = Join-Path $script:Root 'state.json'
$script:TaskName = 'MOCK-ONLY'
$script:Original = '11111111-1111-1111-1111-111111111111'
$script:Active = $script:Original
$script:Plans = @($script:Original)
$script:Calls = @()
$script:FailCommand = ''
function Set-RecoveryOwner([string]$Path) {}
function Get-BootId { 'boot-1' }
function Install-RecoveryTask([datetime]$Expiry) { $script:Calls += 'task' }
function Unregister-ScheduledTask { param($TaskName,$Confirm,$ErrorAction) $script:Calls += 'unregister' }
function Invoke-PowerCfg([string[]]$Arguments) {
    $script:Calls += ($Arguments -join ' ')
    if ($Arguments[0] -eq $script:FailCommand) { throw 'Injected powercfg failure' }
    switch ($Arguments[0]) {
        '/getactivescheme' { return "Power Scheme GUID: $script:Active" }
        '/qh' { return @'
Power Setting GUID: 5ca83367-6e45-459f-a27b-476b1d01c936
Option: 0x00000001 Option: 0x00000002 AC: 0x00000000 DC: 0x00000000
Power Setting GUID: 29f6c1db-86da-48c5-9fdb-f2b67b1f44da
Min: 0x00000000 Max: 0xffffffff Step: 0x00000001 AC: 0x00000000 DC: 0x00000000
Power Setting GUID: 9d7815a6-7ee4-497e-8888-515a05f02364
Min: 0x00000000 Max: 0xffffffff AC: 0x00000000 DC: 0x00000000
'@ }
        '/list' { return ($script:Plans -join "`n") }
        '/duplicatescheme' {
            Assert (Test-Path $script:StatePath) 'persist state before duplication'
            Assert ($script:Calls[1] -eq 'task') 'install recovery before duplication'
            $script:Plans += $Arguments[2]
        }
        '/setactive' { $script:Active = $Arguments[1] }
        '/delete' { $script:Plans = @($script:Plans | Where-Object { $_ -ne $Arguments[1] }) }
    }
    return ''
}
try {
    Start-Awake 60
    $s = Read-State
    Assert ($s.Phase -eq 'active') 'active state persisted'
    Assert ($script:Active -eq $s.Temporary) 'temporary plan selected'
    Assert (@($script:Calls | Where-Object { $_ -like '/set*valueindex *' }).Count -eq 6) 'AC and DC settings applied'
    Assert (!(Test-RecoveryDue $s ([datetime]::UtcNow) 'boot-1')) 'not due early'
    Assert (Test-RecoveryDue $s ([datetime]::UtcNow.AddHours(2)) 'boot-1') 'due at expiry'
    Assert (Test-RecoveryDue $s ([datetime]::UtcNow) 'boot-2') 'recover on reboot'
    $s.Phase = 'prepared'
    Assert (Test-RecoveryDue $s ([datetime]::UtcNow) 'boot-1') 'recover interrupted preparation'
    Start-Awake 120
    $extended = Read-State
    Assert ($extended.Original -eq $s.Original -and $extended.Temporary -eq $s.Temporary) 'extension preserves plans'
    Assert ([datetime]::Parse($extended.ExpiresUtc) -gt [datetime]::Parse($s.ExpiresUtc)) 'extension replaces deadline'
    $s = $extended
    $script:FailCommand = '/setactive'
    try { Restore-Awake $s } catch {}
    Assert (Test-Path $script:StatePath) 'retain state when restoration fails'
    $script:FailCommand = ''
    Restore-Awake $s
    Assert ($script:Active -eq $script:Original) 'restore original scheme'
    Assert (!(Test-Path $script:StatePath)) 'remove state after recovery'
    Assert ($script:Plans.Count -eq 1) 'delete only temporary scheme'
    $script:Calls = @()
    $script:FailCommand = '/setdcvalueindex'
    $rejected = $false
    try { Start-Awake 60 } catch { $rejected = $true }
    Assert $rejected 'surface setup failure'
    Assert ($script:Active -eq $script:Original) 'rollback failed setup'
    Assert (!(Test-Path $script:StatePath)) 'rollback clears state only after restoration'
    'PASS: mocked Windows lifecycle, expiry, reboot, extension, durable preparation, rollback and retry.'
} finally { Remove-Item -LiteralPath $script:Root -Recurse -Force }
