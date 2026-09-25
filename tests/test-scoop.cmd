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


:assert_exit_code <EXPECTED> <COMMAND>
  if not "%errorlevel%" == "%~1" (
    echo "ERROR: Expected exit code %~1 from [%~2] but got %errorlevel%!"
    exit 1
  )
goto :EOF