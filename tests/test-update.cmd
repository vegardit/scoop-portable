@echo off
:: CI test: checks that scoop-portable survives scoop self-updates, both explicit
:: ("scoop update") and implicit (when scoop is outdated during other commands)

:: add commands eval.cmd and scoop-portable.cmd to PATH
set "PATH=%~dp0;%PATH%"

:: execute scoop from different directory
pushd %TEMP%

  call eval whoami

  :: load environment
  call eval call scoop-portable

  :: on first execution the current scoop install wil be replaced by a git clone
  call eval call scoop update

  :: subsequent executions scoop just uses git fetch/pull to update
  call eval call scoop update

  call eval call scoop update yq

  :: mark scoop as outdated so that the next command runs scoop's implicit self-update.
  :: autostash_on_conflict makes that self-update drop the patched lib files (like the
  :: fresh clone of a non-git install does), so the wrapper must re-apply the patches
  call eval call scoop config autostash_on_conflict true
  for %%c in ("install jq" "update yq" "download jq") do (
    call eval call scoop config last_update 2000-01-01T00:00:00
    call eval call scoop %%~c
    call :assert_scoop_patched
  )

popd

goto :EOF


:assert_scoop_patched
  findstr /L /C:".portable" "%SCOOP%\apps\scoop\current\lib\core.ps1" >NUL || (
    echo "ERROR: scoop-portable patches are missing in [%SCOOP%\apps\scoop\current\lib\core.ps1]!"
    exit 1
  )
goto :EOF
