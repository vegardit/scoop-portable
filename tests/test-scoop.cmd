@echo off
:: CI test: loads scoop-portable and checks the behavior of its scoop wrapper
:: (app installs, hook capture, environment refresh and recovery, active version tracking, java switching,
:: exit codes, patching of scoop,
:: argument forwarding, safe stash cleanup, and separate updates of scoop itself)
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

  :: assert scoop's PowerShell modules folder is on the module path of this session: scoop only
  :: adds it to the persistent PSModulePath, which scoop-portable prevents
  call eval powershell -noprofile -command "if (($env:PSModulePath -split ';') -notcontains ($env:SCOOP + '\modules')) { exit 1 }"

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

  :: assert scoop wrote no persistent user environment variables, e.g. JAVA_HOME of the JDKs
  :: above or the shims folder on PATH. scoop-portable sets them per session instead
  call assert-user-env-untouched

  :: assert the wrapper returns the exit code of install/reset/uninstall.
  :: uses a stub scoop because scoop itself exits with 0 when a subcommand fails
  call :assert_wrapper_exit_codes

  :: assert global installs are rejected without installing anything, also for upper case commands
  :: and options, and combined short options (-kg is -k -g), which scoop accepts, too.
  :: <NUL makes the error pause of exit_with_ERROR return immediately
  for %%a in ("install -g" "install --global" "install -G" "install --GLOBAL" "install -kg" "INSTALL -g") do (
    echo ::group::call scoop %%~a jq - expected to be rejected
    call scoop %%~a jq <NUL
    call :assert_exit_code 1 "scoop %%~a jq"
    call :assert_file_not_exists "%SCOOP%\globalApps\apps\jq"
    echo ::endgroup::
  )

  :: assert installing another scoop-portable is rejected while scoop is on PATH
  call :assert_install_rejected_when_scoop_on_path

  :: assert "scoop update" refreshes the saved versions of updated apps and new dependencies,
  :: and does not switch JAVA_HOME to a JDK that was not updated. Also asserts that reset,
  :: update and uninstall are handled in any case
  call :assert_update_refreshes_active_versions

  :: assert a failed patch fails the command and is retried, and a patch that no longer matches warns
  call :assert_patch_failures_are_reported

  :: assert scoop always starts with the patches applied: explicit updates must not revert them,
  :: and a lib patched by an older scoop-portable version is patched before any command runs
  call :assert_scoop_always_runs_patched

  :: assert scoop never updates itself within another command, but in a separate run before it
  call :assert_no_self_update_within_commands

  :: only verified portable patches may be discarded, including in the saved index
  call :assert_self_update_cleans_only_portable_stashes

  :: assert a missing scoop lib file warns, unless it is lib\system.ps1, which blocks all commands
  call :assert_missing_lib_files_are_handled

  :: assert loading adds scoop's PowerShell modules folder to PSModulePath once, also when
  :: loaded again, and leaves an undefined PSModulePath undefined
  call :assert_psmodulepath_of_session
  :: the installed architecture, including a forced 32bit install, determines the session settings
  call :assert_architecture_specific_env
  call :assert_env_files_are_refreshed
  :: exercise real Scoop helpers without allowing the fixture to write the registry
  call eval powershell -noprofile -ex unrestricted -file "%~dp0test-hook-environment.ps1" "%SCOOP%"
  :: each caller must report saving failures without abandoning the remaining app records
  for %%c in (update install reset import) do call :assert_env_save_failures_are_reported %%c
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
  REM a new folder per run that is left behind, see assert_patch_failures_are_reported
  set "stub_root=%TEMP%\scoop-portable-exit-code-test-%RANDOM%%RANDOM%"
  md "%stub_root%\shims" "%stub_root%\apps" "%stub_root%\.portable" || exit 1
  call :create_patched_stub_lib "%stub_root%"
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%stub_root%\.portable\scoop.cmd" >NUL || exit 1
  >"%stub_root%\shims\scoop.cmd" echo @exit /B 7
  set "SCOOP=%stub_root%"
  for %%c in (install reset uninstall) do (
    call "%SCOOP%\.portable\scoop.cmd" %%c some-app >NUL 2>&1
    call :assert_exit_code 7 "scoop %%c"
  )
  endlocal
  echo ::endgroup::
goto :EOF


:assert_install_rejected_when_scoop_on_path
  echo ::group::install a second scoop-portable while scoop is on PATH - expected to be rejected
  setlocal
  REM a new folder per run that is left behind, see assert_patch_failures_are_reported
  set "other_root=%TEMP%\scoop-portable-guard-test-%RANDOM%%RANDOM%"
  REM fail on setup errors, otherwise calling a missing wrapper would also count as the expected rejection
  md "%other_root%" || exit 1
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%other_root%\scoop-portable.cmd" >NUL || exit 1
  call "%other_root%\scoop-portable.cmd" <NUL
  call :assert_exit_code 1 "scoop-portable.cmd in [%other_root%]"
  REM .portable is created after the check, right before the installer is downloaded
  call :assert_file_not_exists "%other_root%\.portable"
  endlocal
  echo ::endgroup::
goto :EOF


:assert_update_refreshes_active_versions
  echo ::group::saved app versions after scoop update (stub scoop)
  setlocal
  REM a new folder per run that is left behind, see assert_patch_failures_are_reported
  set "stub_root=%TEMP%\scoop-portable-update-test-%RANDOM%%RANDOM%"
  set "versions=%stub_root%\.portable\active_versions"
  REM fail on setup errors, otherwise a broken fixture could satisfy some assertions
  md "%stub_root%\shims" "%stub_root%\.portable\scoop" || exit 1
  for %%a in (foo bar jdk8 jdk11) do md "%stub_root%\apps\%%a\current" || exit 1
  call :create_patched_stub_lib "%stub_root%"
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%stub_root%\.portable\scoop.cmd" >NUL || exit 1
  REM the stub scoop does nothing; the test changes the manifests itself like an update would.
  REM A last update that never gets outdated counts each update of scoop itself as successful
  >"%stub_root%\shims\scoop.cmd" echo @exit /B 0
  >"%stub_root%\.portable\scoop\config.json" echo {"last_update": "2099-01-01T00:00:00"}
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

  REM scoop accepts its commands in any case, so these must be handled like the lower case ones.
  REM Otherwise they would run as other commands, which save no versions: the JDK would not switch
  call "%SCOOP%\.portable\scoop.cmd" RESET jdk8 >NUL 2>&1
  call :assert_file_exists "%versions%\jdk8.JAVA_HOME.env_set.cmd"
  call :assert_file_not_exists "%versions%\jdk11.JAVA_HOME.env_set.cmd"
  call "%SCOOP%\.portable\scoop.cmd" UPDATE jdk11 >NUL 2>&1
  call :assert_file_exists "%versions%\jdk11.JAVA_HOME.env_set.cmd"
  call :assert_file_not_exists "%versions%\jdk8.JAVA_HOME.env_set.cmd"
  REM uninstall removes the saved versions of apps that are no longer installed, like gone
  >"%versions%\gone.json" echo {"version": "1"}
  call "%SCOOP%\.portable\scoop.cmd" UNINSTALL gone >NUL 2>&1
  call :assert_file_not_exists "%versions%\gone.json"

  REM "scoop import" installs the apps of a Scoopfile with scoop's own install script, not via
  REM this wrapper, so the wrapper must save the versions of the new apps afterwards. baz stands
  REM for such an app; it is last and has no JAVA_HOME, so the JDK checks above are not affected
  md "%stub_root%\apps\baz\current" || exit 1
  >"%stub_root%\apps\baz\current\manifest.json" echo {"version": "1"}
  call "%SCOOP%\.portable\scoop.cmd" import scoopfile.json >NUL 2>&1
  call :assert_exit_code 0 "scoop import scoopfile.json"
  call :assert_same_file "%stub_root%\apps\baz\current\manifest.json" "%versions%\baz.json" "scoop import scoopfile.json"
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


:assert_patch_failures_are_reported
  echo ::group::patch failures fail the command and are retried (stub scoop)
  setlocal
  REM a new folder per run that is left behind: no recursive delete based on a variable,
  REM which could remove the wrong folder if the variable were wrong or empty
  set "stub_root=%TEMP%\scoop-portable-patch-test-%RANDOM%%RANDOM%"
  set "lib=%stub_root%\apps\scoop\current\lib"
  REM fail on setup errors, otherwise a broken fixture could satisfy some assertions
  md "%stub_root%\shims" "%stub_root%\.portable" "%lib%" || exit 1
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%stub_root%\.portable\scoop.cmd" >NUL || exit 1
  >"%stub_root%\shims\scoop.cmd" echo @exit /B 0
  REM minimal lib files with the upstream code the patches look for. startmenu_shortcut is
  REM left out so that its patch no longer matches and must warn. The functions span two
  REM lines like upstream: a one-line definition would look like the appended patch itself
  >"%lib%\core.ps1" echo $configHome = $env:XDG_CONFIG_HOME
  >"%lib%\system.ps1" echo function Set-EnvVar {
  >>"%lib%\system.ps1" echo }
  >"%lib%\shortcuts.ps1" echo function create_startmenu_shortcuts($manifest, $dir, $global, $arch) {
  >>"%lib%\shortcuts.ps1" echo }
  >"%lib%\install.ps1" echo function Invoke-HookScript {
  >>"%lib%\install.ps1" echo }
  set "SCOOP=%stub_root%"

  REM a failing patch must fail an otherwise successful command and must not write the
  REM marker, so that the next command retries
  attrib +R "%lib%\core.ps1"
  call "%SCOOP%\.portable\scoop.cmd" list >NUL 2>&1
  call :assert_exit_code 1 "scoop list with a read-only lib\core.ps1"
  findstr /L /C:"# scoop-portable-patches:" "%lib%\system.ps1" >NUL && (
    echo "ERROR: The patch marker was written although patching failed!"
    exit 1
  )

  attrib -R "%lib%\core.ps1"
  REM stdout and stderr separately: the patch output must not end up in the command's own output
  call "%SCOOP%\.portable\scoop.cmd" list > "%stub_root%\stdout.log" 2> "%stub_root%\patch.log"
  call :assert_exit_code 0 "scoop list after lib\core.ps1 became writable"
  call :assert_log_lacks "%stub_root%\stdout.log" "Patching scoop"
  call :assert_log_lacks "%stub_root%\stdout.log" "WARNING"
  call :assert_log_contains "%stub_root%\patch.log" "Patching scoop"
  findstr /L /C:"# scoop-portable-patches:" "%lib%\system.ps1" >NUL || (
    echo "ERROR: The patch marker is missing after successful patching!"
    exit 1
  )
  findstr /L /C:".portable" "%lib%\core.ps1" >NUL || (
    echo "ERROR: lib\core.ps1 was not patched!"
    exit 1
  )
  REM check the specific warnings: a generic "WARNING:" check would also pass for other warnings.
  REM The searched texts are at the start of the warning, as PowerShell wraps long warnings at the
  REM console width
  call :assert_log_contains "%stub_root%\patch.log" "function startmenu_shortcut is no longer defined"
  call :assert_log_lacks "%stub_root%\patch.log" "Set-EnvVar is no longer defined"
  call :assert_file_exists "%SCOOP%\.portable\environment.ps1"
  call :assert_log_contains "%lib%\install.ps1" "environment.ps1"
  REM A retained marker must not prevent regenerating a missing helper.
  move "%SCOOP%\.portable\environment.ps1" "%stub_root%\saved-environment.ps1" >NUL || exit 1
  call "%SCOOP%\.portable\scoop.cmd" list >NUL 2>&1
  call :assert_exit_code 0 "scoop list with a missing portable helper"
  call :assert_same_file "%stub_root%\saved-environment.ps1" "%SCOOP%\.portable\environment.ps1" "regenerating the helper"
  endlocal
  echo ::endgroup::
goto :EOF


:assert_scoop_always_runs_patched
  echo ::group::scoop always starts with the patches applied (stub scoop)
  setlocal
  REM a new folder per run that is left behind, see assert_patch_failures_are_reported
  set "stub_root=%TEMP%\scoop-portable-patched-run-test-%RANDOM%%RANDOM%"
  set "lib=%stub_root%\apps\scoop\current\lib"
  REM fail on setup errors, otherwise a broken fixture could satisfy some assertions
  md "%stub_root%\shims" "%stub_root%\.portable\scoop" "%stub_root%\bin" "%stub_root%\apps\scoop\current\.git" || exit 1
  call :create_patched_stub_lib "%stub_root%"
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%stub_root%\.portable\scoop.cmd" >NUL || exit 1
  REM a last update that never gets outdated counts each update of scoop itself as successful
  >"%stub_root%\.portable\scoop\config.json" echo {"last_update": "2099-01-01T00:00:00"}
  REM the stub scoop logs each call and whether the patch marker was present at that time
  >"%stub_root%\shims\scoop.cmd" echo @findstr /L /C:"# scoop-portable-patches:" "%%~dp0..\apps\scoop\current\lib\system.ps1" ^>NUL ^&^& (echo patched: %%* ^>^>"%%~dp0..\calls.log") ^|^| (echo UNPATCHED: %%* ^>^>"%%~dp0..\calls.log")
  >>"%stub_root%\shims\scoop.cmd" echo @exit /B 0
  REM with the .git folder above, a stub git first on PATH reverts lib\system.ps1 like
  REM "git checkout" would, in case scoop-portable reverts its patches before an update
  >"%stub_root%\bin\git.cmd" echo @^>"%%~dp0..\apps\scoop\current\lib\system.ps1" echo function Set-EnvVar { }
  set "PATH=%stub_root%\bin;%PATH%"
  set "SCOOP=%stub_root%"

  REM a lib patched by an older scoop-portable version (no Set-EnvVar override and marker)
  REM must be patched before scoop runs, also for commands like reset that cannot replace scoop
  >"%lib%\system.ps1" echo function Set-EnvVar {
  >>"%lib%\system.ps1" echo }
  call "%SCOOP%\.portable\scoop.cmd" reset foo >NUL 2>&1

  REM explicit updates of scoop itself must not revert the patches before scoop runs.
  REM "" is a plain "scoop update", "scoop foo" updates scoop in a run of its own before foo
  for %%u in ("" "-a" "scoop foo") do call "%SCOOP%\.portable\scoop.cmd" update %%~u >NUL 2>&1

  REM scoop shows the help only for --help as the first argument after the command. Elsewhere
  REM the command really runs, e.g. "scoop config <name> --help" sets that value, which can
  REM write environment variables, so it must not skip the patching like a help request
  >"%lib%\system.ps1" echo function Set-EnvVar {
  >>"%lib%\system.ps1" echo }
  call "%SCOOP%\.portable\scoop.cmd" config foo --help >NUL 2>&1

  REM the logged calls show that the commands above reached scoop at all. The plain "update"
  REM runs are not checked: "patched: update" would also match the other update calls
  for %%c in ("reset foo" "update -a" "update foo" "config foo --help") do (
    findstr /L /C:"patched: %%~c" "%stub_root%\calls.log" >NUL || (
      echo "ERROR: scoop was not called with the patches applied for [scoop %%~c]!"
      exit 1
    )
  )
  findstr /L /C:"UNPATCHED:" "%stub_root%\calls.log" >NUL && (
    echo "ERROR: scoop ran without the patches:"
    type "%stub_root%\calls.log"
    exit 1
  )
  endlocal
  echo ::endgroup::
goto :EOF


:assert_no_self_update_within_commands
  echo ::group::scoop updates itself in a run of its own, not within other commands (stub scoop)
  setlocal
  REM a new folder per run that is left behind, see assert_patch_failures_are_reported
  set "stub_root=%TEMP%\scoop-portable-self-update-test-%RANDOM%%RANDOM%"
  REM fail on setup errors, otherwise a broken fixture could satisfy some assertions
  md "%stub_root%\shims" "%stub_root%\.portable\scoop" || exit 1
  call :create_patched_stub_lib "%stub_root%"
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%stub_root%\.portable\scoop.cmd" >NUL || exit 1
  REM the stub scoop logs each call to %STUB_LOG%: "self-update" for a plain "scoop update", which
  REM sets a last update that never gets outdated unless STUB_FAIL_UPDATE is set, "<args>" for
  REM "scoop config", and "OUTDATED: <args>" for other calls if scoop would update itself within
  REM them, else "fresh: <args>". Calls that do not get the expected XDG_CONFIG_HOME are logged to xdg.log.
  REM Like scoop, it uses %SCOOP%\config.json instead of the one in .portable if that exists
  >"%stub_root%\shims\scoop.cmd" (
    echo @echo off
    echo setlocal
    echo set "config=%%~dp0..\.portable\scoop\config.json"
    echo if exist "%%~dp0..\config.json" set "config=%%~dp0..\config.json"
    echo if /I "%%~1" == "update" if "%%~2" == "" goto :self_update
    echo if /I "%%~1" == "config" goto :config
    echo if not "%%XDG_CONFIG_HOME%%" == "user-xdg" ^>^>"%%~dp0..\xdg.log" echo %%*: XDG_CONFIG_HOME changed
    echo findstr /L /C:2099 "%%config%%" ^>NUL 2^>NUL ^&^& set "state=fresh" ^|^| set "state=OUTDATED"
    echo ^>^>"%%STUB_LOG%%" echo %%state%%: %%*
    echo exit /B 0
    echo :self_update
    echo if not "%%XDG_CONFIG_HOME%%" == "%%SCOOP%%\.portable" ^>^>"%%~dp0..\xdg.log" echo self-update without XDG_CONFIG_HOME
    echo ^>^>"%%STUB_LOG%%" echo self-update
    echo if defined STUB_FAIL_UPDATE exit /B 0
    echo ^>"%%config%%" echo {"last_update": "2099-01-01T00:00:00"}
    echo exit /B 0
    echo :config
    echo ^>^>"%%STUB_LOG%%" echo %%*
    echo exit /B 0
  )
  set "SCOOP=%stub_root%"
  set "XDG_CONFIG_HOME=user-xdg"
  set "STUB_FAIL_UPDATE="
  set "outdated=2000-01-01T00:00:00"
  set "up_to_date=2099-01-01T00:00:00"

  REM when outdated, scoop updates itself before the commands that would do so within them.
  REM "fresh:" shows that this happened before, as only that update changes the last update
  call :run_logged_scoop_command %outdated% "install foo"
  call :assert_exit_code 0 "scoop install foo"
  call :assert_log_contains "%STUB_LOG%" "fresh: install --no-update-scoop foo"
  REM set for each update of scoop itself only, as scoop cannot update itself without it, but
  REM must skip an update within another command
  call :assert_log_contains "%STUB_LOG%" "config autostash_on_conflict true"
  call :assert_log_contains "%STUB_LOG%" "config rm autostash_on_conflict"
  call :run_logged_scoop_command %outdated% "download foo"
  call :assert_log_contains "%STUB_LOG%" "fresh: download --no-update-scoop foo"
  call :run_logged_scoop_command %outdated% "virustotal foo"
  call :assert_log_contains "%STUB_LOG%" "fresh: virustotal --no-update-scoop foo"
  call :run_logged_scoop_command %outdated% "import foo.json"
  call :assert_log_contains "%STUB_LOG%" "fresh: import foo.json"
  call :run_logged_scoop_command %outdated% "update foo"
  call :assert_exit_code 0 "scoop update foo"
  call :assert_log_contains "%STUB_LOG%" "fresh: update foo"
  REM other commands do not update scoop
  call :run_logged_scoop_command %outdated% "list"
  call :assert_log_lacks "%STUB_LOG%" "self-update"
  call :assert_log_contains "%STUB_LOG%" "OUTDATED: list"
  REM scoop accepts commands and options in any case, so "INSTALL" and "--ALL" must count, too
  call :run_logged_scoop_command %outdated% "INSTALL foo"
  call :assert_log_contains "%STUB_LOG%" "fresh: INSTALL --no-update-scoop foo"
  call :run_logged_scoop_command %outdated% "update --ALL"
  call :assert_log_contains "%STUB_LOG%" "fresh: update --ALL"
  REM -u and --no-update-scoop keep scoop from updating itself at all, like in scoop itself.
  REM "OUTDATED:" shows that the command ran without an update of scoop before
  call :run_logged_scoop_command %outdated% "install foo -u"
  call :assert_log_lacks "%STUB_LOG%" "self-update"
  call :assert_log_contains "%STUB_LOG%" "OUTDATED: install --no-update-scoop foo -u"
  call :run_logged_scoop_command %outdated% "download foo --no-update-scoop"
  call :assert_log_lacks "%STUB_LOG%" "self-update"
  call :assert_log_contains "%STUB_LOG%" "OUTDATED: download --no-update-scoop foo --no-update-scoop"
  REM scoop also accepts combined short options: -ku includes -u, -qa includes -a (--all)
  call :run_logged_scoop_command %outdated% "install foo -ku"
  call :assert_log_lacks "%STUB_LOG%" "self-update"
  call :assert_log_contains "%STUB_LOG%" "OUTDATED: install --no-update-scoop foo -ku"
  call :run_logged_scoop_command %outdated% "update -qa"
  call :assert_log_contains "%STUB_LOG%" "fresh: update -qa"
  REM -h or --help as the first argument shows the help of the command, which must not update
  REM scoop first
  call :run_logged_scoop_command %outdated% "install -h"
  call :assert_log_lacks "%STUB_LOG%" "self-update"
  call :assert_log_contains "%STUB_LOG%" "OUTDATED: install -h"
  call :run_logged_scoop_command %outdated% "download --help"
  call :assert_log_lacks "%STUB_LOG%" "self-update"
  call :assert_log_contains "%STUB_LOG%" "OUTDATED: download --help"

  REM getopt treats everything after -- as an app, so the forced option must precede it.
  REM Use a subroutine so each assertion reads the log variable set by that command.
  for %%c in (install download virustotal) do call :assert_argument_separator_is_preserved %%c

  REM Use the stub for this bypass regression: an unfixed wrapper must not install globally.
  set "STUB_LOG=%stub_root%\quoted-global-install.log"
  >NUL 2>&1 call "%SCOOP%\.portable\scoop.cmd" "InStAlL" -kG foo <NUL
  call :assert_exit_code 1 "quoted global install"
  call :assert_file_not_exists "%STUB_LOG%"

  REM A quoted import must still run the separate self-update before executing the Scoopfile.
  >"%SCOOP%\.portable\scoop\config.json" echo {"last_update": "%outdated%"}
  set "STUB_LOG=%stub_root%\quoted-import.log"
  >NUL 2>&1 call "%SCOOP%\.portable\scoop.cmd" "ImPoRt" foo.json
  call :assert_exit_code 0 "quoted import"
  call :assert_log_contains "%STUB_LOG%" "self-update"
  call :assert_log_lacks "%STUB_LOG%" "OUTDATED:"
  findstr /B /L /C:"fresh:" "%STUB_LOG%" >"%stub_root%\forwarded-args.log"
  >"%stub_root%\expected-args.log" echo fresh: "ImPoRt" foo.json
  call :assert_same_file "%stub_root%\expected-args.log" "%stub_root%\forwarded-args.log" "quoted import arguments"

  REM when up to date, scoop only updates itself before the apps if it is named, and is then
  REM removed from the apps, as scoop would otherwise update itself within their update again
  call :run_logged_scoop_command %up_to_date% "update foo"
  call :assert_log_lacks "%STUB_LOG%" "self-update"
  call :assert_log_contains "%STUB_LOG%" "fresh: update foo"
  call :run_logged_scoop_command %up_to_date% "update scoop foo"
  call :assert_log_contains "%STUB_LOG%" "self-update"
  call :assert_log_contains "%STUB_LOG%" "fresh: update foo"
  call :assert_log_lacks "%STUB_LOG%" "scoop foo"
  call :run_logged_scoop_command %up_to_date% "update scoop"
  call :assert_log_contains "%STUB_LOG%" "self-update"
  call :assert_log_lacks "%STUB_LOG%" ": update"
  REM a repeated "scoop" is removed completely, too
  call :run_logged_scoop_command %up_to_date% "update scoop scoop foo"
  call :assert_log_contains "%STUB_LOG%" "self-update"
  call :assert_log_contains "%STUB_LOG%" "fresh: update foo"
  call :assert_log_lacks "%STUB_LOG%" "update scoop"
  REM with "scoop" as the only app, the options are not passed on: scoop rejects e.g.
  REM --no-cache when it only updates itself, but not with "scoop" as an app
  call :run_logged_scoop_command %up_to_date% "update scoop -k"
  call :assert_log_contains "%STUB_LOG%" "self-update"
  call :assert_log_lacks "%STUB_LOG%" "-k"

  call :assert_scoop_update_targets_are_filtered

  REM if scoop cannot update itself, an installation continues like in scoop itself, still
  REM without an update within it. App updates and imports are skipped, as scoop would try to
  REM update itself within them again
  set "STUB_FAIL_UPDATE=true"
  call :run_logged_scoop_command %outdated% "install foo"
  call :assert_exit_code 0 "scoop install foo after scoop could not update itself"
  call :assert_log_contains "%STUB_LOG%" "OUTDATED: install --no-update-scoop foo"
  call :run_logged_scoop_command %outdated% "update foo"
  call :assert_exit_code 1 "scoop update foo after scoop could not update itself"
  call :assert_log_lacks "%STUB_LOG%" "OUTDATED:"
  call :run_logged_scoop_command %outdated% "import foo.json"
  call :assert_exit_code 1 "scoop import foo.json after scoop could not update itself"
  call :assert_log_lacks "%STUB_LOG%" "OUTDATED:"
  REM scoop itself exits with 0 then
  call :run_logged_scoop_command %outdated% "update"
  call :assert_exit_code 1 "scoop update when scoop could not update itself"
  call :assert_log_contains "%STUB_LOG%" "self-update"
  set "STUB_FAIL_UPDATE="

  REM like scoop, the last update is read from %SCOOP%\config.json instead of the one in
  REM .portable if that exists. Tested last, because the file is left behind: the tests
  REM delete nothing, so it is overwritten between the two cases
  >"%stub_root%\config.json" echo {"last_update": "%up_to_date%"}
  call :run_logged_scoop_command %outdated% "update foo"
  call :assert_exit_code 0 "scoop update foo with an up to date root config.json"
  call :assert_log_lacks "%STUB_LOG%" "self-update"
  call :assert_log_contains "%STUB_LOG%" "fresh: update foo"
  REM the reverse case would let scoop update itself within the app update
  >"%stub_root%\config.json" echo {"last_update": "%outdated%"}
  call :run_logged_scoop_command %up_to_date% "update foo"
  call :assert_exit_code 0 "scoop update foo with an outdated root config.json"
  call :assert_log_contains "%STUB_LOG%" "self-update"
  call :assert_log_contains "%STUB_LOG%" "fresh: update foo"

  REM only the runs that update scoop itself get the XDG_CONFIG_HOME of scoop-portable
  call :assert_file_not_exists "%stub_root%\xdg.log"
  endlocal
  echo ::endgroup::
goto :EOF


:run_logged_scoop_command
  :: args: <LAST_UPDATE> <SCOOP_ARGS>
  :: runs the wrapper in the fixture of assert_no_self_update_within_commands with the given
  :: last update of scoop, logging the stub scoop calls to a new %STUB_LOG%.
  :: The exit code is the one of the wrapper
  set /A log_count+=1
  set "STUB_LOG=%stub_root%\calls-%log_count%.log"
  >"%SCOOP%\.portable\scoop\config.json" echo {"last_update": "%~1"}
  REM Leading redirection keeps its separator spaces out of the arguments captured by the stub.
  >NUL 2>&1 call "%SCOOP%\.portable\scoop.cmd" %~2
goto :EOF


:assert_argument_separator_is_preserved
  :: args: <SCOOP_COMMAND>
  :: uses the fixture of assert_no_self_update_within_commands. Compare the entire forwarded
  :: command so an extra option after -- cannot pass by matching only a correct prefix.
  call :run_logged_scoop_command %up_to_date% "%~1 -- foo"
  call :assert_exit_code 0 "scoop %~1 -- foo"
  >"%stub_root%\expected-args.log" echo fresh: %~1 --no-update-scoop -- foo
  call :assert_same_file "%stub_root%\expected-args.log" "%STUB_LOG%" "scoop %~1 -- foo"

  REM Call directly to preserve the inner quotes, which the string argument of the logging
  REM helper cannot represent. Spaces and ampersands must stay inside one quoted manifest name.
  set "STUB_LOG=%stub_root%\quoted-%~1.log"
  >NUL 2>&1 call "%SCOOP%\.portable\scoop.cmd" %~1 -- "app & tools.json"
  call :assert_exit_code 0 "scoop %~1 with a quoted manifest"
  >"%stub_root%\expected-args.log" echo fresh: %~1 --no-update-scoop -- "app & tools.json"
  call :assert_same_file "%stub_root%\expected-args.log" "%STUB_LOG%" "scoop %~1 with a quoted manifest"

  REM Quoting the command must not bypass its safeguards or alter the forwarded arguments.
  set "STUB_LOG=%stub_root%\quoted-command-%~1.log"
  >NUL 2>&1 call "%SCOOP%\.portable\scoop.cmd" "%~1" -- "app & tools.json"
  call :assert_exit_code 0 "quoted scoop %~1"
  >"%stub_root%\expected-args.log" echo fresh: "%~1" --no-update-scoop -- "app & tools.json"
  call :assert_same_file "%stub_root%\expected-args.log" "%STUB_LOG%" "quoted scoop %~1"
goto :EOF


:assert_scoop_update_targets_are_filtered
  :: uses the self-update fixture; a recent timestamp must not suppress an explicit update
  >"%SCOOP%\.portable\scoop\config.json" echo {"last_update": "%up_to_date%"}
  set "STUB_LOG=%stub_root%\quoted-update-target.log"
  >NUL 2>&1 call "%SCOOP%\.portable\scoop.cmd" update "ScOoP"
  call :assert_exit_code 0 "update with only a quoted scoop target"
  >"%stub_root%\expected-update.log" echo self-update
  findstr /X /L /C:"self-update" "%STUB_LOG%" >"%stub_root%\actual-updates.log"
  call :assert_same_file "%stub_root%\expected-update.log" "%stub_root%\actual-updates.log" "exactly one quoted self-update"
  call :assert_log_lacks "%STUB_LOG%" "fresh:"

  REM Exact comparison catches both a second self-update and changes inside another argument.
  REM The wildcard also prevents named-app tracking from expanding fixture-directory file names.
  set "STUB_LOG=%stub_root%\mixed-update-targets.log"
  >NUL 2>&1 call "%SCOOP%\.portable\scoop.cmd" "UpDaTe" "scoop" scoop scoop scoop scoop -k -- "app & scoop tools.json" "" "*" "ScOoP" bar
  call :assert_exit_code 0 "update with mixed quoted and repeated scoop targets"
  findstr /X /L /C:"self-update" "%STUB_LOG%" >"%stub_root%\actual-updates.log"
  call :assert_same_file "%stub_root%\expected-update.log" "%stub_root%\actual-updates.log" "exactly one self-update for repeated targets"
  findstr /B /L /C:"fresh:" "%STUB_LOG%" >"%stub_root%\forwarded-args.log"
  >"%stub_root%\expected-args.log" echo fresh: "UpDaTe" -k -- "app & scoop tools.json" "" "*" bar
  call :assert_same_file "%stub_root%\expected-args.log" "%stub_root%\forwarded-args.log" "filtered app update"
goto :EOF


:assert_self_update_cleans_only_portable_stashes
  echo ::group::self-updates clean only portable stashes (stub scoop, real git)
  setlocal
  REM a new folder per run that is left behind, see assert_patch_failures_are_reported
  set "stub_root=%TEMP%\scoop-portable-stash-test-%RANDOM%%RANDOM%"
  set "repo=%stub_root%\apps\scoop\current"
  REM with an identity for the commits of the fixture, as CI may have none configured
  set "fixture_git=git -C "%repo%" -c user.name=scoop-portable-test -c user.email=test@example.invalid"
  REM fail on setup errors, otherwise a broken fixture could satisfy some assertions
  md "%stub_root%\shims" "%stub_root%\.portable\scoop" "%repo%\lib" || exit 1
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%stub_root%\.portable\scoop.cmd" >NUL || exit 1
  REM the stub scoop takes each call for a successful update of scoop itself
  >"%stub_root%\shims\scoop.cmd" echo @^>"%%~dp0..\.portable\scoop\config.json" echo {"last_update": "2099-01-01T00:00:00"}
  REM Start with upstream-shaped files and use the actual wrapper to generate patches.
  REM Fake "# patched" comments cannot prove that cleanup recognizes its own changes.
  >"%repo%\.gitattributes" echo * text eol=crlf
  >"%repo%\lib\core.ps1" echo $configHome = $env:XDG_CONFIG_HOME
  >"%repo%\lib\shortcuts.ps1" echo function create_startmenu_shortcuts($manifest, $dir, $global, $arch) {
  >>"%repo%\lib\shortcuts.ps1" echo }
  >>"%repo%\lib\shortcuts.ps1" echo function startmenu_shortcut([System.IO.FileInfo] $target, $shortcutName, $arguments, [System.IO.FileInfo]$icon, $global) {
  >>"%repo%\lib\shortcuts.ps1" echo }
  >"%repo%\lib\system.ps1" echo function Set-EnvVar {
  >>"%repo%\lib\system.ps1" echo }
  >"%repo%\lib\install.ps1" echo function Invoke-HookScript {
  >>"%repo%\lib\install.ps1" echo }
  >"%repo%\README.md" echo readme
  %fixture_git% init -q || exit 1
  %fixture_git% add .gitattributes lib README.md || exit 1
  %fixture_git% commit -q -m upstream || exit 1
  set "SCOOP=%stub_root%"

  REM Keep unrecognized legacy edits even in a file older wrapper versions patched.
  >>"%repo%\lib\install.ps1" echo # unrecognized legacy change
  %fixture_git% stash push -q -u -m "WIP at 2026-01-01T00:00:00.0000000+00:00" || exit 1
  REM An explicit user stash is kept even if its contents are entirely portable patches.
  call "%SCOOP%\.portable\scoop.cmd" list >NUL 2>&1
  call :assert_exit_code 0 "patch the stash fixture"
  %fixture_git% stash push -q -u -m "my own work" || exit 1
  >>"%repo%\lib\core.ps1" echo # changed by the user inside a patched library
  %fixture_git% stash push -q -u -m "WIP at 2026-01-02T00:00:00.0000000+00:00" || exit 1

  REM Interleave removable entries with protected ones to exercise stash index changes.
  call "%SCOOP%\.portable\scoop.cmd" list >NUL 2>&1
  call :assert_exit_code 0 "patch the stash fixture"
  %fixture_git% stash push -q -u -m "WIP at 2026-02-01T00:00:00.0000000+00:00" || exit 1

  REM Untracked files must survive, even at a path an older wrapper used to patch.
  call "%SCOOP%\.portable\scoop.cmd" list >NUL 2>&1
  call :assert_exit_code 0 "patch the stash fixture"
  >"%repo%\lib\psmodules.ps1" echo # untracked work of the user
  %fixture_git% stash push -q -u -m "WIP at 2026-01-03T00:00:00.0000000+00:00" || exit 1
  REM The working copy contains only generated patches, but the saved index has user work
  REM in the same patched library. Checking only "stash show" would lose that work.
  call "%SCOOP%\.portable\scoop.cmd" list >NUL 2>&1
  call :assert_exit_code 0 "patch the stash fixture"
  copy /Y "%repo%\lib\core.ps1" "%stub_root%\portable-core.ps1" >NUL || exit 1
  >>"%repo%\lib\core.ps1" echo # staged by the user
  %fixture_git% add lib/core.ps1 || exit 1
  copy /Y "%stub_root%\portable-core.ps1" "%repo%\lib\core.ps1" >NUL || exit 1
  %fixture_git% stash push -q -u -m "WIP at 2026-01-04T00:00:00.0000000+00:00" || exit 1
  call "%SCOOP%\.portable\scoop.cmd" list >NUL 2>&1
  call :assert_exit_code 0 "patch the stash fixture"
  >>"%repo%\lib\core.ps1" echo # user work mixed with portable patches
  %fixture_git% stash push -q -u -m "WIP at 2026-01-05T00:00:00.0000000+00:00" || exit 1
  REM The new hook-load patch does not make other edits in install.ps1 disposable.
  call "%SCOOP%\.portable\scoop.cmd" list >NUL 2>&1
  call :assert_exit_code 0 "patch the stash fixture"
  >>"%repo%\lib\install.ps1" echo # user hook customization
  %fixture_git% stash push -q -u -m "WIP at 2026-01-07T00:00:00.0000000+00:00" || exit 1
  REM PowerShell's normal string equality ignores case, but saved user edits must not be ignored.
  call "%SCOOP%\.portable\scoop.cmd" list >NUL 2>&1
  call :assert_exit_code 0 "patch the stash fixture"
  >"%repo%\lib\core.ps1" echo $confighome = "$env:SCOOP\.portable"
  %fixture_git% stash push -q -u -m "WIP at 2026-01-06T00:00:00.0000000+00:00" || exit 1

  REM Generated patches are removable when staged, too.
  call "%SCOOP%\.portable\scoop.cmd" list >NUL 2>&1
  call :assert_exit_code 0 "patch the stash fixture"
  %fixture_git% add lib || exit 1
  %fixture_git% stash push -q -u -m "WIP at 2026-02-02T00:00:00.0000000+00:00" || exit 1
  REM Each stash must be checked against its own base, not the upstream revision just pulled.
  >>"%repo%\lib\core.ps1" echo # next upstream revision
  %fixture_git% add lib/core.ps1 || exit 1
  %fixture_git% commit -q -m next-upstream || exit 1

  REM Compare object IDs as well as messages: retaining just an entry's name is not enough
  REM to prove its saved working copy, index and untracked files remain recoverable.
  %fixture_git% stash list --format="%%H %%gs" > "%stub_root%\all-stashes.log" || exit 1
  call :assert_log_contains "%stub_root%\all-stashes.log" "WIP at 2026-02-01"
  call :assert_log_contains "%stub_root%\all-stashes.log" "WIP at 2026-02-02"
  findstr /V /C:"WIP at 2026-02-" "%stub_root%\all-stashes.log" > "%stub_root%\stashes-before.log" || exit 1
  call "%SCOOP%\.portable\scoop.cmd" update >NUL 2>&1
  call :assert_exit_code 0 "scoop update"
  %fixture_git% stash list --format="%%H %%gs" > "%stub_root%\stashes-after.log" || exit 1
  call :assert_same_file "%stub_root%\stashes-before.log" "%stub_root%\stashes-after.log" "scoop update"
  endlocal
  echo ::endgroup::
goto :EOF


:assert_missing_lib_files_are_handled
  echo ::group::missing scoop lib files (stub scoop)
  setlocal
  REM a new folder per run that is left behind, see assert_patch_failures_are_reported
  set "stub_root=%TEMP%\scoop-portable-missing-lib-test-%RANDOM%%RANDOM%"
  set "lib=%stub_root%\apps\scoop\current\lib"
  REM fail on setup errors, otherwise a broken fixture could satisfy some assertions
  md "%stub_root%\shims" "%stub_root%\.portable" "%lib%" || exit 1
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%stub_root%\.portable\scoop.cmd" >NUL || exit 1
  >"%stub_root%\shims\scoop.cmd" echo @exit /B 0
  set "SCOOP=%stub_root%"

  REM without lib\system.ps1, scoop cannot be patched, so no command may run
  call "%SCOOP%\.portable\scoop.cmd" list >NUL 2>"%stub_root%\no-system.log"
  call :assert_exit_code 1 "scoop list without lib\system.ps1"
  call :assert_log_contains "%stub_root%\no-system.log" "system.ps1 is missing"
  REM scoop older than 0.4.0 has no lib\system.ps1, so the error names how to update it
  call :assert_log_contains "%stub_root%\no-system.log" "older than 0.4.0"

  REM a missing lib\core.ps1 or lib\shortcuts.ps1 only warns, as retrying would not help
  >"%lib%\system.ps1" echo function Set-EnvVar {
  >>"%lib%\system.ps1" echo }
  call "%SCOOP%\.portable\scoop.cmd" list >NUL 2>"%stub_root%\no-core.log"
  call :assert_exit_code 0 "scoop list without lib\core.ps1 and lib\shortcuts.ps1"
  call :assert_log_contains "%stub_root%\no-core.log" "core.ps1 is missing"
  call :assert_log_contains "%stub_root%\no-core.log" "shortcuts.ps1 is missing"
  findstr /L /C:"# scoop-portable-patches:" "%lib%\system.ps1" >NUL || (
    echo "ERROR: The patch marker is missing although only lib\core.ps1 and lib\shortcuts.ps1 are missing!"
    exit 1
  )
  endlocal
  echo ::endgroup::
goto :EOF


:assert_psmodulepath_of_session
  echo ::group::PSModulePath of a loaded session (stub scoop)
  setlocal
  REM a new folder per run that is left behind, see assert_patch_failures_are_reported
  set "stub_root=%TEMP%\scoop-portable-psmodulepath-test-%RANDOM%%RANDOM%"
  REM fail on setup errors, otherwise a broken fixture could satisfy some assertions
  md "%stub_root%\shims" "%stub_root%\.portable" || exit 1
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%stub_root%\scoop-portable.cmd" >NUL || exit 1
  >"%stub_root%\shims\scoop.cmd" echo @exit /B 0
  REM loading as the user who loaded it last skips granting file permissions on the folder
  >"%stub_root%\.portable\last.user" echo %USERDOMAIN%\%USERNAME%

  REM loaded twice, the modules folder is on PSModulePath once, in front of the existing entries.
  REM Compared with the SCOOP value that loading sets, as it may spell the folder differently
  set "PSModulePath=C:\existing\modules"
  call "%stub_root%\scoop-portable.cmd" >NUL
  call "%stub_root%\scoop-portable.cmd" >NUL
  if not "%PSModulePath%" == "%SCOOP%\modules;C:\existing\modules" (
    echo "ERROR: Unexpected PSModulePath after loading twice: [%PSModulePath%]"
    exit 1
  )

  REM An ampersand is legal in a directory name. Neither CALL expansion in the shared
  REM replacement helper may treat it as a command separator, including when removing a duplicate.
  set "PSModulePath=C:\R&D\Modules;C:\existing\modules"
  call "%stub_root%\scoop-portable.cmd" >NUL
  call "%stub_root%\scoop-portable.cmd" >NUL
  if not "%PSModulePath%" == "%SCOOP%\modules;C:\R&D\Modules;C:\existing\modules" (
    echo "ERROR: PSModulePath lost a literal directory name: [%PSModulePath%]"
    exit 1
  )

  REM an undefined PSModulePath stays undefined, as a new one would hide the default folders of
  REM Windows PowerShell, which it only uses without the variable
  set "PSModulePath="
  call "%stub_root%\scoop-portable.cmd" >NUL
  if defined PSModulePath (
    echo "ERROR: The undefined PSModulePath is [%PSModulePath%] after loading!"
    exit 1
  )
  endlocal
  echo ::endgroup::
goto :EOF


:assert_architecture_specific_env
  echo ::group::architecture-specific session environment (stub scoop)
  setlocal
  REM a new folder per run that is left behind, see assert_patch_failures_are_reported
  set "stub_root=%TEMP%\scoop-portable-architecture-test-%RANDOM%%RANDOM%"
  set "versions=%stub_root%\.portable\active_versions"
  md "%stub_root%\shims" "%stub_root%\.portable\scoop" "%versions%" || exit 1
  for %%a in (arch32 arch64 fallback32 fallback64 jdk8 jdk11) do md "%stub_root%\apps\%%a\current" || exit 1
  call :create_patched_stub_lib "%stub_root%"
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%stub_root%\.portable\scoop.cmd" >NUL || exit 1
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%stub_root%\scoop-portable.cmd" >NUL || exit 1
  >"%stub_root%\shims\scoop.cmd" echo @exit /B 0
  >"%stub_root%\.portable\scoop\config.json" echo {"last_update": "2099-01-01T00:00:00"}
  >"%stub_root%\.portable\last.user" echo %USERDOMAIN%\%USERNAME%
  set "SCOOP=%stub_root%"

  REM Test both installed architectures so choosing the host architecture cannot pass.
  REM Each architecture overrides a whole property: generic variables and extra PATH entries
  REM must not leak into the 32bit selection, while the empty 64bit PATH list uses the generic one.
  >"%SCOOP%\apps\arch32\current\manifest.json" echo {"version":"1","env_set":{"PORTABLE_TEST_GENERIC":"generic"},"env_add_path":["generic-bin","generic-tools"],"architecture":{"32bit":{"env_set":{"PORTABLE_TEST_ARCH":"32bit","PORTABLE_TEST_ROOT":"$dir","PORTABLE_TEST_PERSIST":"$persist_dir"},"env_add_path":"x86"},"64bit":{"env_set":{"PORTABLE_TEST_ARCH":"64bit"},"env_add_path":[]}}}
  copy /Y "%SCOOP%\apps\arch32\current\manifest.json" "%SCOOP%\apps\arch64\current\manifest.json" >NUL || exit 1
  >"%SCOOP%\apps\arch32\current\install.json" echo {"architecture":"32bit"}
  >"%SCOOP%\apps\arch64\current\install.json" echo {"architecture":"64bit"}
  REM Seed the generic outputs of an older wrapper. Starting empty would miss stale files
  REM surviving a whole-property architecture override.
  for %%a in (arch32 arch64) do (
    >"%versions%\%%a.PORTABLE_TEST_GENERIC.env_set.cmd" echo @set PORTABLE_TEST_GENERIC=generic
    >"%versions%\%%a.1.env_add_path" echo generic-bin
    >"%versions%\%%a.2.env_add_path" echo generic-tools
  )
  call "%SCOOP%\.portable\scoop.cmd" reset arch32 >NUL 2>&1
  call :assert_exit_code 0 "reset with 32bit environment settings"
  call :assert_file_not_exists "%versions%\arch32.PORTABLE_TEST_GENERIC.env_set.cmd"
  call :assert_file_not_exists "%versions%\arch32.2.env_add_path"
  >"%stub_root%\expected-path.txt" echo x86
  call :assert_same_file "%stub_root%\expected-path.txt" "%versions%\arch32.1.env_add_path" "32bit PATH selection"
  call :assert_same_file "%SCOOP%\apps\arch32\current\manifest.json" "%versions%\arch32.json" "preserve the original manifest"

  REM Clear inherited values before loading again: only the saved session files can restore them,
  REM because the stub never publishes environment changes to the registry.
  set "PORTABLE_TEST_ARCH="
  set "PORTABLE_TEST_ROOT="
  set "PORTABLE_TEST_PERSIST="
  call "%stub_root%\scoop-portable.cmd" >NUL
  if not "%PORTABLE_TEST_ARCH%" == "32bit" (
    echo "ERROR: The installed 32bit architecture was not restored!"
    exit 1
  )
  if not "%PORTABLE_TEST_ROOT%" == "%SCOOP%\apps\arch32\current" (
    echo "ERROR: The architecture-specific app directory was not expanded!"
    exit 1
  )
  if not "%PORTABLE_TEST_PERSIST%" == "%SCOOP%\persist\arch32" (
    echo "ERROR: The architecture-specific persist directory was not expanded!"
    exit 1
  )
  powershell -noprofile -command "if (($env:PATH -split ';') -notcontains ($env:SCOOP + '\apps\arch32\current\x86')) { exit 1 }" || exit 1

  call "%SCOOP%\.portable\scoop.cmd" reset arch64 >NUL 2>&1
  call :assert_exit_code 0 "reset with 64bit environment settings"
  call :assert_log_contains "%versions%\arch64.PORTABLE_TEST_ARCH.env_set.cmd" "64bit"
  call :assert_file_not_exists "%versions%\arch64.PORTABLE_TEST_GENERIC.env_set.cmd"
  >"%stub_root%\expected-path.txt" echo generic-bin
  call :assert_same_file "%stub_root%\expected-path.txt" "%versions%\arch64.1.env_add_path" "generic PATH fallback"
  >"%stub_root%\expected-path.txt" echo generic-tools
  call :assert_same_file "%stub_root%\expected-path.txt" "%versions%\arch64.2.env_add_path" "complete generic PATH fallback"

  REM Scoop falls back for both a missing architecture branch and empty property values.
  for %%a in (fallback32 fallback64) do >"%SCOOP%\apps\%%a\current\manifest.json" echo {"version":"1","env_set":{"PORTABLE_TEST_FALLBACK":"generic"},"env_add_path":"generic-bin","architecture":{"64bit":{"env_set":null,"env_add_path":[]}}}
  >"%SCOOP%\apps\fallback32\current\install.json" echo {"architecture":"32bit"}
  >"%SCOOP%\apps\fallback64\current\install.json" echo {"architecture":"64bit"}
  >"%stub_root%\expected-path.txt" echo generic-bin
  for %%a in (fallback32 fallback64) do (
    call "%SCOOP%\.portable\scoop.cmd" reset %%a >NUL 2>&1
    call :assert_exit_code 0 "reset with generic environment settings"
    call :assert_log_contains "%versions%\%%a.PORTABLE_TEST_FALLBACK.env_set.cmd" "generic"
    call :assert_same_file "%stub_root%\expected-path.txt" "%versions%\%%a.1.env_add_path" "generic architecture fallback"
  )

  REM JAVA_HOME must be selected before the existing JDK guard runs, or updating an unselected
  REM architecture-specific JDK would steal the selection from the user's chosen JDK.
  for %%a in (jdk8 jdk11) do (
    >"%SCOOP%\apps\%%a\current\manifest.json" echo {"version":"1","architecture":{"32bit":{"env_set":{"JAVA_HOME":"$dir"},"env_add_path":"bin"}}}
    >"%SCOOP%\apps\%%a\current\install.json" echo {"architecture":"32bit"}
  )
  call "%SCOOP%\.portable\scoop.cmd" reset jdk8 jdk11 >NUL 2>&1
  call :assert_file_exists "%versions%\jdk11.JAVA_HOME.env_set.cmd"
  >"%SCOOP%\apps\jdk8\current\manifest.json" echo {"version":"2","architecture":{"32bit":{"env_set":{"JAVA_HOME":"$dir"},"env_add_path":"bin"}}}
  call "%SCOOP%\.portable\scoop.cmd" update --all >NUL 2>&1
  call :assert_exit_code 0 "update with an unselected architecture-specific JDK"
  call :assert_same_file "%SCOOP%\apps\jdk8\current\manifest.json" "%versions%\jdk8.json" "refresh the unselected JDK manifest"
  call :assert_file_exists "%versions%\jdk11.JAVA_HOME.env_set.cmd"
  call :assert_file_not_exists "%versions%\jdk8.JAVA_HOME.env_set.cmd"
  call "%SCOOP%\.portable\scoop.cmd" reset jdk8 >NUL 2>&1
  call :assert_file_exists "%versions%\jdk8.JAVA_HOME.env_set.cmd"
  call :assert_file_not_exists "%versions%\jdk11.JAVA_HOME.env_set.cmd"
  endlocal
  echo ::endgroup::
goto :EOF


:assert_env_files_are_refreshed
  echo ::group::obsolete generated environment files are removed (stub scoop)
  setlocal
  REM a new folder per run that is left behind, see assert_patch_failures_are_reported
  set "stub_root=%TEMP%\scoop-portable-env-refresh-test-%RANDOM%%RANDOM%"
  set "versions=%stub_root%\.portable\active_versions"
  md "%stub_root%\shims" "%stub_root%\.portable\scoop" || exit 1
  for %%a in (foo foo.extra) do md "%stub_root%\apps\%%a\current" || exit 1
  call :create_patched_stub_lib "%stub_root%"
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%stub_root%\.portable\scoop.cmd" >NUL || exit 1
  >"%stub_root%\shims\scoop.cmd" echo @exit /B 0
  >"%stub_root%\.portable\scoop\config.json" echo {"last_update": "2099-01-01T00:00:00"}
  set "SCOOP=%stub_root%"
  >"%SCOOP%\apps\foo\current\manifest.json" echo {"version":"1","env_set":{"PORTABLE_TEST_KEPT":"old","PORTABLE_TEST_REMOVED":"old"},"env_add_path":["bin","tools"]}
  REM Scoop allows dots in app names: pruning foo.* must not remove foo.extra's files.
  >"%SCOOP%\apps\foo.extra\current\manifest.json" echo {"version":"1","env_set":{"PORTABLE_TEST_OTHER":"other"}}
  call "%SCOOP%\.portable\scoop.cmd" reset foo foo.extra >NUL 2>&1
  call :assert_exit_code 0 "initial environment files"
  copy /Y "%versions%\foo.extra.PORTABLE_TEST_OTHER.env_set.cmd" "%stub_root%\other-env.cmd" >NUL || exit 1

  >"%SCOOP%\apps\foo\current\manifest.json" echo {"version":"2","env_set":{"PORTABLE_TEST_KEPT":"new"},"env_add_path":["new-bin"]}
  call "%SCOOP%\.portable\scoop.cmd" update foo >NUL 2>&1
  call :assert_exit_code 0 "refresh with removed environment entries"
  call :assert_file_not_exists "%versions%\foo.PORTABLE_TEST_REMOVED.env_set.cmd"
  call :assert_file_not_exists "%versions%\foo.2.env_add_path"
  call :assert_log_contains "%versions%\foo.PORTABLE_TEST_KEPT.env_set.cmd" "PORTABLE_TEST_KEPT=new"
  >"%stub_root%\expected-path.txt" echo new-bin
  call :assert_same_file "%stub_root%\expected-path.txt" "%versions%\foo.1.env_add_path" "shortened PATH list"
  copy /Y "%versions%\foo.PORTABLE_TEST_KEPT.env_set.cmd" "%stub_root%\kept-env.cmd" >NUL || exit 1

  REM Failed parsing or rendering must not erase or partially replace working environment files.
  >"%SCOOP%\apps\foo\current\manifest.json" echo {"env_set":
  call "%SCOOP%\.portable\scoop.cmd" reset foo >NUL 2>&1
  call :assert_exit_code 1 "invalid manifest"
  call :assert_same_file "%stub_root%\kept-env.cmd" "%versions%\foo.PORTABLE_TEST_KEPT.env_set.cmd" "failed manifest parsing"
  >"%SCOOP%\apps\foo\current\manifest.json" echo {"version":"3","env_set":{"PORTABLE_TEST_KEPT":"must-not-be-written","PORTABLE_TEST_INVALID":null}}
  call "%SCOOP%\.portable\scoop.cmd" reset foo >NUL 2>&1
  call :assert_exit_code 1 "invalid environment value"
  call :assert_same_file "%stub_root%\kept-env.cmd" "%versions%\foo.PORTABLE_TEST_KEPT.env_set.cmd" "failed environment rendering"
  call :assert_same_file "%stub_root%\expected-path.txt" "%versions%\foo.1.env_add_path" "failed environment rendering"

  REM This manifest has no environment keywords, so it also exercises the fast-path decision.
  >"%SCOOP%\apps\foo\current\manifest.json" echo {"version":"4"}
  call "%SCOOP%\.portable\scoop.cmd" reset foo >NUL 2>&1
  call :assert_exit_code 0 "remove all environment properties"
  call :assert_file_not_exists "%versions%\foo.PORTABLE_TEST_KEPT.env_set.cmd"
  call :assert_file_not_exists "%versions%\foo.1.env_add_path"
  call :assert_same_file "%SCOOP%\apps\foo\current\manifest.json" "%versions%\foo.json" "environment-free manifest"
  call :assert_same_file "%stub_root%\other-env.cmd" "%versions%\foo.extra.PORTABLE_TEST_OTHER.env_set.cmd" "preserve another app's files"
  endlocal
  echo ::endgroup::
goto :EOF


:assert_env_save_failures_are_reported
  :: args: <COMMAND>; covers named saves, changed-app scans, and new-app scans
  echo ::group::environment saving failure after %~1 (stub scoop)
  setlocal
  REM a new folder per run that is left behind, see assert_patch_failures_are_reported
  set "stub_root=%TEMP%\scoop-portable-env-failure-%~1-test-%RANDOM%%RANDOM%"
  set "versions=%stub_root%\.portable\active_versions"
  md "%stub_root%\shims" "%stub_root%\.portable\scoop" "%versions%" || exit 1
  for %%a in (a-broken z-later) do md "%stub_root%\apps\%%a\current" || exit 1
  call :create_patched_stub_lib "%stub_root%"
  copy /Y "%SCOOP%\.portable\scoop.cmd" "%stub_root%\.portable\scoop.cmd" >NUL || exit 1
  >"%stub_root%\shims\scoop.cmd" echo @exit /B 0
  >"%stub_root%\.portable\scoop\config.json" echo {"last_update": "2099-01-01T00:00:00"}
  set "SCOOP=%stub_root%"
  REM Keep scan order explicit: the successful save must follow the failure.
  set "DIRCMD=/ON"
  >"%SCOOP%\apps\a-broken\current\manifest.json" echo {"version":"2","env_set":{"PORTABLE_TEST_BROKEN":"new"},"env_add_path":["bin"]}
  >"%SCOOP%\apps\z-later\current\manifest.json" echo {"version":"2"}
  >"%versions%\a-broken.PORTABLE_TEST_BROKEN.env_set.cmd" echo @set PORTABLE_TEST_BROKEN=old
  >"%versions%\a-broken.2.env_add_path" echo old-tools
  attrib +R "%versions%\a-broken.PORTABLE_TEST_BROKEN.env_set.cmd"
  set "command_args=%~1"
  if "%~1" == "update" (
    set "command_args=update --all"
    >"%versions%\a-broken.json" echo {"version":"1"}
  )
  if "%~1" == "reset" (
    set "command_args=reset a-broken z-later"
    >"%versions%\a-broken.json" echo {"version":"1"}
  )
  REM These two commands must find a-broken through the new-app scan, not a named save.
  if "%~1" == "install" set "command_args=install unrelated"
  if "%~1" == "import" set "command_args=import fixture.json"
  call "%SCOOP%\.portable\scoop.cmd" %command_args% >"%stub_root%\failure.log" 2>&1
  call :assert_exit_code 1 "%~1 with an unwritable environment file"
  REM Relocation needs the new version even though writing its derived environment failed.
  call :assert_same_file "%SCOOP%\apps\a-broken\current\manifest.json" "%versions%\a-broken.json" "failed environment write"
  call :assert_same_file "%SCOOP%\apps\z-later\current\manifest.json" "%versions%\z-later.json" "saving continues after failure"
  call :assert_file_exists "%versions%\a-broken.2.env_add_path"
  call :assert_log_contains "%stub_root%\failure.log" "scoop reset a-broken"

  >"%stub_root%\shims\scoop.cmd" echo @exit /B 7
  call "%SCOOP%\.portable\scoop.cmd" reset a-broken z-later >NUL 2>&1
  call :assert_exit_code 7 "preserve the original Scoop failure"
  >"%stub_root%\shims\scoop.cmd" echo @exit /B 0
  attrib -R "%versions%\a-broken.PORTABLE_TEST_BROKEN.env_set.cmd"
  REM The snapshots now match: a named reset must still retry the failed environment generation.
  call "%SCOOP%\.portable\scoop.cmd" reset a-broken >NUL 2>&1
  call :assert_exit_code 0 "retry environment generation"
  call :assert_log_contains "%versions%\a-broken.PORTABLE_TEST_BROKEN.env_set.cmd" "PORTABLE_TEST_BROKEN=new"
  call :assert_file_not_exists "%versions%\a-broken.2.env_add_path"
  if "%~1" == "reset" (
    REM A failed snapshot copy must stop before environment files are changed using stale metadata.
    copy /Y "%versions%\a-broken.json" "%stub_root%\previous-version.json" >NUL || exit 1
    attrib +R "%versions%\a-broken.json"
    >"%SCOOP%\apps\a-broken\current\manifest.json" echo {"version":"3","env_set":{"PORTABLE_TEST_BROKEN":"third"}}
    call "%SCOOP%\.portable\scoop.cmd" reset a-broken >NUL 2>&1
    call :assert_exit_code 1 "unwritable version snapshot"
    call :assert_same_file "%stub_root%\previous-version.json" "%versions%\a-broken.json" "failed snapshot copy"
    call :assert_log_contains "%versions%\a-broken.PORTABLE_TEST_BROKEN.env_set.cmd" "PORTABLE_TEST_BROKEN=new"
    attrib -R "%versions%\a-broken.json"
    call "%SCOOP%\.portable\scoop.cmd" reset a-broken >NUL 2>&1
    call :assert_exit_code 0 "retry version capture"
    call :assert_same_file "%SCOOP%\apps\a-broken\current\manifest.json" "%versions%\a-broken.json" "recovered snapshot copy"
  )
  endlocal
  echo ::endgroup::
goto :EOF


:create_patched_stub_lib
  :: args: <STUB_ROOT>
  :: minimal scoop lib files that look patched by the current scoop-portable version, so that
  :: patch_scoop leaves them unchanged and without warnings. The upstream definitions span two
  :: lines, the appended overrides one line. Keep the marker in sync with scoop-portable.cmd
  setlocal
  set "lib=%~1\apps\scoop\current\lib"
  if not exist "%lib%" md "%lib%" || exit 1
  >"%lib%\core.ps1" echo $configHome = "$env:SCOOP\.portable"
  >"%lib%\shortcuts.ps1" echo function create_startmenu_shortcuts($manifest, $dir, $global, $arch) {
  >>"%lib%\shortcuts.ps1" echo }
  >>"%lib%\shortcuts.ps1" echo function startmenu_shortcut([System.IO.FileInfo] $target, $shortcutName, $arguments, [System.IO.FileInfo]$icon, $global) {
  >>"%lib%\shortcuts.ps1" echo }
  >>"%lib%\shortcuts.ps1" echo function create_startmenu_shortcuts($manifest, $dir, $global, $arch) { }
  >>"%lib%\shortcuts.ps1" echo function startmenu_shortcut([System.IO.FileInfo] $target, $shortcutName, $arguments, [System.IO.FileInfo]$icon, $global) { }
  >"%lib%\system.ps1" echo function Set-EnvVar {
  >>"%lib%\system.ps1" echo }
  >>"%lib%\system.ps1" echo function Set-EnvVar { param([string]$Name, [string]$Value, [switch]$Global) }
  >>"%lib%\system.ps1" echo # scoop-portable-patches: 5
  >"%lib%\install.ps1" echo function Invoke-HookScript {
  >>"%lib%\install.ps1" echo }
  >>"%lib%\install.ps1" echo . "$env:SCOOP\.portable\environment.ps1"
  REM Use the real generated saver: a fake marker alone must not hide a missing helper.
  copy /Y "%SCOOP%\.portable\environment.ps1" "%~1\.portable\environment.ps1" >NUL || exit 1
  endlocal
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


:assert_log_contains
  :: args: <LOG_FILE> <TEXT>
  :: findstr treats a backslash in <TEXT> as an escape character, so <TEXT> must not contain any
  findstr /L /C:"%~2" "%~1" >NUL || (
    echo "ERROR: [%~1] does not contain [%~2]:"
    type "%~1"
    exit 1
  )
goto :EOF


:assert_log_lacks
  :: args: <LOG_FILE> <TEXT>
  :: a missing <LOG_FILE> passes. <TEXT> must not contain a backslash, see assert_log_contains
  findstr /L /C:"%~2" "%~1" >NUL 2>NUL && (
    echo "ERROR: [%~1] unexpectedly contains [%~2]:"
    type "%~1"
    exit 1
  )
goto :EOF
