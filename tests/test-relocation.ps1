# Exercises the real batch loader after moving a stub installation into and out of
# an apostrophe-containing path. No downloads or persistent environment writes are needed.
param([string]$PortableRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Value($Actual, $Expected, [string]$Description) {
    if ($Actual -cne $Expected) { throw "Unexpected value: $Description" }
}

function Invoke-Loader {
    # CALL preserves a batch file's exit code when it finishes with goto :eof.
    & $env:ComSpec /D /S /C ('call "{0}\load.cmd"' -f $fixtureRoot)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not load relocated fixture:`n$(Get-Content -LiteralPath "$fixtureRoot\load.log" -Raw)"
    }
}

# Keep the unique fixture for diagnosis, like the other wrapper tests.
$testRoot = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('scoop-portable-relocation-' + [guid]::NewGuid().ToString('N'))))
$fixtureRoot = Join-Path $testRoot 'original'
foreach ($directory in @('.portable\scoop', '.portable\active_versions', 'shims',
        'apps\scoop\current', 'apps\fixture\1', 'persist\fixture\data')) {
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot $directory) -Force | Out-Null
}
Copy-Item -LiteralPath "$PortableRoot\scoop-portable.cmd" -Destination "$fixtureRoot\scoop-portable.cmd"
"$env:USERDOMAIN\$env:USERNAME" | Set-Content -LiteralPath "$fixtureRoot\.portable\last.user"
'{}' | Set-Content -LiteralPath "$fixtureRoot\.portable\scoop\config.json"
$manifest = '{"version":"1","persist":["data","settings.txt"]}'
$manifest | Set-Content -LiteralPath "$fixtureRoot\.portable\active_versions\fixture.json"
$manifest | Set-Content -LiteralPath "$fixtureRoot\apps\fixture\1\manifest.json"
'directory contents' | Set-Content -LiteralPath "$fixtureRoot\persist\fixture\data\kept.txt"
'file contents' | Set-Content -LiteralPath "$fixtureRoot\persist\fixture\settings.txt"
New-Item -ItemType Junction -Path "$fixtureRoot\apps\fixture\current" -Target "$fixtureRoot\apps\fixture\1" | Out-Null
New-Item -ItemType Junction -Path "$fixtureRoot\apps\fixture\1\data" -Target "$fixtureRoot\persist\fixture\data" | Out-Null
New-Item -ItemType HardLink -Path "$fixtureRoot\apps\fixture\1\settings.txt" -Target "$fixtureRoot\persist\fixture\settings.txt" | Out-Null

# Seed the formats rewritten by fix_paths with the original absolute path.
foreach ($relativePath in @('shims\scoop', 'shims\scoop.ps1', 'shims\fixture.shim', 'apps\fixture\1\fixture.ini')) {
    "# $fixtureRoot\apps\fixture\current" | Set-Content -LiteralPath (Join-Path $fixtureRoot $relativePath)
}
@("@rem $fixtureRoot\apps\scoop\current", '@exit /B 0') | Set-Content -LiteralPath "$fixtureRoot\shims\scoop.cmd"
('@set "PORTABLE_TEST_RELOCATED=' + $fixtureRoot + '\persist\fixture\data"') |
    Set-Content -LiteralPath "$fixtureRoot\.portable\active_versions\fixture.PORTABLE_TEST_RELOCATED.env_set.cmd"
"$fixtureRoot\persist\fixture\data" | Set-Content -LiteralPath "$fixtureRoot\.portable\active_versions\fixture.1.env_add_path"
@'
@echo off
set "PORTABLE_TEST_RELOCATED="
call "%~dp0scoop-portable.cmd" >"%~dp0load.log" 2>&1
if errorlevel 1 exit /B 1
>"%~dp0session.txt" echo %PORTABLE_TEST_RELOCATED%
>"%~dp0path.txt" echo %PATH%
exit /B 0
'@ | Set-Content -LiteralPath "$fixtureRoot\load.cmd"

# Let the loader write last.dir before moving, so the test exercises its actual
# relocation detection rather than invoking a copied PowerShell fragment.
Invoke-Loader
foreach ($directoryName in @("O'Brien scoop", 'plain-again')) {
    $nextRoot = Join-Path $testRoot $directoryName
    # Both resolved paths must remain direct children of this fixture's parent.
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($fixtureRoot)) -ne $testRoot -or
        [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($nextRoot)) -ne $testRoot) {
        throw 'Refusing to move a directory outside the relocation fixture'
    }
    Rename-Item -LiteralPath $fixtureRoot -NewName $directoryName
    $fixtureRoot = $nextRoot
    Invoke-Loader

    foreach ($relativePath in @('shims\scoop', 'shims\scoop.ps1', 'shims\fixture.shim', 'apps\fixture\1\fixture.ini')) {
        Assert-Value (Get-Content -LiteralPath (Join-Path $fixtureRoot $relativePath)) "# $fixtureRoot\apps\fixture\current" $relativePath
    }
    Assert-Value (Get-Content -LiteralPath "$fixtureRoot\shims\scoop.cmd" -First 1) "@rem $fixtureRoot\apps\scoop\current" 'Scoop CMD shim'
    Assert-Value (Get-Content -LiteralPath "$fixtureRoot\.portable\last.dir" -First 1) $fixtureRoot 'recorded installation root'
    Assert-Value (Get-Content -LiteralPath "$fixtureRoot\session.txt") "$fixtureRoot\persist\fixture\data" 'restored environment variable'
    if ((Get-Content -LiteralPath "$fixtureRoot\path.txt") -split ';' -notcontains "$fixtureRoot\persist\fixture\data") {
        throw 'Relocated hook path was not added to PATH'
    }

    $current = Get-Item -LiteralPath "$fixtureRoot\apps\fixture\current"
    Assert-Value $current.LinkType 'Junction' 'current version link type'
    Assert-Value ([string]$current.Target) "$fixtureRoot\apps\fixture\1" 'current version target'
    $data = Get-Item -LiteralPath "$fixtureRoot\apps\fixture\current\data"
    Assert-Value $data.LinkType 'Junction' 'persisted directory link type'
    Assert-Value ([string]$data.Target) "$fixtureRoot\persist\fixture\data" 'persisted directory target'
    Assert-Value (Get-Content -LiteralPath "$fixtureRoot\apps\fixture\current\data\kept.txt") 'directory contents' 'persisted directory contents'
    # A later write proves the persisted file is still a hard link, not a copied snapshot.
    $directoryName | Set-Content -LiteralPath "$fixtureRoot\persist\fixture\settings.txt"
    Assert-Value (Get-Content -LiteralPath "$fixtureRoot\apps\fixture\current\settings.txt") $directoryName 'persisted file link'
    Write-Host "Relocation passed: $directoryName"
}
