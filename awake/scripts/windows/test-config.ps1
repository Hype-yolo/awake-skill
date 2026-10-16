# No elevation, network calls, or machine configuration. Native Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\config.ps1"
function Assert($Value, [string]$Message) { if (!$Value) { throw "FAIL: $Message" } }
function Assert-Throws([scriptblock]$Operation, [string]$Message) {
    $failed = $false
    try { & $Operation | Out-Null } catch { $failed = $true }
    Assert $failed $Message
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('awake-config-test-' + [guid]::NewGuid())
$configPath = Join-Path $root 'preferences\config.json'
try {
    Assert ($null -eq (Read-AwakeConfig $configPath)) 'missing config'
    $Action = 'read'; $Path = $configPath
    Assert ((Invoke-AwakeConfigMain | ConvertFrom-Json).state -eq 'missing') 'missing CLI JSON'
    Save-AwakeConfig $configPath 'existing' '' | Out-Null
    $saved = Read-AwakeConfig $configPath
    Assert ($saved.network.mode -ceq 'existing' -and $null -eq $saved.network.ssid) 'existing mode persists'
    # Build Unicode at runtime so the test source itself works without a BOM on PS5.1.
    $ssid = ([string][char]0x624B) + [char]0x673A + ' $(whoami); '' " ` &'
    Save-AwakeConfig $configPath 'hotspot' $ssid | Out-Null
    Assert ((Read-AwakeConfig $configPath).network.ssid -ceq $ssid) 'Unicode and shell-like SSID is data'
    $before = [IO.File]::ReadAllText($configPath)
    foreach ($bad in @('', '   ', "bad`nname", "bad`rname", ("bad" + [char]0), ('a' * 33), ([string][char]0x624B * 11))) {
        Assert-Throws { Save-AwakeConfig $configPath 'hotspot' $bad } 'reject invalid SSID'
        Assert ([IO.File]::ReadAllText($configPath) -ceq $before) 'invalid input never clobbers file'
    }
    Assert-Throws { Save-AwakeConfig $configPath 'existing' 'unwanted' } 'reject SSID with existing mode'
    foreach ($broken in @('{broken', '{"version":2,"platform":"windows","network":{"mode":"existing","ssid":null}}', '{"version":1,"platform":"macos","network":{"mode":"existing","ssid":null}}', '{"version":1,"platform":"windows","network":{"mode":"existing","ssid":null},"password":"forbidden"}')) {
        [IO.File]::WriteAllText($configPath, $broken)
        Assert-Throws { Read-AwakeConfig $configPath } 'reject malformed or incompatible config'
        Assert-Throws { Save-AwakeConfig $configPath 'existing' '' } 'refuse overwriting broken config'
        Assert ([IO.File]::ReadAllText($configPath) -ceq $broken) 'broken config preserved for manual repair'
    }
    Assert (@(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($configPath)) -Filter '*.tmp' -Force).Count -eq 0) 'no temporary files remain'
    'PASS: per-user config persistence, Unicode, validation, and no-clobber tests.'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
