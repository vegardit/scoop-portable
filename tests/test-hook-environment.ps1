# CI regression fixture for portable declarations, hook settings, shared search paths and saved-state ownership.
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

function Invoke-Wrapper([string]$Arguments, [int]$ExpectedExitCode = 0) {
    # Capture stderr in CMD so expected cleanup errors do not become terminating
    # NativeCommandError records in the PowerShell test process.
    # CALL preserves the wrapper's exit code; direct cmd /c invocation can return
    # zero when the batch file finishes with goto :eof.
    & $env:ComSpec /D /S /C ('call "{0}\.portable\scoop.cmd" {1} >"{0}\wrapper.log" 2>&1' -f $fixtureRoot, $Arguments)
    if ($LASTEXITCODE -ne $ExpectedExitCode) {
        throw "Unexpected wrapper exit code ${LASTEXITCODE}: $Arguments`n$(Get-Content -LiteralPath "$fixtureRoot\wrapper.log" -Raw)"
    }
}

function Write-SavedState([string]$Name, [switch]$WithoutSnapshots) {
    $files = @{
        "$Name.1.env_add_path" = 'bin'
        "$Name.PORTABLE_TEST_OWNER.env_set.cmd" = '@set "PORTABLE_TEST_OWNER=' + $Name + '"'
        "$Name.PORTABLE_TEST_LEGACY.env_set.cmd" = '@set PORTABLE_TEST_LEGACY=' + $Name
        # A dot can belong to the variable name even when an app has the longer prefix.
        "$Name.extra.PORTABLE_TEST_DOTTED.env_set.cmd" = '@set "extra.PORTABLE_TEST_DOTTED=' + $Name + '"'
    }
    if (-not $WithoutSnapshots) {
        $files["$Name.json"] = '{"version":"1"}'
        $files["$Name.env_hooks"] = '{}'
    }
    foreach ($file in $files.GetEnumerator()) {
        Set-Content -LiteralPath "$versions\$($file.Key)" -Value $file.Value
    }
    return $files.Keys
}

function Read-SavedState {
    $state = @{}
    foreach ($file in Get-ChildItem -LiteralPath $versions -File) {
        $state[$file.Name] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName))
    }
    return $state
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

function Invoke-InstallHooks([string]$Name, $Manifest, [string]$Architecture = '64bit') {
    # These variables are supplied by install_app to Invoke-HookScript in Scoop.
    $app = $Name
    $global = $false
    $dir = $original_dir = Join-Path $fixtureRoot "apps\$Name\1"
    $persist_dir = Join-Path $fixtureRoot "persist\$Name"
    $Manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$dir\manifest.json"
    @{ architecture = $Architecture } | ConvertTo-Json | Set-Content -LiteralPath "$dir\install.json"
    Invoke-HookScript -HookType pre_install -Manifest $Manifest -Arch $Architecture
    Invoke-HookScript -HookType installer -Manifest $Manifest -Arch $Architecture
    # Scoop switches to the junction before applying declarations and post_install.
    $dir = Join-Path $fixtureRoot "apps\$Name\current"
    $scoopPathEnvVar = 'PATH'
    env_add_path $Manifest $dir $false $Architecture
    env_set $Manifest $false $Architecture
    Invoke-HookScript -HookType post_install -Manifest $Manifest -Arch $Architecture
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
        Read-ScoopFunction install env_rm
        Read-ScoopFunction install Invoke-HookScript
    ) -join [Environment]::NewLine | Set-Content -LiteralPath "$lib\install.ps1"
    $env:SCOOP = $fixtureRoot
    Invoke-Wrapper list
    . "$lib\system.ps1"
    . "$lib\install.ps1"
    # Commands can source install.ps1 again in one process. The hook wrapper must
    # still delegate to upstream rather than capturing itself and recursing.
    . "$lib\install.ps1"

    $policyFiles = @(Write-SavedState 'restricted.app')
    $policyAppDir = "$fixtureRoot\apps\restricted.save\current"
    New-Item -ItemType Directory -Path $policyAppDir | Out-Null
    '{"version":"1","env_set":{"PORTABLE_TEST_POLICY":"refreshed"},"env_add_path":"new-bin"}' |
        Set-Content -LiteralPath "$policyAppDir\manifest.json"
    # Stale outputs prove that reset regenerates settings instead of retaining
    # files written by an earlier process with a permissive execution policy.
    '@set "PORTABLE_TEST_POLICY=stale"' | Set-Content -LiteralPath "$versions\restricted.save.PORTABLE_TEST_POLICY.env_set.cmd"
    'old-bin' | Set-Content -LiteralPath "$versions\restricted.save.1.env_add_path"
    $previousPolicy = $env:PSExecutionPolicyPreference
    try {
        # The runner's Unrestricted policy is inherited by child processes. Model
        # a copied installation under a restricted account without changing any
        # user or machine policy, and verify that the child really is restricted.
        $env:PSExecutionPolicyPreference = 'Restricted'
        Assert-Value (& powershell -noprofile -command 'Get-ExecutionPolicy') 'Restricted' 'child execution policy'
        Invoke-Wrapper 'reset restricted.save'
        Invoke-Wrapper 'uninstall restricted.app'
    } finally {
        $env:PSExecutionPolicyPreference = $previousPolicy
    }
    foreach ($file in $policyFiles) {
        Assert-Value (Test-Path -LiteralPath "$versions\$file") $false 'cleanup under a restricted account policy'
    }
    Assert-Value (Get-Content -LiteralPath "$versions\restricted.save.PORTABLE_TEST_POLICY.env_set.cmd" -Raw).Trim() `
        '@set "PORTABLE_TEST_POLICY=refreshed"' 'save settings under a restricted account policy'
    Assert-Value (Get-Content -LiteralPath "$versions\restricted.save.1.env_add_path" -Raw).Trim() `
        'new-bin' 'save PATH under a restricted account policy'

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
set "PORTABLE_TEST_DEP="
set "PORTABLE_TEST_REFERENCE="
set "PORTABLE_TEST_REFERENCE_BRACED="
set "PORTABLE_TEST_REFERENCE_PERSIST="
set "PORTABLE_TEST_REFERENCE_POST="
set "PORTABLE_TEST_REFERENCE_EMPTY=stale"
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
    reference = $env:PORTABLE_TEST_REFERENCE
    braced = $env:PORTABLE_TEST_REFERENCE_BRACED
    referencePersist = $env:PORTABLE_TEST_REFERENCE_PERSIST
    referencePost = $env:PORTABLE_TEST_REFERENCE_POST
    referenceEmpty = $env:PORTABLE_TEST_REFERENCE_EMPTY
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

    # The consumer sorts before its dependency. Neither saving nor loading may
    # rely on filename order or inherit the installing PowerShell's environment.
    foreach ($name in 'z-dependency', 'a-consumer') {
        New-Item -ItemType Directory -Path "$fixtureRoot\apps\$name\1" | Out-Null
        New-Item -ItemType Junction -Path "$fixtureRoot\apps\$name\current" -Target "$fixtureRoot\apps\$name\1" | Out-Null
    }
    '{"version":"1","env_set":{"PORTABLE_TEST_DEP":"$dir"}}' |
        Set-Content -LiteralPath "$fixtureRoot\apps\z-dependency\current\manifest.json"
    $referenceManifest = @'
{
    "version": "1",
    "pre_install": "Set-EnvVar PORTABLE_TEST_REFERENCE pre",
    "env_set": {"PORTABLE_TEST_REFERENCE": "wrong generic value"},
    "architecture": {
        "32bit": {"env_set": {
            "PORTABLE_TEST_REFERENCE": "$env:PORTABLE_TEST_DEP",
            "PORTABLE_TEST_REFERENCE_BRACED": "${env:PORTABLE_TEST_DEP}\\braced",
            "PORTABLE_TEST_REFERENCE_PERSIST": "$persist_dir\\$env:PORTABLE_TEST_PART",
            "PORTABLE_TEST_REFERENCE_EMPTY": "$env:PORTABLE_TEST_ABSENT",
            "PORTABLE_TEST_REFERENCE_POST": "$env:PORTABLE_TEST_DEP"
        }},
        "64bit": {"env_set": {"PORTABLE_TEST_REFERENCE": "wrong architecture"}}
    },
    "post_install": "Set-EnvVar PORTABLE_TEST_REFERENCE_POST \"$dir\\post\""
}
'@
    $referenceManifest | Set-Content -LiteralPath "$fixtureRoot\apps\a-consumer\current\manifest.json"
    @'
# Apply declarations in Scoop's process and dependency order, before returning to the saver.
$ErrorActionPreference = 'Stop'
$fixtureRoot = $env:SCOOP
. "$fixtureRoot\apps\scoop\current\lib\system.ps1"
. "$fixtureRoot\apps\scoop\current\lib\install.ps1"
'@ + "`r`nfunction Invoke-InstallHooks {`r`n" + ${function:Invoke-InstallHooks}.ToString() + "`r`n}`r`n" + @'
foreach ($name in 'z-dependency', 'a-consumer') {
    $manifest = Get-Content -LiteralPath "$fixtureRoot\apps\$name\current\manifest.json" -Raw | ConvertFrom-Json
    Invoke-InstallHooks $name $manifest 32bit
}
'@ | Set-Content -LiteralPath "$fixtureRoot\install-declarations.ps1"
    $env:PORTABLE_TEST_DEP = 'C:\stale-parent'
    $env:PORTABLE_TEST_PART = 'settings'
    $env:PORTABLE_TEST_ABSENT = $null
    & powershell -noprofile -ex unrestricted -file "$fixtureRoot\install-declarations.ps1"
    if ($LASTEXITCODE -ne 0) { throw 'Declaration installation fixture failed' }
    Invoke-Wrapper 'install a-consumer --no-update-scoop'
    $session = Read-Session
    Assert-Value $session.reference "$fixtureRoot\apps\z-dependency\current" 'reference to a newly installed dependency'
    Assert-Value $session.braced "$fixtureRoot\apps\z-dependency\current\braced" 'braced environment reference'
    Assert-Value $session.referencePersist "$fixtureRoot\persist\a-consumer\settings" 'mixed persist and environment references'
    Assert-Value $session.referenceEmpty $null 'unset environment reference'
    Assert-Value $session.referencePost "$fixtureRoot\apps\a-consumer\current\post" 'post-install overrides a declaration'

    # The general shim is a no-op. Reset coverage must really reapply declarations
    # in a child process, otherwise it only verifies replay of the installation record.
    @'
# Run the environment portion of Scoop's reset, with hooks intentionally absent.
param([string]$AppName)
$ErrorActionPreference = 'Stop'
. "$env:SCOOP\apps\scoop\current\lib\system.ps1"
. "$env:SCOOP\apps\scoop\current\lib\install.ps1"
$app = $AppName
$global = $false
$original_dir = "$env:SCOOP\apps\$app\1"
$dir = "$env:SCOOP\apps\$app\current"
$persist_dir = "$env:SCOOP\persist\$app"
$manifest = Get-Content -LiteralPath "$dir\manifest.json" -Raw | ConvertFrom-Json
$architecture = (Get-Content -LiteralPath "$dir\install.json" -Raw | ConvertFrom-Json).architecture
env_rm $manifest $global $architecture
env_set $manifest $global $architecture
'@ | Set-Content -LiteralPath "$fixtureRoot\reset-declarations.ps1"
    @'
@echo off
if /I not "%~1"=="reset" exit /B 0
powershell -noprofile -ex unrestricted -file "%~dp0..\reset-declarations.ps1" "%~2"
exit /B %errorlevel%
'@ | Set-Content -LiteralPath "$fixtureRoot\shims\scoop.cmd"
    try {
        $env:PORTABLE_TEST_DEP = "$fixtureRoot\apps\z-dependency\current\reset"
        Invoke-Wrapper 'reset a-consumer'
        $session = Read-Session
        Assert-Value $session.reference $env:PORTABLE_TEST_DEP 'reset captures a changed reference'
        Assert-Value $session.referencePost "$fixtureRoot\apps\a-consumer\current\post" 'reset retains post-install settings'

        $declarationRecord = "$fixtureRoot\apps\a-consumer\current\.scoop-portable-env.json"
        $originalDeclarations = Get-Content -LiteralPath $declarationRecord -Raw
        $lock = [IO.File]::Open($declarationRecord, 'Open', 'Read', 'Read')
        try {
            $env:PORTABLE_TEST_DEP = "$fixtureRoot\apps\z-dependency\current\retry"
            Invoke-Wrapper 'reset a-consumer' 1
            if ((Get-Content -LiteralPath "$fixtureRoot\wrapper.log" -Raw) -notlike '*could not save manifest settings*') {
                throw 'A declaration capture failure did not explain how to repair it'
            }
            Assert-Value (Get-Content -LiteralPath $declarationRecord -Raw) $originalDeclarations 'failed capture preserves the complete record'
        } finally {
            $lock.Dispose()
        }
        Invoke-Wrapper 'reset a-consumer'
        Assert-Value (Read-Session).reference $env:PORTABLE_TEST_DEP 'capture can be retried after a blocked write'

        # Simulate stored values from the former root, then reset at the new root.
        # The nested-root case catches accidentally rebasing freshly captured
        # declarations using the older origin still needed by the retained hooks.
        $originalDeclarations = Get-Content -LiteralPath $declarationRecord -Raw
        $escapedRoot = ($fixtureRoot | ConvertTo-Json -Compress).Trim('"')
        foreach ($previousRoot in 'Z:\previous-scoop', (Split-Path $fixtureRoot -Parent)) {
            $escapedPreviousRoot = ($previousRoot | ConvertTo-Json -Compress).Trim('"')
            $originalDeclarations.Replace($escapedRoot, $escapedPreviousRoot) | Set-Content -LiteralPath $declarationRecord
            Invoke-Wrapper 'update --all'
            $session = Read-Session
            Assert-Value $session.reference "$fixtureRoot\apps\z-dependency\current\retry" 'relocated dependency reference'
            Assert-Value $session.referencePersist "$fixtureRoot\persist\a-consumer\settings" 'relocated persist reference'
            Assert-Value $session.referencePost "$fixtureRoot\apps\a-consumer\current\post" 'relocated post-install setting'
            $env:PORTABLE_TEST_DEP = "$fixtureRoot\apps\z-dependency\current\moved"
            Invoke-Wrapper 'reset a-consumer'
            $session = Read-Session
            Assert-Value $session.reference $env:PORTABLE_TEST_DEP 'reset refreshes declaration origins after a move'
            Assert-Value $session.referencePost "$fixtureRoot\apps\a-consumer\current\post" 'reset preserves hook origins after a move'
        }

        # An older installation can have hook records but no declaration section.
        # Reset must add that section without discarding the saved post-install value.
        $legacyRecord = Get-Content -LiteralPath $declarationRecord -Raw | ConvertFrom-Json
        $legacyRecord.PSObject.Properties.Remove('declarations')
        $legacyRecord | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $declarationRecord
        $env:PORTABLE_TEST_DEP = "$fixtureRoot\apps\z-dependency\current\repaired"
        Invoke-Wrapper 'reset a-consumer'
        $session = Read-Session
        Assert-Value $session.reference $env:PORTABLE_TEST_DEP 'reset repairs a legacy declaration record'
        Assert-Value $session.referencePost "$fixtureRoot\apps\a-consumer\current\post" 'legacy repair retains hook settings'

        $reducedManifest = $referenceManifest | ConvertFrom-Json
        $reducedManifest.architecture.'32bit'.env_set.PSObject.Properties.Remove('PORTABLE_TEST_REFERENCE_BRACED')
        $reducedManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$fixtureRoot\apps\a-consumer\current\manifest.json"
        Invoke-Wrapper 'reset a-consumer'
        Assert-Value (Read-Session).braced $null 'removed declaration is pruned'
        '{"version":"2"}' | Set-Content -LiteralPath "$fixtureRoot\apps\a-consumer\current\manifest.json"
        Invoke-Wrapper 'reset a-consumer'
        $session = Read-Session
        Assert-Value $session.reference 'pre' 'empty declaration snapshot preserves earlier hook settings'
        Assert-Value $session.referencePersist $null 'empty declaration snapshot drops obsolete declarations'
        Assert-Value $session.referencePost "$fixtureRoot\apps\a-consumer\current\post" 'empty declaration snapshot preserves later hooks'
        Write-Host 'Portable declaration capture regressions passed.'
    } finally {
        '@exit /B 0' | Set-Content -LiteralPath "$fixtureRoot\shims\scoop.cmd"
    }

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
    # Reset must replace a damaged generated file without first needing its old contents.
    New-Item -ItemType Directory -Path "$fixtureRoot\apps\repair\current" | Out-Null
    '{"version":"1","env_set":{"PORTABLE_TEST_REPAIRED":"restored"}}' |
        Set-Content -LiteralPath "$fixtureRoot\apps\repair\current\manifest.json"
    Set-Content -LiteralPath "$versions\repair.PORTABLE_TEST_REPAIRED.env_set.cmd" -Value '' -NoNewline
    Invoke-Wrapper 'reset repair'
    Assert-Value (Get-Content -LiteralPath "$versions\repair.PORTABLE_TEST_REPAIRED.env_set.cmd" -Raw).Trim() `
        '@set "PORTABLE_TEST_REPAIRED=restored"' 'reset repairs an empty generated file'
    Write-Host 'Empty-script repair regression passed.'

    foreach ($pair in @(@('foo', 'foo.extra'), @('foo.extra', 'foo'),
            @('foo.extra', 'foo.extra.more'), @('foo.1', 'foo'), @('foo', 'foo.1'),
            @('orphan.gone', 'orphan.live'))) {
        $removed, $kept = $pair
        New-Item -ItemType Directory -Path "$fixtureRoot\apps\$kept\current" -Force | Out-Null
        # The stub Scoop leaves directories alone. Only the survivor has a current
        # directory, reproducing the filesystem state after an actual uninstall.
        $withoutSnapshots = $removed -eq 'orphan.gone'
        $removedFiles = @(Write-SavedState $removed -WithoutSnapshots:$withoutSnapshots)
        $keptFiles = @(Write-SavedState $kept -WithoutSnapshots:$withoutSnapshots)
        $expected = Read-SavedState
        foreach ($file in $removedFiles) { $expected.Remove($file) }
        Invoke-Wrapper "uninstall $removed"
        foreach ($file in $removedFiles) {
            Assert-Value (Test-Path -LiteralPath "$versions\$file") $false "remove $file"
        }
        $actual = Read-SavedState
        Assert-Value $actual.Count $expected.Count 'uninstall removes only the absent app state'
        foreach ($file in $expected.Keys) {
            Assert-Value $actual[$file] $expected[$file] "preserve $file after uninstalling $removed"
        }
        # These fixture directories are empty; the non-recursive delete cannot remove app data.
        [IO.Directory]::Delete("$fixtureRoot\apps\$kept\current")
        Invoke-Wrapper "uninstall $kept"
        foreach ($file in $keptFiles) {
            Assert-Value (Test-Path -LiteralPath "$versions\$file") $false "remove remaining $file"
        }
    }

    # Saving uses the same ownership rule. A numeric app suffix must not protect
    # an obsolete PATH index, nor may a dotted variable be pruned by a neighboring app.
    foreach ($name in 'refresh', 'refresh.extra', 'refresh.1') {
        New-Item -ItemType Directory -Path "$fixtureRoot\apps\$name\current" -Force | Out-Null
        '{"version":"1"}' | Set-Content -LiteralPath "$fixtureRoot\apps\$name\current\manifest.json"
    }
    '{"version":"1","env_add_path":"old-bin","env_set":{"extra.PORTABLE_TEST_REMOVED":"old"}}' |
        Set-Content -LiteralPath "$fixtureRoot\apps\refresh\current\manifest.json"
    Invoke-Wrapper 'reset refresh refresh.extra refresh.1'
    Assert-Value (Test-Path -LiteralPath "$versions\refresh.extra.PORTABLE_TEST_REMOVED.env_set.cmd") $true `
        'refreshing a neighboring app preserves a dotted variable'
    '{"version":"2"}' | Set-Content -LiteralPath "$fixtureRoot\apps\refresh\current\manifest.json"
    Invoke-Wrapper 'reset refresh'
    Assert-Value (Test-Path -LiteralPath "$versions\refresh.1.env_add_path") $false 'prune PATH despite a numeric app suffix'
    Assert-Value (Test-Path -LiteralPath "$versions\refresh.extra.PORTABLE_TEST_REMOVED.env_set.cmd") $false 'prune a dotted variable'
    foreach ($name in 'refresh.extra', 'refresh.1') {
        Assert-Value (Test-Path -LiteralPath "$versions\$name.json") $true 'preserve the neighboring version record'
    }

    $blockedFiles = @(Write-SavedState 'blocked.app')
    $blockedFile = "$versions\blocked.app.PORTABLE_TEST_OWNER.env_set.cmd"
    # Allow the ownership reader, but deny deletion until the handle is disposed.
    # Read-only attributes alone would not exercise Remove-Item -Force failures.
    $lock = [IO.File]::Open($blockedFile, 'Open', 'Read', 'Read')
    try {
        Invoke-Wrapper 'uninstall blocked.app' 1
        Assert-Value (Test-Path -LiteralPath "$versions\blocked.app.json") $true 'retain the manifest after failed cleanup'
        Assert-Value (Test-Path -LiteralPath $blockedFile) $true 'retain the locked file'
        '@exit /B 7' | Set-Content -LiteralPath "$fixtureRoot\shims\scoop.cmd"
        Invoke-Wrapper 'uninstall blocked.app' 7
    } finally {
        $lock.Dispose()
        '@exit /B 0' | Set-Content -LiteralPath "$fixtureRoot\shims\scoop.cmd"
    }
    Invoke-Wrapper 'uninstall blocked.app'
    foreach ($file in $blockedFiles) {
        Assert-Value (Test-Path -LiteralPath "$versions\$file") $false 'retry cleanup after releasing the lock'
    }

    $unknownFile = "$versions\unknown.PORTABLE_TEST.env_set.cmd"
    '@rem Cannot identify an owner' | Set-Content -LiteralPath $unknownFile
    Invoke-Wrapper 'uninstall unknown' 1
    Assert-Value (Test-Path -LiteralPath $unknownFile) $true 'retain an unidentifiable file'
    if ((Get-Content -LiteralPath "$fixtureRoot\wrapper.log" -Raw) -notlike '*unknown.PORTABLE_TEST.env_set.cmd*') {
        throw 'Cleanup did not identify the file that needs repair'
    }
    '@set "PORTABLE_TEST=recovered"' | Set-Content -LiteralPath $unknownFile
    Invoke-Wrapper 'uninstall unknown'
    Assert-Value (Test-Path -LiteralPath $unknownFile) $false 'retry cleanup after repairing an orphan script'
    Write-Host 'Portable hook and saved-state ownership regressions passed.'
} catch {
    Write-Error $_
    exit 1
}
