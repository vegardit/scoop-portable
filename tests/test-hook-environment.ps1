# CI regression fixture for portable hook settings, shared search paths and dotted app names.
# Uses Scoop's real helper bodies with a registry writer that always fails, so
# a missing patch cannot modify the user's environment during this test.
param([Parameter(Mandatory = $true)][string]$PortableRoot)

$ErrorActionPreference = 'Stop'

function Read-ScoopFunction([string]$Library, [string]$Name) {
    $tokens = $null
    $parseErrors = $null
    $source = Join-Path $PortableRoot "apps\scoop\current\lib\$Library.ps1"
    $tree = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw "Cannot read Scoop fixture source: $source" }
    # Take the upstream definition, before any override appended by the wrapper.
    $definition = $tree.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $false) | Select-Object -First 1
    if (-not $definition) { throw "Missing Scoop fixture function: $Name" }
    $definition.Extent.Text
}

function Invoke-Wrapper([string]$Arguments) {
    & $env:ComSpec /D /S /C ('""{0}\.portable\scoop.cmd" {1}"' -f $fixtureRoot, $Arguments) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Portable wrapper failed: $Arguments" }
}

function Read-Session([switch]$EmptySearchPaths) {
    # Every probe starts without effects inherited from the hook process, including
    # after reinstalls. Keep system paths needed to execute CMD and PowerShell.
    $env:PATH = ($env:PATH -split ';' | Where-Object { -not $_.StartsWith($fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase) }) -join ';'
    $mode = if ($EmptySearchPaths) { 'empty' } else { 'inherited' }
    $json = & $env:ComSpec /D /S /C ('""{0}\read-session.cmd" {1}"' -f $fixtureRoot, $mode)
    if ($LASTEXITCODE -ne 0) { throw 'Could not load the fixture session' }
    ($json -join [Environment]::NewLine) | ConvertFrom-Json
}

function Assert-Value($Actual, $Expected, [string]$Description) {
    if ($Actual -cne $Expected) { throw "Unexpected value: $Description" }
}

function Assert-Path($Session, [string]$Path, [int]$Count = 1) {
    if (@($Session.path -split ';' | Where-Object { $_ -eq $Path }).Count -ne $Count) {
        throw "Unexpected PATH occurrence count: $Path"
    }
}

function Invoke-InstallHooks([string]$Name, $Manifest) {
    # These variables are supplied by install_app to Invoke-HookScript in Scoop.
    $app = $Name
    $global = $false
    $dir = $original_dir = Join-Path $fixtureRoot "apps\$Name\1"
    $persist_dir = Join-Path $fixtureRoot "persist\$Name"
    $Manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$dir\manifest.json"
    Invoke-HookScript -HookType pre_install -Manifest $Manifest -Arch 64bit
    Invoke-HookScript -HookType installer -Manifest $Manifest -Arch 64bit
    # Scoop switches to the junction before applying declarations and post_install.
    $dir = Join-Path $fixtureRoot "apps\$Name\current"
    $scoopPathEnvVar = 'PATH'
    env_add_path $Manifest $dir $false 64bit
    env_set $Manifest $false 64bit
    Invoke-HookScript -HookType post_install -Manifest $Manifest -Arch 64bit
}

try {
    # Like the batch fixtures, keep a unique directory for diagnosis rather than
    # recursively deleting a path assembled from environment variables.
    $fixtureRoot = Join-Path $env:TEMP ('scoop-portable-hook-test-' + [guid]::NewGuid().ToString('N'))
    $lib = Join-Path $fixtureRoot 'apps\scoop\current\lib'
    $versions = Join-Path $fixtureRoot '.portable\active_versions'
    foreach ($directory in @($lib, $versions, "$fixtureRoot\.portable\scoop", "$fixtureRoot\shims")) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    foreach ($name in 'hooks.10', 'hook-only', 'tool.10.3', 'write-failure', 'shared-a', 'shared-b') {
        New-Item -ItemType Directory -Path "$fixtureRoot\apps\$name\1" -Force | Out-Null
        New-Item -ItemType Junction -Path "$fixtureRoot\apps\$name\current" -Target "$fixtureRoot\apps\$name\1" | Out-Null
    }
    # Exercise the distribution source even if the installed wrapper has not been refreshed yet.
    Copy-Item -LiteralPath "$PortableRoot\scoop-portable.cmd" -Destination "$fixtureRoot\.portable\scoop.cmd"
    Copy-Item -LiteralPath "$PortableRoot\scoop-portable.cmd" -Destination "$fixtureRoot\scoop-portable.cmd"
    '@exit /B 0' | Set-Content -LiteralPath "$fixtureRoot\shims\scoop.cmd"
    '{"last_update":"2099-01-01T00:00:00"}' | Set-Content -LiteralPath "$fixtureRoot\.portable\scoop\config.json"
    "$env:USERDOMAIN\$env:USERNAME" | Set-Content -LiteralPath "$fixtureRoot\.portable\last.user"
    '$configHome = $env:XDG_CONFIG_HOME' | Set-Content -LiteralPath "$lib\core.ps1"
    @'
function create_startmenu_shortcuts($manifest, $dir, $global, $arch) {
}
function startmenu_shortcut([System.IO.FileInfo] $target, $shortcutName, $arguments, [System.IO.FileInfo]$icon, $global) {
}
'@ | Set-Content -LiteralPath "$lib\shortcuts.ps1"
    $system = @'
function Get-EnvVar {
    param([string]$Name, [switch]$Global)
    if ($Name -eq 'PATH') { return 'C:\registry-only' }
}
function Set-EnvVar {
    param([string]$Name, [string]$Value, [switch]$Global)
    throw 'The fixture must never call the registry writer'
}
function friendly_path($Path) { $Path }
function get_config($Name) { $false }
'@
    foreach ($name in 'Split-PathLikeEnvVar', 'Add-Path', 'Remove-Path') {
        $system += [Environment]::NewLine + (Read-ScoopFunction system $name)
    }
    $system | Set-Content -LiteralPath "$lib\system.ps1"
    @(
        Read-ScoopFunction manifest arch_specific
        Read-ScoopFunction core Get-AbsolutePath
        Read-ScoopFunction install is_in_dir
        Read-ScoopFunction install env_add_path
        Read-ScoopFunction install env_set
        Read-ScoopFunction install Invoke-HookScript
    ) -join [Environment]::NewLine | Set-Content -LiteralPath "$lib\install.ps1"
    $env:SCOOP = $fixtureRoot
    Invoke-Wrapper list
    . "$lib\system.ps1"
    . "$lib\install.ps1"
    # Commands can source install.ps1 again in one process. The hook wrapper must
    # still delegate to upstream rather than capturing itself and recursing.
    . "$lib\install.ps1"

    $manifest = @'
{
    "version": "1",
    "pre_install": [
        "Set-EnvVar PORTABLE_TEST_DECLARED pre",
        "Add-Path -Path \"$persist_dir\\old\" -Force",
        "Add-Path -Path \"$persist_dir\\bin\" -Force"
    ],
    "installer": {"script": [
        "if ((Get-EnvVar PORTABLE_TEST_DECLARED) -ne 'pre') { throw 'pre_install setting was lost' }",
        "Add-Path -Path \"$persist_dir\\tools\" -Force",
        "Remove-Path -Path \"$persist_dir\\old\"",
        "Set-EnvVar PORTABLE_TEST_HOOK \"$dir\\.gradle\"",
        "$env:PORTABLE_TEST_HOOK = \"$dir\\.gradle\""
    ]},
    "env_set": {
        "PORTABLE_TEST_DECLARED": "manifest",
        "PORTABLE_TEST_AFTER": "manifest"
    },
    "env_add_path": ["declared", "discard-a", "discard-b"],
    "post_install": [
        "if ((Get-EnvVar PORTABLE_TEST_DECLARED) -ne 'manifest') { throw 'declaration must replace the pre_install setting' }",
        "Remove-Path -Path \"$dir\\discard-a;$dir\\discard-b\"",
        "Set-EnvVar PATH (\"$persist_dir\\direct;\" + (Get-EnvVar PATH))",
        "Add-Path -Path @(\"$persist_dir\\first\", \"$persist_dir\\second\") -Force",
        "if ((Get-EnvVar PATH) -notlike \"*$persist_dir\\direct*\") { throw 'direct PATH assignment was lost' }",
        "Set-EnvVar PORTABLE_TEST_AFTER post",
        "if ((Get-EnvVar PORTABLE_TEST_AFTER) -ne 'post') { throw 'post_install setting was lost' }",
        "Set-EnvVar PORTABLE_TEST_TEXT 'space & more'",
        "Set-EnvVar PORTABLE_TEST_EMPTY ''"
    ]
}
'@ | ConvertFrom-Json
    Invoke-InstallHooks hooks.10 $manifest
    $env:PORTABLE_TEST_INPUT = ''
    $hookOnly = '{"version":"1","post_install":"Set-EnvVar PORTABLE_TEST_ONLY \"$dir\\cache$env:PORTABLE_TEST_INPUT\""}' | ConvertFrom-Json
    Invoke-InstallHooks hook-only $hookOnly
    '{"version":"1","env_add_path":"bin"}' | Set-Content -LiteralPath "$fixtureRoot\apps\tool.10.3\current\manifest.json"
    Invoke-Wrapper 'reset hooks.10 hook-only tool.10.3'

    # Clear the child process effects and load twice in a new CMD. Assertions must
    # be satisfied by saved state, not by values inherited from the hook execution.
    @'
@echo off
set "PORTABLE_TEST_HOOK="
set "PORTABLE_TEST_ONLY="
set "PORTABLE_TEST_DECLARED="
set "PORTABLE_TEST_AFTER="
set "PORTABLE_TEST_TEXT="
set "PORTABLE_TEST_EMPTY=stale"
set "PORTABLE_TEST_SCALAR="
set "PKG_CONFIG_PATH=C:\caller-pkg"
set "CMAKE_PREFIX_PATH=C:\caller-cmake"
if "%~1" == "empty" (
  set "PKG_CONFIG_PATH="
  set "CMAKE_PREFIX_PATH="
)
call "%~dp0scoop-portable.cmd" >NUL
if errorlevel 1 exit /B 1
call "%~dp0scoop-portable.cmd" >NUL
if errorlevel 1 exit /B 1
powershell -noprofile -file "%~dp0read-session.ps1"
'@ | Set-Content -LiteralPath "$fixtureRoot\read-session.cmd"
    @'
@{
    hook = $env:PORTABLE_TEST_HOOK
    only = $env:PORTABLE_TEST_ONLY
    declared = $env:PORTABLE_TEST_DECLARED
    after = $env:PORTABLE_TEST_AFTER
    text = $env:PORTABLE_TEST_TEXT
    empty = $env:PORTABLE_TEST_EMPTY
    scalar = $env:PORTABLE_TEST_SCALAR
    pkg = $env:PKG_CONFIG_PATH
    cmake = $env:CMAKE_PREFIX_PATH
    path = $env:PATH
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath "$fixtureRoot\read-session.ps1"
    $session = Read-Session
    Assert-Value $session.hook "$fixtureRoot\apps\hooks.10\current\.gradle" 'hook variable'
    Assert-Value $session.only "$fixtureRoot\apps\hook-only\current\cache" 'hook without declarative environment properties'
    Assert-Value $session.declared 'manifest' 'declarative settings follow installer hooks'
    Assert-Value $session.after 'post' 'post_install follows declarative settings'
    Assert-Value $session.text 'space & more' 'literal hook value'
    Assert-Value $session.empty $null 'hook removes a value'
    Assert-Path $session "$fixtureRoot\persist\hooks.10\bin"
    Assert-Path $session "$fixtureRoot\persist\hooks.10\tools"
    Assert-Path $session "$fixtureRoot\persist\hooks.10\old" 0
    Assert-Path $session "$fixtureRoot\apps\hooks.10\current\discard-a" 0
    Assert-Path $session "$fixtureRoot\apps\hooks.10\current\discard-b" 0
    $appPaths = @($session.path -split ';' | Where-Object { $_ -like "$fixtureRoot\*\hooks.10\*" })
    Assert-Value ($appPaths -join ';') ("$fixtureRoot\persist\hooks.10\first;$fixtureRoot\persist\hooks.10\second;" +
        "$fixtureRoot\persist\hooks.10\direct;" +
        "$fixtureRoot\apps\hooks.10\current\declared;$fixtureRoot\persist\hooks.10\tools;$fixtureRoot\persist\hooks.10\bin") 'hook PATH order'
    Assert-Path $session 'C:\registry-only' 0
    Assert-Path $session "$fixtureRoot\apps\tool.10.3\current\bin"
    Assert-Path $session "$fixtureRoot\apps\tool\current\bin" 0

    # A forced bulk update can change evaluated hook values while the manifest
    # bytes stay the same. The wrapper must compare captured state as well.
    $env:PORTABLE_TEST_INPUT = '\refreshed'
    Invoke-InstallHooks hook-only $hookOnly
    Invoke-Wrapper 'update --all'
    $session = Read-Session
    Assert-Value $session.only "$fixtureRoot\apps\hook-only\current\cache\refreshed" 'updated hook value with an unchanged manifest'

    # Saved values must follow the installation root after relocation, including
    # paths outside apps\<name>\current. Cover a different drive and a root that
    # contains the new one, where two successive replacements would duplicate it.
    $record = "$fixtureRoot\apps\hooks.10\current\.scoop-portable-env.json"
    $originalRecord = Get-Content -LiteralPath $record -Raw
    $escapedRoot = ($fixtureRoot | ConvertTo-Json -Compress).Trim('"')
    foreach ($previousRoot in 'Z:\previous-scoop', (Split-Path $fixtureRoot -Parent)) {
        $escapedPreviousRoot = ($previousRoot | ConvertTo-Json -Compress).Trim('"')
        $originalRecord.Replace($escapedRoot, $escapedPreviousRoot) | Set-Content -LiteralPath $record
        Invoke-Wrapper 'reset hooks.10'
        $session = Read-Session
        Assert-Value $session.hook "$fixtureRoot\apps\hooks.10\current\.gradle" 'relocated hook variable'
        Assert-Path $session "$fixtureRoot\persist\hooks.10\bin"
    }

    # A reinstall without these hooks must not retain the previous version's state.
    $replacement = '{"version":"2","env_set":{"PORTABLE_TEST_AFTER":"replacement"}}' | ConvertFrom-Json
    Invoke-InstallHooks hooks.10 $replacement
    Invoke-Wrapper 'reset hooks.10'
    $session = Read-Session
    Assert-Value $session.hook $null 'removed hook variable'
    Assert-Value $session.after 'replacement' 'replacement manifest'
    Assert-Path $session "$fixtureRoot\persist\hooks.10\bin" 0
    Assert-Path $session "$fixtureRoot\persist\hooks.10\tools" 0

    # Each installation runs in a fresh process and loads the previously saved session.
    # This reproduces libsndfile/raylib's read-modify-write hooks without registry access
    # or inherited hook effects concealing a broken capture/replay implementation.
    @'
param([string]$AppName)
$ErrorActionPreference = 'Stop'
$fixtureRoot = $env:SCOOP
. "$fixtureRoot\apps\scoop\current\lib\system.ps1"
. "$fixtureRoot\apps\scoop\current\lib\install.ps1"
'@ + "`r`nfunction Invoke-InstallHooks {`r`n" + ${function:Invoke-InstallHooks}.ToString() + "`r`n}`r`n" + @'
$manifest = Get-Content -LiteralPath "$fixtureRoot\apps\$AppName\current\manifest.json" -Raw | ConvertFrom-Json
Invoke-InstallHooks $AppName $manifest
'@ | Set-Content -LiteralPath "$fixtureRoot\install-shared.ps1"
    @'
@echo off
set "PKG_CONFIG_PATH=C:\caller-pkg"
set "CMAKE_PREFIX_PATH=C:\caller-cmake"
call "%~dp0scoop-portable.cmd" >NUL
if errorlevel 1 exit /B 1
powershell -noprofile -ex unrestricted -file "%~dp0install-shared.ps1" "%~1"
if errorlevel 1 exit /B 1
call "%~dp0.portable\scoop.cmd" reset "%~1" >NUL
exit /B %errorlevel%
'@ | Set-Content -LiteralPath "$fixtureRoot\install-shared.cmd"
    $shared = @'
{
    "version": "1",
    "post_install": [
        "foreach ($name in 'PKG_CONFIG_PATH', 'CMAKE_PREFIX_PATH') {",
        "    $own = \"$dir\\$name\"",
        "    $null, $tail = Split-PathLikeEnvVar -Pattern $own -Path (Get-EnvVar $name)",
        "    Set-EnvVar $name \"$own;$tail\"",
        "    [Environment]::SetEnvironmentVariable($name, \"$own;$tail\", 'Process')",
        "}",
        "Set-EnvVar PORTABLE_TEST_SCALAR 'C:\\one;C:\\two'"
    ]
}
'@
    foreach ($order in @(@('shared-a', 'shared-b'), @('shared-b', 'shared-a'))) {
        foreach ($name in $order) {
            $shared | Set-Content -LiteralPath "$fixtureRoot\apps\$name\current\manifest.json"
            & $env:ComSpec /D /S /C ('""{0}\install-shared.cmd" {1}"' -f $fixtureRoot, $name) | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Shared-path installation failed: $name" }
        }
        # Reinstall with the app's own paths already inherited from the saved session.
        & $env:ComSpec /D /S /C ('""{0}\install-shared.cmd" {1}"' -f $fixtureRoot, $order[0]) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Shared-path reinstall failed' }
        # The installer's caller must not be frozen into the record. A fresh session
        # with no inherited list must contain only the two apps, still exactly once.
        foreach ($empty in $false, $true) {
            $session = Read-Session -EmptySearchPaths:$empty
            foreach ($setting in @(@('pkg', 'PKG_CONFIG_PATH', 'C:\caller-pkg'), @('cmake', 'CMAKE_PREFIX_PATH', 'C:\caller-cmake'))) {
                $actual = @($session.($setting[0]) -split ';' | Where-Object { $_ } | Sort-Object)
                $expected = @("$fixtureRoot\apps\shared-a\current\$($setting[1])",
                    "$fixtureRoot\apps\shared-b\current\$($setting[1])")
                if (-not $empty) { $expected += $setting[2] }
                Assert-Value ($actual -join ';') (($expected | Sort-Object) -join ';') 'shared paths after repeated session loading'
            }
            Assert-Value $session.scalar 'C:\one;C:\two' 'semicolon-containing scalar remains an assignment'
        }

        # Removing one app's hooks must not leave its paths inside the other app's record.
        foreach ($name in $order) {
            Invoke-InstallHooks $name ('{"version":"2"}' | ConvertFrom-Json)
            Invoke-Wrapper "reset $name"
            $session = Read-Session
            if (($session.pkg -split ';') -contains "$fixtureRoot\apps\$name\current\PKG_CONFIG_PATH") {
                throw "Removed hook path was retained by another app: $name"
            }
        }
        Assert-Value $session.pkg 'C:\caller-pkg' 'caller setting after both hooks are removed'
        Assert-Value $session.cmake 'C:\caller-cmake' 'caller CMake setting after both hooks are removed'
    }

    # A blocked output must fail capture rather than claim an app has portable settings.
    $blocked = "$fixtureRoot\apps\write-failure\current\.scoop-portable-env.json.tmp"
    New-Item -ItemType Directory -Path $blocked | Out-Null
    $failed = $false
    try { Invoke-InstallHooks write-failure $hookOnly } catch {
        if ($_.Exception.Message -notlike '*could not save hook settings*') { throw }
        $failed = $true
    }
    if (-not $failed) { throw 'A hook-state write failure was ignored' }
    Write-Host 'Portable hook and dotted-name regressions passed.'
} catch {
    Write-Error $_
    exit 1
}
