# Per-user preferences only. Run without elevation under the intended user's account.
[CmdletBinding()]
param(
    [ValidateSet('read','save')][string]$Action = 'read',
    [ValidateSet('existing','hotspot')][string]$Mode,
    [string]$Ssid,
    [string]$Path = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AwakeSkill\config.json')
)
$ErrorActionPreference = 'Stop'

function Assert-AwakeConfigKeys($Object, [string[]]$Keys) {
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { throw 'Invalid config object.' }
    $actual = @($Object.PSObject.Properties.Name)
    if ($actual.Count -ne $Keys.Count) { throw 'Unexpected config fields.' }
    foreach ($key in $Keys) { if ($actual -cnotcontains $key) { throw "Missing config field: $key" } }
}
function Assert-AwakeConfig($Config) {
    Assert-AwakeConfigKeys $Config @('version','platform','network')
    if (($Config.version -isnot [int] -and $Config.version -isnot [long]) -or $Config.version -ne 1) { throw 'Unsupported config version.' }
    if ($Config.platform -cne 'windows') { throw 'Config belongs to a different platform.' }
    Assert-AwakeConfigKeys $Config.network @('mode','ssid')
    if ($Config.network.mode -ceq 'existing') {
        if ($null -ne $Config.network.ssid) { throw 'Existing-network mode requires a null SSID.' }
    } elseif ($Config.network.mode -ceq 'hotspot') {
        $name = $Config.network.ssid
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or $name.IndexOfAny([char[]]@(0,10,13)) -ge 0) { throw 'Invalid hotspot SSID.' }
        $encoding = [Text.UTF8Encoding]::new($false, $true)
        if ($encoding.GetByteCount($name) -gt 32) { throw 'Hotspot SSID exceeds 32 UTF-8 bytes.' }
    } else { throw 'Unsupported network mode.' }
}
function Read-AwakeConfig([string]$ConfigPath) {
    if (![IO.File]::Exists($ConfigPath)) {
        if (Test-Path -LiteralPath $ConfigPath) { throw 'Config path is not a file.' }
        return $null
    }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $config = [IO.File]::ReadAllText($ConfigPath, $encoding) | ConvertFrom-Json
    Assert-AwakeConfig $config
    return $config
}
function Save-AwakeConfig([string]$ConfigPath, [string]$NetworkMode, [string]$NetworkSsid) {
    if ($NetworkMode -ceq 'existing' -and ![string]::IsNullOrEmpty($NetworkSsid)) { throw 'Do not supply an SSID with existing-network mode.' }
    $config = [pscustomobject]@{ version=1; platform='windows'; network=[pscustomobject]@{ mode=$NetworkMode; ssid=$null } }
    if ($NetworkMode -ceq 'hotspot') { $config.network.ssid = $NetworkSsid }
    Assert-AwakeConfig $config
    $fullPath = [IO.Path]::GetFullPath($ConfigPath)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    [void][IO.Directory]::CreateDirectory($directory)
    # Serialize cooperating writers; never replace a malformed or incompatible file.
    $lock = [IO.File]::Open(($fullPath + '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $temporary = Join-Path $directory ('.config-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $previous = Read-AwakeConfig $fullPath
        [IO.File]::WriteAllText($temporary, ($config | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false, $true))
        if ($null -ne $previous) {
            [IO.File]::Replace($temporary, $fullPath, [System.Management.Automation.Language.NullString]::Value)
        } else { [IO.File]::Move($temporary, $fullPath) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        $lock.Dispose()
    }
    return $config
}
function Invoke-AwakeConfigMain {
    if ($Action -eq 'save') {
        if ([string]::IsNullOrEmpty($Mode)) { throw 'save requires -Mode existing or hotspot.' }
        Save-AwakeConfig $Path $Mode $Ssid | ConvertTo-Json -Depth 4
    } else {
        $config = Read-AwakeConfig $Path
        if ($null -eq $config) { '{"state":"missing"}' }
        else { $config | ConvertTo-Json -Depth 4 }
    }
}
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-AwakeConfigMain } catch { Write-Error $_ -ErrorAction Continue; exit 1 }
}
