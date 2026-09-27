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

  :: mark scoop as outdated, so that the wrapper lets scoop update itself in a run of its own
  :: before the next command, which scoop would otherwise do within it. The wrapper sets
  :: autostash_on_conflict for that run, which makes it drop the patched lib files (like the
  :: fresh clone of a non-git install does), so the wrapper must re-apply the patches
  for %%c in ("install jq" "update yq" "download jq") do (
    call eval call scoop config last_update 2000-01-01T00:00:00
    REM the check after the command only means something if scoop really was outdated in the
    REM file it reads, e.g. not if scoop used another config file
    findstr /L /C:"2000-01-01" "%SCOOP%\.portable\scoop\config.json" >NUL || (
      echo "ERROR: the outdated last update is missing in [%SCOOP%\.portable\scoop\config.json]!"
      exit 1
    )
    call eval call scoop %%~c
    call :assert_scoop_patched
    REM only a completed "scoop update" run replaces the outdated last update. install and
    REM download get --no-update-scoop, so for them this shows that the wrapper ran one before
    REM them. For "update yq", scoop would also update itself within the run, so this only shows
    REM that scoop got updated; the separate run is covered by the stub tests of test-scoop.cmd
    findstr /L /C:"2000-01-01" "%SCOOP%\.portable\scoop\config.json" >NUL && (
      echo "ERROR: scoop did not update itself before [scoop %%~c]!"
      exit 1
    )
  )

  :: This fixture only has generated portable patches. User edits and unknown changes
  :: must be preserved instead; those cases are covered by test-scoop.cmd.
  git -C "%SCOOP%\apps\scoop\current" stash list | findstr /L /C:"WIP at" >NUL && (
    echo "ERROR: portable-only stash entries remain after the self-updates of scoop!"
    exit 1
  )

  :: assert the wrapper removed autostash_on_conflict again after these self-updates, so that
  :: scoop skips an update within another command instead of pulling unpatched lib files
  findstr /L /C:"autostash_on_conflict" "%SCOOP%\.portable\scoop\config.json" >NUL && (
    echo "ERROR: autostash_on_conflict is still set in [%SCOOP%\.portable\scoop\config.json]!"
    exit 1
  )

  :: assert the updates above wrote no persistent user environment variables, e.g. the shims
  :: folder that scoop adds to PATH when it re-creates its own shim while updating itself
  call assert-user-env-untouched

popd

goto :EOF


:assert_scoop_patched
  findstr /L /C:".portable" "%SCOOP%\apps\scoop\current\lib\core.ps1" >NUL || (
    echo "ERROR: scoop-portable patches are missing in [%SCOOP%\apps\scoop\current\lib\core.ps1]!"
    exit 1
  )
goto :EOF
