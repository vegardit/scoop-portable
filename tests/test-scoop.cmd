@echo off
setlocal

:: https://superuser.com/questions/80485/exit-batch-file-from-subroutine
if not "%selfWrapped%"=="%~0" (
  REM this is necessary so that we can use "exit" to terminate the batch file,
  REM and all subroutines, but not the original cmd.exe
  set "selfWrapped=%~0"
  %ComSpec% /S /C ""%~0" %*"
  goto :EOF
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