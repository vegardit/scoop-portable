@echo off
:: CI test: loads scoop-portable and checks the behavior of its scoop wrapper
:: (app installs, active version tracking, java switching, exit codes)
setlocal

:: https://superuser.com/questions/80485/exit-batch-file-from-subroutine
if not "%selfWrapped%"=="%~0" (
  REM this is necessary so that we can use "exit" to terminate the batch file,
  REM and all subroutines, but not the original cmd.exe
  set "selfWrapped=%~0"
  %ComSpec% /S /C ""%~0" %*"
  REM "cmd /c test-scoop.cmd" (as used by CI via sudo) exits with 0 if this script
  REM ends with "goto :EOF", so pass the exit code of the wrapped run on explicitly
  call exit /B %%errorlevel%%
)

:: add commands eval.cmd to PATH
set "PATH=%~dp0;%PATH%"

:: execute scoop from different directory
pushd %TEMP%

  call eval whoami

  :: install/load environment
  call eval call scoop-portable

  :: assert scoop is on path
  call eval call scoop --version

  :: assert auto installed via scoop-portable-config.cmd
  call eval yq --version

  :: install an app that uses 'add_env_path' and 'presist' in manifest.json
  if not exist %SCOOP%\apps\gpg call eval call scoop install gpg
  :: assert 'add_env_path' is evaluated as expected
  call eval gpg --version
  call :assert_file_exists "%SCOOP%\.portable\active_versions\gpg.json"
  call :assert_file_exists "%SCOOP%\.portable\active_versions\gpg.1.env_add_path"

  :: assert version info for transitive dependencies are created
  call :assert_file_exists "%SCOOP%\.portable\active_versions\7zip.json"

  :: test uninstalling an app
  call eval call scoop install jq
  call :assert_file_exists "%SCOOP%\.portable\active_versions\jq.json"
  call eval call scoop uninstall jq
  call :assert_file_not_exists "%SCOOP%\.portable\active_versions\jq.json"

  :: assert other version files still exist after uninstalling one app
  call :assert_file_exists "%SCOOP%\.portable\active_versions\7zip.json"
  call :assert_file_exists "%SCOOP%\.portable\active_versions\gpg.json"
  call :assert_file_exists "%SCOOP%\.portable\active_versions\gpg.1.env_add_path"
  call :assert_file_exists "%SCOOP%\.portable\active_versions\yq.json"

  :: test java switchign
  call eval call scoop reset temurin8-jdk
  call eval java -version
  call eval call scoop reset temurin11-jdk
  call eval java -version

  :: assert the wrapper returns the exit code of install/reset/uninstall.
  :: uses a stub scoop because scoop itself exits with 0 when a subcommand fails
  call :assert_wrapper_exit_codes

  :: assert global installs are rejected without installing anything.
  :: <NUL makes the error pause of exit_with_ERROR return immediately
  for %%f in (-g --global) do (
    echo ::group::call scoop install %%f jq - expected to be rejected
    call scoop install %%f jq <NUL
    call :assert_exit_code 1 "scoop install %%f jq"
    call :assert_file_not_exists "%SCOOP%\globalApps\apps\jq"
    echo ::endgroup::
  )

  :: assert installing another scoop-portable is rejected while scoop is on PATH
  call :assert_install_rejected_when_scoop_on_path

  :: assert "scoop update" refreshes the saved versions of updated apps and new dependencies,
  :: and does not switch JAVA_HOME to a JDK that was not updated
  call :assert_update_refreshes_active_versions
popd

goto :EOF


:assert_file_exists
  if not exist "%~1" (
    echo "ERROR: Expected file [%~1] does not exist!"
    exit 1
  )
goto :EOF


:assert_file_not_exists
  if exist "%~1" (
    echo "ERROR: Unexpected file [%~1] exists!"
    exit 1
  )
goto :EOF


:assert_wrapper_exit_codes
  echo ::group::wrapper exit codes (stub scoop exiting with 7)
  setlocal
  set "stub_root=%TEMP%\scoop-portable-exit-code-test"
  if exist "%stub_root%" rd /S /Q "%stub_root%"
  md "%stub_root%\shims" "%stub_root%\apps" "%stub_root%\.portable"
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%stub_root%\.portable\scoop.cmd" >NUL
  >"%stub_root%\shims\scoop.cmd" echo @exit /B 7
  set "SCOOP=%stub_root%"
  for %%c in (install reset uninstall) do (
    call "%SCOOP%\.portable\scoop.cmd" %%c some-app >NUL 2>&1
    call :assert_exit_code 7 "scoop %%c"
  )
  rd /S /Q "%stub_root%"
  endlocal
  echo ::endgroup::
goto :EOF


:assert_install_rejected_when_scoop_on_path
  echo ::group::install a second scoop-portable while scoop is on PATH - expected to be rejected
  setlocal
  set "other_root=%TEMP%\scoop-portable-guard-test"
  if exist "%other_root%" rd /S /Q "%other_root%"
  REM fail on setup errors, otherwise calling a missing wrapper would also count as the expected rejection
  md "%other_root%" || exit 1
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%other_root%\scoop-portable.cmd" >NUL || exit 1
  call "%other_root%\scoop-portable.cmd" <NUL
  call :assert_exit_code 1 "scoop-portable.cmd in [%other_root%]"
  REM .portable is created after the check, right before the installer is downloaded
  call :assert_file_not_exists "%other_root%\.portable"
  rd /S /Q "%other_root%"
  endlocal
  echo ::endgroup::
goto :EOF


:assert_update_refreshes_active_versions
  echo ::group::saved app versions after scoop update (stub scoop)
  setlocal
  set "stub_root=%TEMP%\scoop-portable-update-test"
  set "versions=%stub_root%\.portable\active_versions"
  if exist "%stub_root%" rd /S /Q "%stub_root%"
  REM fail on setup errors, otherwise a broken fixture could satisfy some assertions
  md "%stub_root%\shims" "%stub_root%\.portable" || exit 1
  for %%a in (foo bar jdk8 jdk11) do md "%stub_root%\apps\%%a\current" || exit 1
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%stub_root%\.portable\scoop.cmd" >NUL || exit 1
  REM the stub scoop does nothing; the test changes the manifests itself like an update would
  >"%stub_root%\shims\scoop.cmd" echo @exit /B 0
  >"%stub_root%\apps\foo\current\manifest.json" echo {"version": "1"}
  >"%stub_root%\apps\jdk8\current\manifest.json" echo {"version": "8", "env_set": {"JAVA_HOME": "$dir"}}
  >"%stub_root%\apps\jdk11\current\manifest.json" echo {"version": "11", "env_set": {"JAVA_HOME": "$dir"}}
  set "SCOOP=%stub_root%"

  REM make jdk11 the active JDK
  call "%SCOOP%\.portable\scoop.cmd" reset foo jdk8 jdk11 >NUL 2>&1
  call :assert_file_exists "%versions%\jdk11.JAVA_HOME.env_set.cmd"

  REM bar simulates a new dependency installed by the update
  >"%stub_root%\apps\bar\current\manifest.json" echo {"version": "1"}
  for %%u in ("main/foo" "--all" "scoop foo") do (
    >"%stub_root%\apps\foo\current\manifest.json" echo {"version": "%%~u"}
    call "%SCOOP%\.portable\scoop.cmd" update %%~u >NUL 2>&1
    call :assert_same_file "%stub_root%\apps\foo\current\manifest.json" "%versions%\foo.json" "scoop update %%~u"
  )
  call :assert_file_exists "%versions%\bar.json"

  REM an update of the not selected jdk8 must refresh its saved copy but keep jdk11 selected.
  REM called via a subroutine because a for loop would expand "*" even inside quotes
  call :assert_update_keeps_selected_jdk *
  call :assert_update_keeps_selected_jdk --all

  REM a bucket prefix must not prevent switching the JDK
  call "%SCOOP%\.portable\scoop.cmd" reset java/jdk8 >NUL 2>&1
  call :assert_file_exists "%versions%\jdk8.JAVA_HOME.env_set.cmd"
  call :assert_file_not_exists "%versions%\jdk11.JAVA_HOME.env_set.cmd"

  REM naming a JDK in "scoop update" still selects it, even if it was already up to date
  call "%SCOOP%\.portable\scoop.cmd" update jdk11 >NUL 2>&1
  call :assert_file_exists "%versions%\jdk11.JAVA_HOME.env_set.cmd"
  call :assert_file_not_exists "%versions%\jdk8.JAVA_HOME.env_set.cmd"

  REM "*" must not be expanded to file names: run from a folder containing a file named
  REM like the not selected jdk8, which must then not be saved as a named app
  md "%stub_root%\cwd" || exit 1
  >"%stub_root%\cwd\jdk8" type NUL
  pushd "%stub_root%\cwd"
  call "%SCOOP%\.portable\scoop.cmd" update scoop * >NUL 2>&1
  popd
  call :assert_file_exists "%versions%\jdk11.JAVA_HOME.env_set.cmd"
  call :assert_file_not_exists "%versions%\jdk8.JAVA_HOME.env_set.cmd"

  rd /S /Q "%stub_root%"
  endlocal
  echo ::endgroup::
goto :EOF


:assert_update_keeps_selected_jdk
  :: args: <UPDATE_ARG>
  :: expects the fixture of assert_update_refreshes_active_versions with jdk11 selected
  >"%stub_root%\apps\foo\current\manifest.json" echo {"version": "updated by %~1"}
  >"%stub_root%\apps\jdk8\current\manifest.json" echo {"version": "8 updated by %~1", "env_set": {"JAVA_HOME": "$dir"}}
  call "%SCOOP%\.portable\scoop.cmd" update %~1 >NUL 2>&1
  REM foo shows that the update was processed at all, so the JDK checks cannot pass by accident
  call :assert_same_file "%stub_root%\apps\foo\current\manifest.json" "%versions%\foo.json" "scoop update %~1"
  call :assert_same_file "%stub_root%\apps\jdk8\current\manifest.json" "%versions%\jdk8.json" "scoop update %~1"
  call :assert_file_exists "%versions%\jdk11.JAVA_HOME.env_set.cmd"
  call :assert_file_not_exists "%versions%\jdk8.JAVA_HOME.env_set.cmd"
goto :EOF


:assert_same_file
  :: args: <EXPECTED_FILE> <ACTUAL_FILE> <COMMAND>
  fc /B "%~1" "%~2" >NUL 2>&1 || (
    echo "ERROR: [%~2] does not match [%~1] after [%~3]!"
    exit 1
  )
goto :EOF


:assert_exit_code
  :: args: <EXPECTED> <COMMAND>
  if not "%errorlevel%" == "%~1" (
    echo "ERROR: Expected exit code %~1 from [%~2] but got %errorlevel%!"
    exit 1
  )
goto :EOF