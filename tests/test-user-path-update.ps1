# Exercises the real CMD update wrapper against the disposable CI user's PATH.
# Unlike test-user-path.ps1, this fixture must never run in a developer's profile.
param([string]$PortableRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:USERNAME -ne 'noadmin') {
    throw 'This test requires the disposable noadmin account created by the GitHub Actions workflow.'
}

function Invoke-Wrapper([string]$Arguments, [string]$Log) {
    # Redirect in CMD so expected native stderr does not become a terminating
    # PowerShell error before the wrapper's exit code can be asserted.
    # CALL preserves the batch errorlevel when its top-level dispatch ends with
    # GOTO :EOF; a direct CMD /C invocation reports success instead.
    & $env:ComSpec /D /S /C ('"call "{0}\.portable\scoop.cmd" {1} >"{2}" 2>&1"' -f $fixture, $Arguments, $Log)
    return $LASTEXITCODE
}

function Assert-Update([string]$Name, [string]$Value, [string]$Mode = 'change', [int]$ScoopExit = 0) {
    $key.SetValue('Path', $Value, 'ExpandString')
    [IO.File]::WriteAllText("$fixture\.portable\environment.ps1", $helperSource)
    $env:TEMP = Join-Path $fixture $Name
    if ($Mode -ne 'capture-failure') { New-Item -ItemType Directory -Path $env:TEMP | Out-Null }
    $env:PORTABLE_PATH_MODE = $Mode
    $env:PORTABLE_PATH_EXIT = [string]$ScoopExit
    [IO.File]::Delete("$fixture\calls.txt")
    [IO.File]::Delete("$fixture\notifications.txt")
    $log = "$fixture\$Name.log"
    $expectedExit = if ($ScoopExit) { $ScoopExit } elseif ($Mode -in 'capture-failure', 'restore-failure') { 1 } else { 0 }
    $actualExit = Invoke-Wrapper 'update --all' $log
    $output = Get-Content -LiteralPath $log -Raw
    if ($actualExit -ne $expectedExit) {
        # Temporary files disappear with the CI runner, so include their diagnostics in the job log.
        Write-Host $output
        throw "Wrong exit code for ${Name}: expected $expectedExit, got $actualExit; see $log"
    }
    if ($Mode -eq 'capture-failure') {
        if (Test-Path -LiteralPath "$fixture\calls.txt") { throw 'Update ran after snapshot capture failed' }
        if ($output -notlike '*Could not save user PATH*') { throw 'Snapshot failure was not explained' }
    } else {
        if (-not (Test-Path -LiteralPath "$fixture\calls.txt")) { throw "The fixture update did not run: $Name" }
        $snapshots = @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'scoop-portable-path-*.json')
        if ($Mode -eq 'restore-failure') {
            if ($snapshots.Count -ne 1 -or $output -notlike '*Snapshot retained at*') {
                throw 'Failed restoration did not retain and identify its snapshot'
            }
            $saved = Get-Content -LiteralPath $snapshots[0].FullName -Raw -Encoding Unicode | ConvertFrom-Json
            if ($saved.value -cne $Value -or $saved.kind -ne 'ExpandString' -or -not $saved.exists) {
                throw 'Recovery snapshot lost the original PATH'
            }
            return
        }
        if ($snapshots.Count) { throw "Successful restoration retained a snapshot: $Name" }
    }
    if ($key.GetValueKind('Path') -ne 'ExpandString' -or
        -not [string]::Equals($key.GetValue('Path', $null, 'DoNotExpandEnvironmentNames'), $Value, 'Ordinal')) {
        throw "The update damaged the original PATH: $Name"
    }
    $notified = Test-Path -LiteralPath "$fixture\notifications.txt"
    if ($notified -ne ($Mode -notin 'unchanged', 'capture-failure')) { throw "Wrong notification behavior: $Name" }
    if ($Mode -eq 'notify-failure' -and $output -notlike '*could not notify*') { throw 'Notification failure was hidden' }
}

$fixture = Join-Path $env:TEMP ('scoop-portable-path-update-' + [guid]::NewGuid().ToString('N'))
$lib = "$fixture\apps\scoop\current\lib"
foreach ($directory in @($lib, "$fixture\.portable\scoop", "$fixture\.portable\active_versions", "$fixture\shims")) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
Copy-Item -LiteralPath "$PortableRoot\scoop-portable.cmd" -Destination "$fixture\.portable\scoop.cmd"
'{"last_update":"2099-01-01T00:00:00"}' | Set-Content -LiteralPath "$fixture\.portable\scoop\config.json"
'$configHome = $env:XDG_CONFIG_HOME' | Set-Content -LiteralPath "$lib\core.ps1"
@'
function create_startmenu_shortcuts($manifest, $dir, $global, $arch) {
}
function startmenu_shortcut([System.IO.FileInfo] $target, $shortcutName, $arguments, [System.IO.FileInfo]$icon, $global) {
}
'@ | Set-Content -LiteralPath "$lib\shortcuts.ps1"
@'
function Set-EnvVar {
}
function Publish-EnvVar {
    'called' | Add-Content -LiteralPath "$env:SCOOP\notifications.txt"
    if ($env:PORTABLE_PATH_MODE -eq 'notify-failure') { throw 'Injected notification failure' }
}
'@ | Set-Content -LiteralPath "$lib\system.ps1"
"function Invoke-HookScript {`r`n}" | Set-Content -LiteralPath "$lib\install.ps1"
@'
@echo off
if /I not "%~1"=="update" exit /B 0
powershell -noprofile -ex unrestricted -file "%~dp0..\update.ps1"
if errorlevel 1 exit /B 99
exit /B %PORTABLE_PATH_EXIT%
'@ | Set-Content -LiteralPath "$fixture\shims\scoop.cmd"
@'
$ErrorActionPreference = 'Stop'
'called' | Add-Content -LiteralPath "$env:SCOOP\calls.txt"
if ($env:PORTABLE_PATH_MODE -ne 'unchanged') {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try { $key.SetValue('Path', 'C:\changed-by-fixture', 'String') } finally { $key.Dispose() }
}
if ($env:PORTABLE_PATH_MODE -eq 'restore-failure') {
    # Fail at the helper boundary while leaving the recovery snapshot intact.
    # The isolated-key fixture separately exercises an actual denied registry write.
    "`r`nfunction Restore-ScoopPortableUserPath { throw 'Injected restoration failure' }" |
        Add-Content -LiteralPath "$env:SCOOP\.portable\environment.ps1"
}
'@ | Set-Content -LiteralPath "$fixture\update.ps1"

$originalScoop = $env:SCOOP
$originalTemp = $env:TEMP
$env:SCOOP = $fixture
$key = $null
try {
    if ((Invoke-Wrapper list "$fixture\setup.log") -ne 0) { throw 'Could not prepare the wrapper fixture' }
    $helperSource = Get-Content -LiteralPath "$fixture\.portable\environment.ps1" -Raw
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    $existed = $key.GetValueNames() -contains 'Path'
    $originalValue = $key.GetValue('Path', $null, 'DoNotExpandEnvironmentNames')
    $originalKind = if ($existed) { $key.GetValueKind('Path') } else { $null }
    try {
        # The first case must fail with the old wrapper specifically because setx
        # truncates the restored value. No new helper API is needed to reach it.
        Assert-Update 'setx-limit' ('C:\long;' * 200)
        Assert-Update 'cmd-limit' ('C:\long;' * 1200)
        Assert-Update 'literal-value' ('%USERPROFILE%\space & tools!^(x);C:\' + [char]0x4E2D)
        Assert-Update 'unchanged' 'C:\original' 'unchanged'
        Assert-Update 'update-failure' 'C:\original' 'change' 7
        Assert-Update 'capture-failure' 'C:\original' 'capture-failure'
        Assert-Update 'restore-failure' 'C:\original' 'restore-failure'
        Assert-Update 'both-fail' 'C:\original' 'restore-failure' 7
        Assert-Update 'notify-failure' 'C:\original' 'notify-failure'
        Write-Host 'User PATH update tests passed.'
    } finally {
        # Restore independently of the code under test, even on the expected red run.
        if ($existed) { $key.SetValue('Path', $originalValue, $originalKind) } else { $key.DeleteValue('Path', $false) }
    }
} finally {
    if ($key) { $key.Dispose() }
    $env:SCOOP = $originalScoop
    $env:TEMP = $originalTemp
}
