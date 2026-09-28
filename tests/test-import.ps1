# Offline regression for the global-install guard on Scoopfile imports.
# Keep Scoop's real dispatcher and importer, but replace all external side effects
# so even the unfixed wrapper cannot install apps or change the user's settings.
param([string]$PortableRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'

function Invoke-Wrapper([string]$Arguments, [int]$ExpectedExitCode = 0) {
    # CALL preserves batch exit codes, and CMD captures expected stderr without
    # turning it into NativeCommandError records in this PowerShell test process.
    & $env:ComSpec /D /S /C ('call "{0}\.portable\scoop.cmd" {1} >"{0}\wrapper.log" 2>&1' -f $fixture, $Arguments)
    if ($LASTEXITCODE -ne $ExpectedExitCode) {
        throw "Unexpected exit code ${LASTEXITCODE}: $Arguments`n$(Get-Content -LiteralPath "$fixture\wrapper.log" -Raw)"
    }
}

function Assert-Effects([string[]]$Expected = @()) {
    $actual = @(Get-Content -LiteralPath "$fixture\effects.log" | Where-Object { $_ })
    if (($actual -join "`n") -cne ($Expected -join "`n")) {
        throw "Unexpected import effects: $($actual -join '; ')"
    }
}

function Write-Scoopfile([string]$Info) {
    @{
        config = @{ imported_probe = 'fixture value' }
        buckets = @(@{ Name = 'fixture'; Source = 'https://bucket.invalid' })
        # A later global entry must also prevent the earlier local installation.
        apps = @(
            @{ Name = 'first-app'; Source = 'fixture'; Info = '' }
            @{ Name = 'second-app'; Source = 'fixture'; Info = $Info }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$fixture\input file.json"
    [IO.File]::WriteAllText("$fixture\effects.log", '')
    [IO.File]::WriteAllText("$fixture\loads.log", '')
}

$previousScoop = $env:SCOOP
$previousHost = $env:PORTABLE_IMPORT_TEST_HOST
try {
    # Retain the unique fixture for diagnosis, as the other batch fixtures do.
    # Spaces and apostrophes also exercise the new patcher's path handling.
    $fixture = Join-Path $env:TEMP ("scoop-portable-import-O'Brien " + [guid]::NewGuid().ToString('N'))
    $scoopSource = Join-Path $PortableRoot 'apps\scoop\current'
    $scoop = Join-Path $fixture 'apps\scoop\current'
    $lib = Join-Path $scoop 'lib'
    $importFile = Join-Path $scoop 'libexec\scoop-import.ps1'
    foreach ($directory in @($lib, "$scoop\bin", "$scoop\libexec", "$fixture\shims",
            "$fixture\.portable\scoop", "$fixture\.portable\active_versions")) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Copy-Item -LiteralPath "$PortableRoot\scoop-portable.cmd" -Destination "$fixture\.portable\scoop.cmd"
    Copy-Item -LiteralPath "$scoopSource\bin\scoop.ps1" -Destination "$scoop\bin\scoop.ps1"
    Copy-Item -LiteralPath "$scoopSource\lib\commands.ps1" -Destination "$lib\commands.ps1"
    Copy-Item -LiteralPath "$scoopSource\lib\manifest.ps1" -Destination "$lib\manifest.ps1"
    $upstreamImport = [IO.File]::ReadAllText("$scoopSource\libexec\scoop-import.ps1")
    # The installed importer may already be guarded. Remove only our generated block
    # from this copy so write failures and self-updates still exercise patching.
    # Keep this literal in sync with define_scoop_patches in scoop-portable.cmd.
    $installedGuard = @'
# scoop-portable: Imports bypass the CMD install guard. Check all apps before applying the Scoopfile.
# Throw unwinds Scoop's dispatcher; abort can return success after exiting only this child script.
foreach ($portableApp in $import.apps) {
    if ('Global install' -in ($portableApp.Info -split ', ')) {
        throw ('scoop-portable: Cannot import global app {0}. Remove its entry or remove Global install from its Info field to install it locally.' -f $portableApp.Name)
    }
}
'@
    # Match either checkout newline style without normalizing the rest of Scoop's script.
    foreach ($newline in @("`r`n", "`n")) {
        $upstreamImport = $upstreamImport.Replace(($installedGuard -replace '\r?\n', $newline) + $newline, '')
    }
    [IO.File]::WriteAllText("$fixture\upstream-import.ps1", $upstreamImport)
    [IO.File]::WriteAllText($importFile, $upstreamImport)
    @'
@echo off
"%PORTABLE_IMPORT_TEST_HOST%" -noprofile -ex unrestricted -file "%~dp0..\apps\scoop\current\bin\scoop.ps1" %*
exit /B %errorlevel%
'@ | Set-Content -LiteralPath "$fixture\shims\scoop.cmd"
    @'
$scoopdir = $env:SCOOP
$configHome = $env:XDG_CONFIG_HOME
function Get-DefaultArchitecture { '64bit' }
function abort($msg, [int]$exit_code = 1) { Write-Host $msg; exit $exit_code }
function warn($msg) { Write-Warning $msg }
function set_config($Name, $Value) { Add-Content -LiteralPath "$env:SCOOP\effects.log" -Value "config $Name" }
'@ | Set-Content -LiteralPath "$lib\core.ps1"
    'function add_bucket($Name, $Source) { Add-Content -LiteralPath "$env:SCOOP\effects.log" -Value "bucket $Name" }' |
        Set-Content -LiteralPath "$lib\buckets.ps1"
    '# No help functions are needed by the fixture.' | Set-Content -LiteralPath "$lib\help.ps1"
    @'
function create_startmenu_shortcuts($manifest, $dir, $global, $arch) {
}
function startmenu_shortcut([System.IO.FileInfo] $target, $shortcutName, $arguments, [System.IO.FileInfo]$icon, $global) {
}
'@ | Set-Content -LiteralPath "$lib\shortcuts.ps1"
    "function Set-EnvVar {`r`n    throw 'Registry writes are forbidden in this fixture'`r`n}" |
        Set-Content -LiteralPath "$lib\system.ps1"
    "function Invoke-HookScript {`r`n}" | Set-Content -LiteralPath "$lib\install.ps1"
    # Exercise the importer's URL branch without opening a network connection.
    @'
function url_manifest($url) {
    Add-Content -LiteralPath "$env:SCOOP\loads.log" -Value $url
    parse_json "$env:SCOOP\input file.json"
}
'@ | Add-Content -LiteralPath "$lib\manifest.ps1"
    foreach ($command in 'install', 'hold') {
        ('Add-Content -LiteralPath "$env:SCOOP\effects.log" -Value (''{0} '' + ($args -join '' ''))' -f $command) |
            Set-Content -LiteralPath "$scoop\libexec\scoop-$command.ps1"
    }
    foreach ($command in 'list', 'config', 'help') {
        '# Deliberately no external effects.' | Set-Content -LiteralPath "$scoop\libexec\scoop-$command.ps1"
    }
    @'
# A self-update replaces the importer while leaving the general patch marker intact.
Copy-Item -LiteralPath "$env:SCOOP\upstream-import.ps1" -Destination "$PSScriptRoot\scoop-import.ps1" -Force
'{"last_update":"2099-01-01T00:00:00"}' | Set-Content -LiteralPath "$env:SCOOP\.portable\scoop\config.json"
Add-Content -LiteralPath "$env:SCOOP\updates.log" -Value 'self-update'
'@ | Set-Content -LiteralPath "$scoop\libexec\scoop-update.ps1"
    '{"last_update":"2099-01-01T00:00:00"}' | Set-Content -LiteralPath "$fixture\.portable\scoop\config.json"
    $env:SCOOP = $fixture

    $hosts = @(Get-Command powershell.exe, pwsh.exe -CommandType Application -ErrorAction SilentlyContinue |
        Group-Object Name | ForEach-Object { $_.Group[0].Source })
    if (-not $hosts) { throw 'No PowerShell host found' }
    foreach ($hostPath in $hosts) {
        $env:PORTABLE_IMPORT_TEST_HOST = $hostPath
        foreach ($info in 'Global install', '64bit, gLoBaL InStAlL, Held package') {
            Write-Scoopfile $info
            Invoke-Wrapper ('"IMPORT" "{0}\input file.json"' -f $fixture) 1
            Assert-Effects
            $output = Get-Content -LiteralPath "$fixture\wrapper.log" -Raw
            if ($output -notmatch 'second-app') { throw 'Rejection did not identify the global app' }
        }
        Write-Scoopfile 'Global install'
        Invoke-Wrapper 'import https://fixture.invalid/scoopfile.json' 1
        Assert-Effects
        if (@(Get-Content -LiteralPath "$fixture\loads.log").Count -ne 1) { throw 'URL was not loaded exactly once' }

        Write-Scoopfile '64bit, Held package'
        Invoke-Wrapper ('import "{0}\input file.json"' -f $fixture)
        Assert-Effects @('config imported_probe', 'bucket fixture', 'install fixture/first-app', 'install fixture/second-app', 'hold second-app')
    }

    $patched = [Convert]::ToBase64String([IO.File]::ReadAllBytes($importFile))
    Write-Scoopfile ''
    Invoke-Wrapper ('import "{0}\input file.json"' -f $fixture)
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($importFile)) -cne $patched) { throw 'Repeated patching changed the importer' }

    # Invalid boundaries must block imports without changing the file or preventing
    # unrelated commands and help from running. A substring match is insufficient.
    $anchor = 'foreach ($item in $import.config.PSObject.Properties) {'
    foreach ($broken in @($upstreamImport.Replace($anchor, 'foreach ($item in @()) {'),
            ($upstreamImport + "`r`n" + $anchor + "`r`n}`r`n"))) {
        [IO.File]::WriteAllText($importFile, $broken)
        Write-Scoopfile ''
        Invoke-Wrapper ('import "{0}\input file.json"' -f $fixture) 1
        Assert-Effects
        if ([IO.File]::ReadAllText($importFile) -cne $broken) { throw 'An unsupported importer was modified' }
        Invoke-Wrapper list
        Invoke-Wrapper 'import --help'
    }

    [IO.File]::Move($importFile, "$fixture\missing-import.ps1")
    Invoke-Wrapper ('import "{0}\input file.json"' -f $fixture) 1
    Assert-Effects
    [IO.File]::WriteAllText($importFile, $upstreamImport)
    $originalAttributes = [IO.File]::GetAttributes($importFile)
    try {
        [IO.File]::SetAttributes($importFile, $originalAttributes -bor [IO.FileAttributes]::ReadOnly)
        Invoke-Wrapper ('import "{0}\input file.json"' -f $fixture) 1
        Assert-Effects
    } finally {
        [IO.File]::SetAttributes($importFile, $originalAttributes)
    }
    Invoke-Wrapper ('import "{0}\input file.json"' -f $fixture)

    # Both newline styles and UTF-8 BOMs must survive; exact stash ownership checks
    # compare bytes, so an encoding conversion would make our own patch unrecognizable.
    foreach ($newline in @("`n", "`r`n")) {
        foreach ($bom in @($false, $true)) {
            $encoding = New-Object System.Text.UTF8Encoding($bom)
            $original = ($upstreamImport -replace '\r?\n', $newline) + '# ' + [char]0x00E4 + $newline
            [IO.File]::WriteAllText($importFile, $original, $encoding)
            Write-Scoopfile ''
            Invoke-Wrapper ('import "{0}\input file.json"' -f $fixture)
            $bytes = [IO.File]::ReadAllBytes($importFile)
            if (($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -ne $bom) {
                throw 'Patching changed the UTF-8 BOM'
            }
            $text = [IO.File]::ReadAllText($importFile)
            if (-not $text.EndsWith('# ' + [char]0x00E4 + $newline) -or
                ($newline -eq "`n" -and $text.Contains("`r")) -or
                ($newline -eq "`r`n" -and $text -match '(?<!\r)\n')) { throw 'Patching changed the encoding or newlines' }
        }
    }

    '{"last_update":"2000-01-01T00:00:00"}' | Set-Content -LiteralPath "$fixture\.portable\scoop\config.json"
    Write-Scoopfile 'Global install'
    Invoke-Wrapper ('import "{0}\input file.json"' -f $fixture) 1
    Assert-Effects
    if (@(Get-Content -LiteralPath "$fixture\updates.log").Count -ne 1) { throw 'The self-update fixture did not run once' }
    Write-Host 'Scoopfile import guard tests passed.'
} finally {
    $env:SCOOP = $previousScoop
    $env:PORTABLE_IMPORT_TEST_HOST = $previousHost
}
