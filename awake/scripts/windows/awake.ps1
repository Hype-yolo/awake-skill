#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('start','status','stop','recover')][string]$Action = 'status',
    [ValidateRange(1,1440)][int]$Minutes = 60
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-PowerCfg([string[]]$Arguments) {
    $result = & "$env:SystemRoot\System32\powercfg.exe" @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "powercfg failed ($LASTEXITCODE): $($Arguments -join ' ') $result" }
    return ($result -join "`n")
}
function Get-ActiveScheme {
    $output = Invoke-PowerCfg @('/getactivescheme')
    $match = [regex]::Match($output, '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}')
    if (!$match.Success) { throw 'Cannot read active power scheme.' }
    return $match.Value.ToLowerInvariant()
}
function Get-AwakeSettings([string]$Scheme) {
    $results = @()
    foreach ($pair in @(@('SUB_BUTTONS','LIDACTION','5ca83367-6e45-459f-a27b-476b1d01c936'), @('SUB_SLEEP','STANDBYIDLE','29f6c1db-86da-48c5-9fdb-f2b67b1f44da'), @('SUB_SLEEP','HIBERNATEIDLE','9d7815a6-7ee4-497e-8888-515a05f02364'))) {
        $output = Invoke-PowerCfg @('/qh', $Scheme, $pair[0])
        # Query a complete subgroup, including hidden settings; isolate the target GUID block.
        $guidPattern = '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'
        $block = [regex]::Match($output, '(?is)' + [regex]::Escape($pair[2]) + '(.*?)(?=' + $guidPattern + '|$)')
        if (!$block.Success) { throw "Missing power setting $($pair[1])." }
        # Localized labels differ; the final two hex indexes within this block are AC/DC.
        $values = [regex]::Matches($block.Groups[1].Value, '0x[0-9a-fA-F]+')
        if ($values.Count -lt 2) { throw "Cannot read AC/DC indexes for $($pair[1])." }
        $ac = [Convert]::ToUInt32($values[$values.Count - 2].Value.Substring(2),16)
        $dc = [Convert]::ToUInt32($values[$values.Count - 1].Value.Substring(2),16)
        $results += [pscustomobject]@{ Setting=$pair[1]; AC=$ac; DC=$dc }
    }
    return $results
}
function Assert-AwakeSettings([string]$Scheme) {
    foreach ($setting in @(Get-AwakeSettings $Scheme)) {
        if ($setting.AC -ne 0 -or $setting.DC -ne 0) { throw "AC/DC verification failed for $($setting.Setting)." }
    }
}
function Get-BootId { return (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') }
function Set-RecoveryOwner([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Save-State($State) {
    $json = $State | ConvertTo-Json -Depth 5
    $temporary = "$script:StatePath.new"
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    Set-RecoveryOwner $temporary
    # Flush durable state before the power scheme can change.
    $stream = [IO.File]::Open($temporary, 'Open', 'ReadWrite', 'None')
    try { $stream.Flush($true) } finally { $stream.Dispose() }
    if (Test-Path -LiteralPath $script:StatePath) {
        # Preserve a real CLR null; PS 5.1 casts ordinary $null to an invalid empty backup path.
        [IO.File]::Replace($temporary, $script:StatePath, [System.Management.Automation.Language.NullString]::Value)
    } else { [IO.File]::Move($temporary, $script:StatePath) }
}
function Read-State {
    if (!(Test-Path -LiteralPath $script:StatePath)) { return $null }
    $s = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
    if ($s.Version -ne 1 -or $s.Original -notmatch '^[0-9a-f-]{36}$' -or $s.Temporary -notmatch '^[0-9a-f-]{36}$' -or $s.Original -eq $s.Temporary) { throw 'Invalid recovery state; manual inspection required.' }
    [void][guid]::Parse($s.Original); [void][guid]::Parse($s.Temporary)
    [void][datetime]::Parse($s.ExpiresUtc)
    return $s
}
function Restore-Awake($State) {
    # Original scheme was never edited. Always restore it, even after another plan was selected.
    [void](Invoke-PowerCfg @('/setactive', $State.Original))
    if ((Get-ActiveScheme) -ne $State.Original) { throw 'Original scheme could not be verified; recovery retained.' }
    $plans = Invoke-PowerCfg @('/list')
    if ($plans -match [regex]::Escape($State.Temporary)) { [void](Invoke-PowerCfg @('/delete', $State.Temporary)) }
    # Keep the task and state on any failure. A later watchdog invocation retries.
    Remove-Item -LiteralPath $script:StatePath -Force
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
}
function Test-RecoveryDue($State, [datetime]$Now, [string]$Boot) {
    return ($State.Phase -ne 'active' -or $Now.ToUniversalTime() -ge [datetime]::Parse($State.ExpiresUtc).ToUniversalTime() -or $State.Boot -ne $Boot)
}
function Install-RecoveryTask([datetime]$Expiry) {
    $worker = Join-Path $script:Root 'awake.ps1'
    if ([IO.Path]::GetFullPath($PSCommandPath) -ne $worker) { Copy-Item -LiteralPath $PSCommandPath -Destination $worker -Force }
    Set-RecoveryOwner $worker
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $taskAction = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$worker`" -Action recover"
    $exact = New-ScheduledTaskTrigger -Once -At $Expiry.ToLocalTime()
    $retry = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $boot = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $script:TaskName -Action $taskAction -Trigger @($exact,$retry,$boot) -Settings $settings -Principal $principal -Force | Out-Null
    $task = Get-ScheduledTask -TaskName $script:TaskName
    if ($task.State -eq 'Disabled') { throw 'Recovery task is disabled.' }
}
function Start-Awake([int]$Duration) {
    $existing = Read-State
    if ($existing) {
        if (Test-RecoveryDue $existing ([datetime]::UtcNow) (Get-BootId)) {
            Restore-Awake $existing
        } else {
            if ((Get-ActiveScheme) -ne $existing.Temporary) { throw 'Active plan changed externally. Run stop before starting again.' }
            Assert-AwakeSettings $existing.Temporary
            $newExpiry = [datetime]::UtcNow.AddMinutes($Duration)
            # If state persistence fails, the old deadline remains authoritative for minute recovery.
            Install-RecoveryTask $newExpiry
            $existing.ExpiresUtc = $newExpiry.ToString('o')
            Save-State $existing
            Write-Output "Session deadline replaced with $($existing.ExpiresUtc) (UTC)."
            return
        }
    }
    $original = Get-ActiveScheme
    $state = [pscustomobject]@{ Version=1; Original=$original; Temporary=([guid]::NewGuid().ToString()); ExpiresUtc=([datetime]::UtcNow.AddMinutes($Duration).ToString('o')); Boot=(Get-BootId); Phase='prepared' }
    # Registration precedes all power changes; state precedes duplication and activation.
    Install-RecoveryTask ([datetime]::Parse($state.ExpiresUtc))
    Save-State $state
    try {
        [void](Invoke-PowerCfg @('/duplicatescheme', $state.Original, $state.Temporary))
        [void](Invoke-PowerCfg @('/changename', $state.Temporary, 'Awake Skill (temporary)'))
        foreach ($mode in @('/setacvalueindex','/setdcvalueindex')) {
            [void](Invoke-PowerCfg @($mode, $state.Temporary, 'SUB_BUTTONS', 'LIDACTION', '0'))
            [void](Invoke-PowerCfg @($mode, $state.Temporary, 'SUB_SLEEP', 'STANDBYIDLE', '0'))
            [void](Invoke-PowerCfg @($mode, $state.Temporary, 'SUB_SLEEP', 'HIBERNATEIDLE', '0'))
        }
        [void](Invoke-PowerCfg @('/setactive', $state.Temporary))
        if ((Get-ActiveScheme) -ne $state.Temporary) { throw 'Temporary scheme did not become active.' }
        Assert-AwakeSettings $state.Temporary
        $state.Phase = 'active'
        Save-State $state
        Write-Output "Configured until $($state.ExpiresUtc) (UTC). Hardware lid behavior still requires a real test."
    } catch {
        $failure = $_
        try { Restore-Awake $state } catch { Write-Warning "Recovery still pending: $_. Run stop again; scheduled recovery remains installed." }
        throw $failure
    }
}
function Initialize-SecureRoot {
    # Program Files is protected from standard-user child creation. Do not execute SYSTEM code from a user-writable checkout.
    $script:Root = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'AwakeSkillRecovery'
    $allowed = @('S-1-5-18','S-1-5-32-544')
    if (!(Test-Path -LiteralPath $script:Root)) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true,$false)
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        foreach ($sid in $allowed) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
            [void]$acl.AddAccessRule($rule)
        }
        [void][IO.Directory]::CreateDirectory($script:Root,$acl)
    }
    foreach ($item in @((Get-Item -LiteralPath $script:Root -Force)) + @(Get-ChildItem -LiteralPath $script:Root -Force -Recurse)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Recovery directory must not contain reparse points.' }
        $acl = Get-Acl -LiteralPath $item.FullName
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $allowed) { throw 'Unsafe recovery directory owner.' }
        foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed) { throw 'Recovery files must be accessible only to Administrators and SYSTEM.' }
        }
    }
    $script:StatePath = Join-Path $script:Root 'state.json'
    $script:TaskName = 'AwakeSkill-Recover-v1'
}
function Invoke-AwakeMain {
    if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use native Windows PowerShell 5.1 (powershell.exe) on Windows 10/11.' }
    if ([Environment]::Is64BitOperatingSystem -and ![Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell; 32-bit processes are unsupported on 64-bit Windows.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run Windows PowerShell as Administrator.' }
    Initialize-SecureRoot
    $lock = $null
    try {
        $lockPath = Join-Path $script:Root 'session.lock'
        if (!(Test-Path -LiteralPath $lockPath)) { [IO.File]::WriteAllText($lockPath, '') }
        Set-RecoveryOwner $lockPath
        $lock = [IO.File]::Open($lockPath, 'Open', 'ReadWrite', 'None')
        $state = Read-State
        switch ($Action) {
            'start' { Start-Awake $Minutes }
            'stop' { if ($state) { Restore-Awake $state; 'Original power scheme restored.' } else { 'No active session.' } }
            'recover' { if ($state -and (Test-RecoveryDue $state ([datetime]::UtcNow) (Get-BootId))) { Restore-Awake $state } }
            'status' {
                if (!$state) { 'No active session.'; break }
                [pscustomobject]@{ Phase=$state.Phase; ExpiresUtc=$state.ExpiresUtc; OriginalScheme=$state.Original; TemporaryScheme=$state.Temporary; ActiveScheme=(Get-ActiveScheme); Settings=@(Get-AwakeSettings $state.Temporary); RecoveryTask=(Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty State) } | ConvertTo-Json
            }
        }
    } finally { if ($lock) { $lock.Dispose() } }
}
# Dot-source imports functions only, for tests which mock every external mutation.
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-AwakeMain } catch { Write-Error $_ -ErrorAction Continue; exit 1 }
}
