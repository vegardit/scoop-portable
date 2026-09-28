@echo off
:: SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com) and contributors
:: SPDX-FileContributor: Sebastian Thomschke, Vegard IT GmbH
:: SPDX-License-Identifier: Apache-2.0
:: SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/scoop-portable

:: ABOUT
:: =====
:: This is a self-contained Windows batch file to install and launch a portable scoop (https://github.com/lukesampson/scoop) environment.

:: ############################################################################
:: act as wrapper for shims\scoop.cmd if this batch file is located at [scoop_install_root]\.portable\scoop.cmd
:: ############################################################################
call :ends_with "%~f0" ".portable\scoop.cmd" && (
  call :intercept_scoop_command %*
  goto :eof
)

:: ############################################################################
:: check if called with arguments, if so don't export variables to cmd process
:: ############################################################################
if not "%~1" == "" (
  setlocal
)

:: ############################################################################
:: check if ANSI color output is supported
:: ############################################################################
for /F "tokens=4-5 delims=. " %%i in ('ver') do set VERSION=%%i
:: only Windows 10+ supports ANSI
if %VERSION% gtr 9 (
  set ANSICON=1
)

:: ############################################################################
:: define env vars evaluated by scoop
:: ############################################################################
set SCOOP=%~dp0
set SCOOP=%SCOOP:~0,-1%
set SCOOP_CACHE=%SCOOP%\cache
set SCOOP_GLOBAL=%SCOOP%\globalApps


:: ############################################################################
:: install scoop if required
:: ############################################################################
if not exist "%SCOOP%\.portable" (
  call :install_scoop || exit /B 1
) else (
  if not exist "%SCOOP%\shims\scoop.cmd" (
    call :install_scoop || exit /B 1
  )
)

:: ##########################################################################
:: load the existing portable scoop installation
:: ##########################################################################

:: ==========================================================================
call :log_TASK Loading scoop-portable environment [%SCOOP%]
:: ==========================================================================
copy /Y "%~f0" "%SCOOP%\.portable\scoop.cmd" >NUL


:: ==========================================================================
call :log_TASK Checking file permissions
:: ==========================================================================
echo %USERDOMAIN%\%USERNAME%>"%SCOOP%\.portable\current.user"
fc "%SCOOP%\.portable\current.user" "%SCOOP%\.portable\last.user" >NUL 2>NUL
if errorlevel 1 (
  call :log_WARN Granting user [%USERDOMAIN%\%USERNAME%] full access to [%SCOOP%]...
  icacls "%SCOOP%" /Q /T /GRANT "%USERDOMAIN%\%USERNAME%:(CI)(OI)(F)"
)
del "%SCOOP%\.portable\current.user"
echo %USERDOMAIN%\%USERNAME%>"%SCOOP%\.portable\last.user"


:: ==========================================================================
:: check if installation location was moved
:: ==========================================================================
if exist "%SCOOP%\.portable\last.dir" (
  echo %SCOOP%>"%SCOOP%\.portable\current.dir"
  vol %SCOOP:~0,1%:>>"%SCOOP%\.portable\current.dir"
  fc "%SCOOP%\.portable\current.dir" "%SCOOP%\.portable\last.dir" >NUL 2>NUL
  if errorlevel 1 (
    call :fix_paths || exit /B 1
  )
  del "%SCOOP%\.portable\current.dir"
)
echo %SCOOP%>"%SCOOP%\.portable\last.dir"
vol %SCOOP:~0,1%:>>"%SCOOP%\.portable\last.dir"


:: ==========================================================================
call :log_TASK Setting environment variables
:: ==========================================================================
call :extend_PATH "%SCOOP%\shims"
:: important to add .portable after shims so that out scoop wrapper is used
call :extend_PATH "%SCOOP%\.portable"
:: scoop links the PowerShell modules of apps (manifest entry "psmodule") into this folder, but only
:: adds it to the persistent PSModulePath (ensure_in_psmodulepath in lib\psmodules.ps1), which the
:: patches prevent. So it is added per session, like the shims folder: an earlier entry is removed
:: first, so that loading again does not add it twice, and the existing entries are kept, as
:: PowerShell also finds its own and the user's modules through them.
:: An undefined PSModulePath (e.g. in a stripped environment) is left alone: Windows PowerShell
:: only uses its default folders without the variable, so a new one with just this folder would
:: hide them, and replace_substrings returns its search text for an undefined variable.
:: Two separate lines, each checking again: within one parenthesized block, %PSModulePath% would be
:: expanded before the removal. And a value that held only this folder is undefined after the
:: removal, so it is left alone like any undefined value
if defined PSModulePath call :replace_substrings PSModulePath "%SCOOP%\modules;" ""
if defined PSModulePath set "PSModulePath=%SCOOP%\modules;%PSModulePath%"
call :set_app_env_vars

call :log_SUCCESS The portable scoop environment is ready.


:: ==========================================================================
:: if scoop portable was launched with arguments, execute the arguments
:: ==========================================================================
if not "%~1" == "" (
  %*
  goto :eof
)

:: ==========================================================================
:: determine if a command window needs to be launched
:: ==========================================================================

:: check if launched via windows explorer
if /I "%CmdCmdLine:"=%" == "%ComSpec% /c %~dpf0 " (
  title Command Prompt
  if exist "%SCOOP%\apps\clink\current\clink.bat" (
    call :log_TASK Loading clink
    cmd /K %SCOOP%\apps\clink\current\clink.bat inject --quiet
  ) else (
    cmd
  )
  goto :eof
)

:: launched via other batch file or manually from command window
goto :eof



:install_scoop
  :: ##########################################################################
  :: create a new portable scoop installation
  :: ##########################################################################

  call :log_HEADER Installing [scoop] at [%SCOOP%]...
  setlocal
  :: ignore the wrapper and shims of this installation, e.g. on PATH from an earlier load in the same
  :: session; otherwise also the upstream installer would find them and silently skip the installation.
  :: :extend_PATH adds both entries in exactly this form
  call :replace_substrings PATH "%SCOOP%\.portable;" ""
  call :replace_substrings PATH "%SCOOP%\shims;" ""
  :: $PATH: excludes the current directory, e.g. when started from within %SCOOP%\shims
  where /Q $PATH:scoop && (
    call :exit_with_ERROR Cannot install scoop, 'scoop' command already on PATH
    exit /B 1
  )

  :: https://github.com/ScoopInstaller/Scoop/wiki/Quick-Start#installing-scoop
  :: ==========================================================================
  :: default config, can be overridden via scoop-portable-config.cmd
  :: ==========================================================================
  setlocal EnableDelayedExpansion

  ::set SCOOP_PROXY=<HOSTNAME>:<PORT>
  ::set SCOOP_PROXY=myproxy.local:8080
  set SCOOP_PROXY=

  :: if set to true the Windows credentials of the logged-in user are used for proxy authentication
  set SCOOP_PROXY_USE_WINDOWS_CREDENTIALS=false

  :: if SCOOP_PROXY_USE_WINDOWS_CREDENTIALS is set to false, then use these credentials for proxy authentication
  set SCOOP_PROXY_USER=
  set SCOOP_PROXY_PASSWORD=

  :: additional scoop buckets to register by default
  :: set SCOOP_BUCKETS=extras java
  set SCOOP_BUCKETS=

  :: packages to install by default
  set SCOOP_PACKAGES=


  :: ==========================================================================
  :: load custom config from separate file if exists
  :: ==========================================================================
  set custom_config_file=%~dp0scoop-portable-config.cmd
  if exist "%custom_config_file%" (
    call :log_TASK Loading custom config from [%custom_config_file%]
    call "%custom_config_file%" || exit /B 1
  )


  :: ==========================================================================
  :: Setting PowerShell ExecutionPolicy [RemoteSigned] if required
  :: ==========================================================================
  powershell -noprofile -command ^
    if ((Get-ExecutionPolicy).ToString() -notin @('Unrestricted', 'RemoteSigned', 'Bypass')) { ^
      Write-Host "[$(Get-Date -Format 'HH:mm:ss,ff')] Setting PowerShell ExecutionPolicy [RemoteSigned]..."; ^
      Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser ^
    }


  :: ==========================================================================
  call :log_TASK Downloading scoop installer
  :: ==========================================================================
  :: https://github.com/lukesampson/scoop/wiki/Using-Scoop-behind-a-proxy
  if defined SCOOP_PROXY (
    call :log_TASK Downloading scoop installer using proxy [%SCOOP_PROXY%]
    set "scoopProxy=[net.webrequest]::defaultwebproxy = new-object net.webproxy 'http://%SCOOP_PROXY%';"
    if "%SCOOP_PROXY_USE_WINDOWS_CREDENTIALS%" == "true" (
      set "scoopProxy=!scoopProxy!; [net.webrequest]::defaultwebproxy.credentials = [net.credentialcache]::defaultcredentials;"
    ) else (
      if defined SCOOP_PROXY_USER (
        set "scoopProxy=!scoopProxy!; [net.webrequest]::defaultwebproxy.credentials = new-object net.networkcredential '%SCOOP_PROXY_USER%', '%SCOOP_PROXY_PASSWORD%';"
      )
    )
  )

  call :mkdirs "%SCOOP%\.portable"

  :: 1) replacing '$env:XDG_CONFIG_HOME' is a workaround for https://github.com/ScoopInstaller/Scoop/issues/4498
  ::    to make <USERPROFILE>\.config\scoop\config.json portable
  :: 2) replacing '  Add-ShimsDirToPath' to prevent shim dir being permanently added to %PATH%
  :: 3) disabling the "exists and is not empty" check for SCOOP_DIR (added by ScoopInstaller/Install@c64d414)
  ::    because the portable install root always contains at least scoop-portable.cmd itself
  :: each patch warns if the installer no longer contains its text, because the replacement would then
  :: silently do nothing. The script is one cmd line built with ^, so every line needs an even number of "
  :: and, with delayed expansion enabled here, no ! may be used
  :: $ErrorActionPreference='Stop' makes a failed download abort the installation
  :: instead of writing and running an empty installer script
  powershell -noprofile -command $ErrorActionPreference = 'Stop'; !scoopProxy! ^
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; ^
    $installer_script = (New-Object System.Net.WebClient).DownloadString('https://get.scoop.sh'); ^
    if (-not $installer_script.contains('$env:XDG_CONFIG_HOME')) { Write-Warning 'scoop-portable: installer patch 1 not applied, scoop may keep its config in the user profile' }; ^
    if ($installer_script -notmatch '\s\s+Add-ShimsDirToPath') { Write-Warning 'scoop-portable: installer patch 2 not applied, the shims folder may be added to the user PATH' }; ^
    if (-not $installer_script.contains('(Test-Path \"$SCOOP_DIR\*\")')) { Write-Warning 'scoop-portable: installer patch 3 not applied, the installer may reject the non-empty folder' }; ^
    $installer_script = $installer_script.replace('$env:XDG_CONFIG_HOME', '\"$env:SCOOP\.portable\"'); ^
    $installer_script = $installer_script -replace '\s\s+Add-ShimsDirToPath', ''; ^
    $installer_script = $installer_script.replace('(Test-Path \"$SCOOP_DIR\*\")', '$false'); ^
    Set-Content -Path "$env:TEMP\scoop_installer.ps1" -Value $installer_script || exit /B 1
  powershell -noprofile -File "%TEMP%\scoop_installer.ps1" || exit /B 1
  del "%TEMP%\scoop_installer.ps1"

  :: the installer also exits with 0 without installing anything, e.g. if another scoop is on PATH
  if not exist "%SCOOP%\shims\scoop.cmd" (
    call :exit_with_ERROR The scoop installer did not install scoop at [%SCOOP%]
    exit /B 1
  )

  call :patch_scoop || exit /B 1

  :: installing itself as scoop wrapper
  copy /Y "%~f0" "%SCOOP%\.portable\scoop.cmd" >NUL

  echo %USERDOMAIN%\%USERNAME%>"%SCOOP%\.portable\last.user"

  :: https://github.com/ScoopInstaller/Scoop/wiki/Using-Scoop-behind-a-proxy
  if defined SCOOP_PROXY (
    if "%SCOOP_PROXY_USE_WINDOWS_CREDENTIALS%" == "true" (
       call "%SCOOP%\.portable\scoop.cmd" config proxy currentuser@%SCOOP_PROXY% || exit /B 1
    ) else (
      if defined SCOOP_PROXY_USER (
        call "%SCOOP%\.portable\scoop.cmd" config proxy %SCOOP_PROXY_USER%:%SCOOP_PROXY_PASSWORD%@%SCOOP_PROXY% || exit /B 1
      ) else (
        call "%SCOOP%\.portable\scoop.cmd" config proxy %SCOOP_PROXY% || exit /B 1
      )
    )
  )

  if defined SCOOP_BUCKETS (
    REM install git if not present - required for adding buckets
    where /Q git.exe
    if errorlevel 1 (
      call :has_substring "%SCOOP_PACKAGES%" "git-with-openssh"
      if errorlevel 1 (
        call :log_TASK Installing [git]
        call "%SCOOP%\.portable\scoop.cmd" install git
        call :extend_PATH "%SCOOP%\shims"
      ) else (
        call :log_TASK Installing [git-with-openssh]
        call "%SCOOP%\.portable\scoop.cmd" install git-with-openssh
        call :extend_PATH "%SCOOP%\shims"
      )
    )

    for %%b in (%SCOOP_BUCKETS%) do (
      call :log_TASK Adding scoop bucket [%%b]
      call "%SCOOP%\.portable\scoop.cmd" bucket add %%b
    )
  )

  if defined SCOOP_PACKAGES (
    call :log_TASK Installing packages [%SCOOP_PACKAGES%]
    setlocal
    for %%p in (%SCOOP_PACKAGES%) do (
      call "%SCOOP%\.portable\scoop.cmd" install %%~p
    )
    endlocal
  )
goto :eof



:fix_paths
  :: ##########################################################################
  :: function to fix paths after scoop dir was moved
  :: ##########################################################################
  setlocal

  call :log_WARN Installation directory was moved. Fixing paths...

  :: Rewrite generated session files. Captured hook records retain their original
  :: roots so the saver can rebase them later and compare their raw snapshots.
  :: Read the root from the environment so apostrophes stay path data, not PowerShell syntax.
  set fix_paths=^
    Set-StrictMode -version latest; ^
    $last_dir = (Get-Content -path ($env:SCOOP + '\.portable\last.dir') -first 1).trim() + '\'; ^
    ^
    function replaceScoopPaths($file_path) { ^
      if (Test-Path -path $file_path) { ^
        $old = Get-Content -path $file_path -raw; ^
        if (-not [string]::IsNullOrEmpty($old)) { ^
          $new = $old.replace($last_dir, $env:SCOOP + '\'); ^
          if ($old -ne $new) { ^
            Write-Host "[$(Get-Date -Format 'HH:mm:ss,ff')] --^> Path updated in: $file_path"; ^
            Set-Content -noNewline -path $file_path -value $new; ^
          } ^
        } ^
      } ^
    } ^
    ^
    replaceScoopPaths ($env:SCOOP + '\.portable\scoop\config.json'); ^
    replaceScoopPaths ($env:SCOOP + '\shims\scoop'); ^
    replaceScoopPaths ($env:SCOOP + '\shims\scoop.cmd'); ^
    replaceScoopPaths ($env:SCOOP + '\shims\scoop.ps1'); ^
    ^
    Get-ChildItem ($env:SCOOP + '\.portable\active_versions') -file -filter *.env_set.cmd  ^| Foreach-Object { replaceScoopPaths $_.FullName }; ^
    Get-ChildItem ($env:SCOOP + '\.portable\active_versions') -file -filter *.env_add_path ^| Foreach-Object { replaceScoopPaths $_.FullName }; ^
    Get-ChildItem ($env:SCOOP + '\apps')                      -file -filter *.ini -recurse ^| Foreach-Object { replaceScoopPaths $_.FullName }; ^
    Get-ChildItem ($env:SCOOP + '\shims')                     -file -filter *.shim         ^| Foreach-Object { replaceScoopPaths $_.FullName }; ^
    ^
    function fixAppCurrentVersionSymlinks($app_curr_ver_path) { ^
      $app_name = $app_curr_ver_path.Parent.Name; ^
      if ($app_name -eq 'scoop') { return; } ^
      $app_manifest = Get-Content -path ($env:SCOOP + '\.portable\active_versions\' + $app_name + '.json') -raw ^| ConvertFrom-Json; ^
      $app_curr_ver = $app_manifest.version; ^
      if (Test-Path -Path $app_curr_ver_path) { ^
        fsutil reparsepoint delete $app_curr_ver_path ^| out-null; ^
        Remove-Item $app_curr_ver_path -recurse -force; ^
      } ^
      New-Item -itemType Junction -path $app_curr_ver_path -target ($env:SCOOP + '\apps\' + $app_name + '\' + $app_curr_ver) ^| out-null; ^
      Write-Host "[$(Get-Date -Format 'HH:mm:ss,ff')] --^> Junction updated: $app_curr_ver_path"; ^
      ^
      if ('persist' -in $app_manifest.PSobject.Properties.Name) { ^
        $app_manifest.persist ^| ForEach-Object { ^
          $app_persist_path = $_; ^
          $persist_path = $env:SCOOP + '\persist\' + $app_name + '\' + $app_persist_path; ^
          if ((Get-Item $persist_path) -is [System.IO.DirectoryInfo]) { ^
            fsutil reparsepoint delete "$app_curr_ver_path\$app_persist_path" ^| out-null; ^
            Remove-Item "$app_curr_ver_path\$app_persist_path" -recurse -force; ^
            New-Item -itemType Junction -path "$app_curr_ver_path\$app_persist_path" -target $persist_path ^| out-null; ^
            Write-Host "[$(Get-Date -Format 'HH:mm:ss,ff')] --^> Junction updated: $app_curr_ver_path\$app_persist_path"; ^
          } else { ^
            Remove-Item "$app_curr_ver_path\$app_persist_path" -force; ^
            New-Item -itemType HardLink -path "$app_curr_ver_path\$app_persist_path" -target $persist_path ^| out-null; ^
            Write-Host "[$(Get-Date -Format 'HH:mm:ss,ff')] --^> HardLink updated: $app_curr_ver_path\$app_persist_path"; ^
          } ^
        } ^
      } ^
    } ^
    ^
    Get-ChildItem ($env:SCOOP + '\apps\*\*') -directory -filter current ^| Foreach-Object { fixAppCurrentVersionSymlinks $_ }; ^
    Get-ChildItem ($env:SCOOP + '\apps\*') -directory ^| Where-Object { -not (Test-Path (Join-Path $_.FullName 'current')) } ^| Foreach-Object { fixAppCurrentVersionSymlinks ([System.IO.DirectoryInfo](Join-Path $_.FullName 'current')) }; ^
    #

  powershell -noprofile -ex unrestricted -command "%fix_paths%" || exit /B 1
goto :eof



:intercept_scoop_command
  :: ##########################################################################
  :: wrapper for shims\scoop.cmd
  :: ##########################################################################

  :: ==========================================================================
  :: check if scoop <command> -h/--help is requested
  :: ==========================================================================
  :: like in scoop (bin\scoop.ps1), only -h or --help as the first argument after the command
  :: shows the help. Passed on directly, as showing help writes nothing and needs no patching,
  :: and e.g. "scoop install -h" must not update scoop itself first. Anywhere else, e.g. in
  :: "scoop config <name> --help", the command really runs, so it is not passed on here.
  :: /? is not handled: "call" shows its own help for any /? argument
  for %%h in (-h --help) do if /I "%~2" == "%%h" (
    call "%SCOOP%\shims\scoop.cmd" %*
    goto :eof
  )

  setlocal EnableDelayedExpansion
  :: patch before scoop runs, not only after commands that may replace scoop: an installation
  :: patched by an older scoop-portable version would otherwise run this command with the upstream
  :: Set-EnvVar, and reset/uninstall would never get patched. Running scoop unpatched is worse
  :: than failing, so the command is not run if patching fails
  call :ensure_scoop_patched || exit /B 1
  :: scoop accepts its commands in any case, e.g. "scoop INSTALL", so all comparisons of
  :: scoop_command below ignore case (if /I). Quotes must also be stripped for dispatch,
  :: otherwise scoop "install" would bypass its safeguards. Keep the forwarded args intact.
  set "scoop_command=%~1"

  :: ==========================================================================
  :: INTERCEPT scoop update
  :: ==========================================================================
  if /I "%scoop_command%" == "update" (
    REM scoop updates itself with the patches in place: update_scoop sets autostash_on_conflict,
    REM so scoop stashes the patched lib files before pulling, while its running process keeps
    REM the patched functions it loaded at start. Reverting the patches before the update would
    REM let this whole run write persistent environment variables
    REM App installers can still write PATH directly. Keep its raw value out of CMD,
    REM and do not start an update unless a complete recovery snapshot was saved.
    call :save_user_PATH || exit /B 1
    REM before updating apps, scoop updates itself if "scoop" is one of the apps or its last
    REM update is 3 hours or more ago. That update runs on its own instead (see
    REM update_scoop_if_outdated), so every "scoop" target is removed from the app invocation.
    REM Compare argument values: substring replacement misses quoted targets and can change
    REM text inside another quoted argument.
    call :filter_scoop_update_args %*
    set "apps_to_update="
    call :get_2nd_positional_arg apps_to_update !app_update_args!
    REM has_short_option also finds -a in combined short options like -qa, which would otherwise
    REM be taken for a plain "scoop update" and update all apps within the run below that also
    REM updates scoop itself
    call :has_short_option a !app_update_args! && set "apps_to_update=all"
    call :has_arg --all !app_update_args! && set "apps_to_update=all"
    if defined scoop_named (
      REM without the options, which are meant for the app updates: scoop rejects e.g. --no-cache
      REM when it only updates itself, but not with "scoop" as one of the apps. Checked first, as
      REM "scoop update scoop <options>" has no apps left, but is not a plain "scoop update".
      REM As scoop never sees these options, it cannot reject an invalid one either, e.g. a typo.
      REM Accepted: the update of scoop itself that was asked for runs anyway
      call :update_scoop update
    ) else if not defined apps_to_update (
      REM only scoop itself, i.e. a plain "scoop update" with its options, if any
      call :update_scoop !app_update_args!
    ) else (
      call :update_scoop_if_outdated
    )
    set rc=!errorlevel!
    REM if scoop could not update itself, it would try again within the app updates, so they
    REM are skipped. scoop itself also skips them if its update fails
    if !rc! == 0 if defined apps_to_update (
      call "%SCOOP%\shims\scoop.cmd" !app_update_args!
      set rc=!errorlevel!
      REM Re-patch defensively if an app or a future scoop version replaces the lib files.
      REM A failed re-patch fails an otherwise successful command, because scoop could then
      REM write persistent environment variables.
      call :ensure_scoop_patched || if !rc! == 0 set rc=1
    )
    REM compare manifests to also cover --all, "*", "scoop update scoop <app>" and new
    REM dependencies. A changed JDK does not take JAVA_HOME from the selected one there.
    REM Saving failures also fail an otherwise successful command. Continue recording apps:
    REM scoop has already changed their versions, which relocation must be able to restore.
    call :save_active_versions_of_changed_apps || if !rc! == 0 set rc=1
    REM save the named apps last so they win, e.g. "scoop update <jdk>" re-selects that JDK.
    REM skipped if any argument is "*" (not only the first app, e.g. "scoop update scoop *"),
    REM because the for loop in get_positional_args would expand it to the file names of the
    REM current directory. has_arg itself compares without a for loop, so "*" stays literal
    call :has_arg * %* || (
      REM /%* makes the first arg (the command) a flag so it is not treated as an app name
      call :get_positional_args apps /%*
      for %%a in (!apps!) do (
        call :save_active_version %%a || if !rc! == 0 set rc=1
      )
    )
    REM Restore even after an update or settings-save failure, without hiding that error.
    call :restore_user_PATH || if !rc! == 0 set rc=1
    exit /B !rc!
  )

  :: ==========================================================================
  :: INTERCEPT scoop install
  :: ==========================================================================
  if /I "%scoop_command%" == "install" (
    call :has_arg --global %* && set global_install=true
    REM has_short_option also finds -g in combined short options like -kg, and -G
    call :has_short_option g %* && set global_install=true
    if "!global_install!" == "true" (
      call :exit_with_ERROR Installing applications globally is not supported by scoop-portable.
      exit /B 1
    )

    call :update_scoop_before_command %* || exit /B 1
    REM Put the option before the user arguments: after --, getopt takes it for an app name.
    REM FOR /F splits only the command; its * token keeps the rest, including quotes and --.
    REM SET has no outer quotes because arguments may already quote paths or URLs with ampersands.
    REM Delayed expansion keeps that text from being parsed as commands in the FOR input.
    REM A user-supplied --no-update-scoop remains harmless: getopt sets the same option twice.
    set scoop_args=%*
    for /F "tokens=1,*" %%c in ("!scoop_args!") do call "%SCOOP%\shims\scoop.cmd" %%c --no-update-scoop %%d
    set rc=!errorlevel!
    REM see the update block for why a failed re-patch fails the command
    call :ensure_scoop_patched || if !rc! == 0 set rc=1

    REM /%* makes the first arg (the command) a flag so it is not treated as an app name
    call :get_positional_args apps /%*
    for %%a in (!apps!) do (
      call :save_active_version %%a || if !rc! == 0 set rc=1
    )

    REM save app states of dependencies (if any)
    call :save_active_versions_of_new_apps || if !rc! == 0 set rc=1

    REM %rc% would be expanded when this block is parsed, i.e. before rc is set.
    REM The FOR variable carries the exit code across endlocal, which must run
    REM before set_app_env_vars so the env changes reach the caller.
    for %%r in (!rc!) do (
      endlocal
      call :set_app_env_vars
      exit /B %%r
    )
  )

  :: ==========================================================================
  :: INTERCEPT scoop uninstall
  :: ==========================================================================
  if /I "%scoop_command%" == "uninstall" (
    call :get_2nd_positional_arg app_name %*
    call "%SCOOP%\shims\scoop.cmd" %*
    set rc=!errorlevel!
    REM Scoop may already have removed the app when portable cleanup fails.
    REM Report that incomplete cleanup without hiding an earlier Scoop failure.
    call :cleanup_active_versions || if !rc! == 0 set rc=1
    exit /B !rc!
  )

  :: ==========================================================================
  :: INTERCEPT scoop reset
  :: ==========================================================================
  if /I "%scoop_command%" == "reset" (
    call "%SCOOP%\shims\scoop.cmd" %*
    set rc=!errorlevel!

    call :parse_reset_args %*
    if defined reset_all (
      REM Reset also repairs generated settings when the manifest and hook snapshots already
      REM match, e.g. after a failed save. A changed-app scan would skip those repairs.
      REM Bulk targets override named apps in Scoop; only a named reset selects another JDK.
      for /F "delims=" %%a in ('dir /B /AD "%SCOOP%\apps\*" 2^>NUL') do if /I not "%%a" == "scoop" (
        REM Continue saving after failures without hiding an earlier Scoop error.
        call :save_active_version "%%a" keep_selected_jdk || if !rc! == 0 set rc=1
      )
    ) else (
      for %%a in (!reset_apps!) do (
        call :save_active_version %%a || if !rc! == 0 set rc=1
      )
    )

    REM see the install block for why the exit code is passed via a FOR variable
    for %%r in (!rc!) do (
      endlocal
      call :set_app_env_vars
      exit /B %%r
    )
  )

  :: ==========================================================================
  :: INTERCEPT scoop import
  :: ==========================================================================
  if /I "%scoop_command%" == "import" (
    REM import runs "scoop install" per app, but has no option to keep scoop from updating
    REM itself within these installations (see update_scoop_if_outdated), so it only runs after
    REM scoop updated itself successfully.
    REM So, unlike in scoop itself, no import runs while scoop cannot update itself, e.g. without
    REM git (which scoop needs for that) or while GitHub cannot be reached. Accepted: continuing
    REM would let a later attempt within the import that succeeds load unpatched files. The
    REM warning names the way out.
    REM import also applies the configs of the Scoopfile first, which can undo this protection: a
    REM hand-written, outdated last_update, e.g. from a pasted config.json, lets scoop update itself
    REM within the import right away, and autostash_on_conflict, which "scoop export" keeps, lets
    REM an update within an import that runs longer than an hour pull the unpatched lib files, see
    REM update_scoop. Accepted: the first needs a hand-written Scoopfile, as "scoop export" never
    REM writes last_update, and the second a setting that scoop-portable never leaves on, plus a
    REM long import
    call :update_scoop_if_outdated || (
      call :log_WARN Skipping the import: scoop must update itself first. Install git with "scoop install git" if it is missing, otherwise check the connection to GitHub
      exit /B 1
    )
    REM A self-update can replace the importer. Check its guard afterwards, on every import,
    REM independently of the general patch marker; unsupported importers must only block imports.
    call :ensure_scoop_import_patched || exit /B 1
    call "%SCOOP%\shims\scoop.cmd" %*
    set rc=!errorlevel!
    REM scoop may still try to update itself within an import that runs longer than an hour. A git
    REM based scoop then skips that update, see update_scoop, unless the Scoopfile set
    REM autostash_on_conflict, see above. One without git replaces its lib files anyway. See the
    REM update block for why a failed re-patch fails the command
    call :ensure_scoop_patched || if !rc! == 0 set rc=1
    REM the apps are installed by scoop's own install script, not via this wrapper, so their
    REM versions are saved here, like the dependencies after "scoop install". Also after a
    REM failure: import continues with the next app, so earlier ones may be installed
    call :save_active_versions_of_new_apps || if !rc! == 0 set rc=1
    REM see the install block for why the exit code is passed via a FOR variable
    for %%r in (!rc!) do (
      endlocal
      call :set_app_env_vars
      exit /B %%r
    )
  )

  :: ==========================================================================
  :: EXECUTE other scoop command
  :: ==========================================================================
  :: "scoop download" and "scoop virustotal" would update scoop within the command like
  :: "scoop install", see there
  set "no_update_scoop="
  if /I "%scoop_command%" == "download" set "no_update_scoop=--no-update-scoop"
  if /I "%scoop_command%" == "virustotal" set "no_update_scoop=--no-update-scoop"
  if defined no_update_scoop (
    call :update_scoop_before_command %* || exit /B 1
    REM Keep the option before -- and preserve quoted arguments, as in the install block.
    set scoop_args=%*
    for /F "tokens=1,*" %%c in ("!scoop_args!") do call "%SCOOP%\shims\scoop.cmd" %%c !no_update_scoop! %%d
  ) else (
    call "%SCOOP%\shims\scoop.cmd" %*
  )
  set rc=!errorlevel!
  :: no other command is known to update scoop itself, so this only guards against unknown cases.
  :: see the update block for why a failed re-patch fails the command
  call :ensure_scoop_patched || if !rc! == 0 set rc=1
  exit /B !rc!
goto :eof



:save_active_versions_of_changed_apps
  :: saves each app whose manifest or captured hooks differ from their snapshots, including new apps.
  :: fc also fails for apps without a current manifest, which save_active_version then skips.
  :: keep_selected_jdk: a changed JDK must not take JAVA_HOME from the selected one, because
  :: the JDK is selected with "scoop reset <jdk>" (or by naming it in "scoop update <jdk>")
  setlocal
  :: Remember any failure without letting a later successful save hide it or skipping other apps.
  set "save_rc=0"
  for /F %%f in ('dir /B "%SCOOP%\apps\*" 2^>NUL') do (
    set "app_changed="
    fc /B "%SCOOP%\apps\%%~f\current\manifest.json" "%SCOOP%\.portable\active_versions\%%~f.json" >NUL 2>&1 || set "app_changed=true"
    REM A forced update can produce different hook settings without changing the manifest.
    if exist "%SCOOP%\apps\%%~f\current\.scoop-portable-env.json" (
      fc /B "%SCOOP%\apps\%%~f\current\.scoop-portable-env.json" "%SCOOP%\.portable\active_versions\%%~f.env_hooks" >NUL 2>&1 || set "app_changed=true"
    ) else if exist "%SCOOP%\.portable\active_versions\%%~f.env_hooks" (
      set "app_changed=true"
    )
    if defined app_changed call :save_active_version %%~f keep_selected_jdk || set "save_rc=1"
  )
exit /B %save_rc%



:save_active_versions_of_new_apps
  setlocal
  :: Like the changed-app scan, keep recording versions after a failed environment write.
  set "save_rc=0"
  for /F %%f in ('dir /B "%SCOOP%\apps\*" 2^>NUL') do (
    if not exist "%SCOOP%\.portable\active_versions\%%~f.json" (
      call :save_active_version %%~f || set "save_rc=1"
    )
  )
exit /B %save_rc%



:save_active_version
  :: args: <APP_NAME(@<APP_VERSION>)> [keep_selected_jdk]
  setlocal
  call :mkdirs "%SCOOP%\.portable\active_versions"

  set app=%~1
  set save_mode=%~2

  :: extract appname from [bucket/]app[@version]
  call :substring_before %app% @ app_name
  for %%i in ("%app_name:/=\%") do set "app_name=%%~nxi"

  if not exist "%SCOOP%\apps\%app_name%\current\manifest.json" exit /B 0

  :: fix_paths reads this snapshot to restore the selected version after a move. Keep it
  :: current even if generating the derived environment files fails; it is not a success marker.
  copy /Y "%SCOOP%\apps\%app_name%\current\manifest.json" "%SCOOP%\.portable\active_versions\%app_name%.json" >NUL || goto :save_active_version___FAILED

  :: Hook state may be the only source of settings, e.g. Gradle has no env_set property.
  findstr /C:env_set /C:env_add_path "%SCOOP%\.portable\active_versions\%app_name%.json" >NUL
  if %errorlevel% == 1 (
    if not exist "%SCOOP%\apps\%app_name%\current\.scoop-portable-env.json" if not exist "%SCOOP%\.portable\active_versions\%app_name%.env_hooks" if not exist "%SCOOP%\.portable\active_versions\%app_name%.*.env_set.cmd" if not exist "%SCOOP%\.portable\active_versions\%app_name%.*.env_add_path" exit /B 0
  )

  :: Pass data through the environment; the helper is generated when Scoop is patched.
  :: Keeping this PowerShell out of a -command string also avoids CMD's 8191-character limit.
  set "scoop_portable_app=%app_name%"
  set "scoop_portable_save_mode=%save_mode%"
  :: Match cleanup_active_versions: use a process policy override for copied installations.
  powershell -noprofile -ex unrestricted -command ". \"$env:SCOOP\.portable\environment.ps1\"; Save-ScoopPortableEnvironment $env:scoop_portable_app $env:scoop_portable_save_mode" || goto :save_active_version___FAILED
exit /B 0

:save_active_version___FAILED
  :: A matching snapshot does not imply a complete environment, so change-only scans cannot retry this.
  >&2 call :log_WARN Could not save portable settings for %app_name%. After correcting the error, run "scoop reset %app_name%".
exit /B 1



:cleanup_active_versions
  :: A copied installation skips the installer's per-user policy setup.
  :: Like Scoop's shim, allow the helper in this process without changing the user's policy.
  powershell -noprofile -ex unrestricted -command ". \"$env:SCOOP\.portable\environment.ps1\"; Remove-ScoopPortableInactiveVersions" || (
    >&2 call :log_WARN Could not remove portable settings. Correct the reported error; cleanup is retried on the next uninstall.
    exit /B 1
  )
exit /B 0



:define_scoop_patches
  :: Shared text transformations keep stash verification tied to the patches we actually write.
  :: Cleanup applies them to a stash's own base blobs, without running any saved PowerShell code.
  :: Keep the marker in sync with ensure_scoop_patched whenever the general patches change.
  :: The import guard is checked separately on every import, after any self-update.
  :: Match Scoop's comma-space-separated Info tokens and case-insensitive comparison exactly,
  :: so the guard rejects the same entries Scoop would install globally.
  set scoop_patch_functions=^
    $shortcutFunctions = 'function create_startmenu_shortcuts($manifest, $dir, $global, $arch) {', 'function startmenu_shortcut([System.IO.FileInfo] $target, $shortcutName, $arguments, [System.IO.FileInfo]$icon, $global) {'; ^
    $envOverride = 'function Set-EnvVar { param([string]$Name, [string]$Value, [switch]$Global) }'; ^
    $hookOverride = '. \"$env:SCOOP\.portable\environment.ps1\"'; ^
    $patchMarker = '# scoop-portable-patches: 6'; ^
    $importStart = 'foreach ($item in $import.config.PSObject.Properties) {'; ^
    $importGuard = ^
      '# scoop-portable: Imports bypass the CMD install guard. Check all apps before applying the Scoopfile.', ^
      '# Throw unwinds Scoop''s dispatcher; abort can return success after exiting only this child script.', ^
      'foreach ($portableApp in $import.apps) {', ^
      '    if (''Global install'' -in ($portableApp.Info -split '', '')) {', ^
      '        throw (''scoop-portable: Cannot import global app {0}. Remove its entry or remove Global install from its Info field to install it locally.'' -f $portableApp.Name)', ^
      '    }', ^
      '}'; ^
    function portableText($file, $text) { ^
      switch -CaseSensitive ($file) { ^
        'lib/core.ps1' { return $text.replace('$env:XDG_CONFIG_HOME', '\"$env:SCOOP\.portable\"') } ^
        'lib/shortcuts.ps1' { $lines = @($shortcutFunctions ^| ForEach-Object { $_ + ' }' }) } ^
        'lib/system.ps1' { $lines = @($envOverride, $patchMarker) } ^
        'lib/install.ps1' { $lines = @($hookOverride) } ^
        'libexec/scoop-import.ps1' { ^
          $anchors = [regex]::Matches($text, '(?m)^^' + [regex]::Escape($importStart) + '\r?$'); ^
          if ($anchors.Count -ne 1) { throw 'Cannot locate a unique Scoopfile import boundary' }; ^
          $newline = [string][char]10; if ($text.Contains([string][char]13 + [char]10)) { $newline = [string][char]13 + [char]10 }; ^
          $guard = ($importGuard -join $newline) + $newline; ^
          $position = $anchors[0].Index; ^
          if ($position -ge $guard.Length -and [string]::Equals($text.Substring($position - $guard.Length, $guard.Length), $guard, [StringComparison]::Ordinal)) { return $text }; ^
          return $text.Insert($position, $guard); ^
        } ^
        default { throw 'Unknown portable patch' } ^
      }; ^
      foreach ($line in $lines) { if (-not $text.contains($line)) { $text = $text + $line + [char]10 } }; ^
      return $text; ^
    };
goto :eof



:ensure_scoop_import_patched
  :: Patch only the importer: failure must reject imports without blocking commands needed to
  :: update Scoop. Reuse the transformation for stash verification, with no separate cached marker.
  :: The boundary is checked even when the guard is present, so an ambiguous upstream edit fails.
  :: Preserve UTF-8 bytes, including a BOM and newlines, to match stash verification exactly.
  setlocal
  call :define_scoop_patches
  set patch_import=^
    $ErrorActionPreference = 'Stop'; ^
    try { ^
      $path = $env:SCOOP + '\apps\scoop\current\libexec\scoop-import.ps1'; ^
      $utf8 = New-Object System.Text.UTF8Encoding($false, $true); ^
      $old = $utf8.GetString([IO.File]::ReadAllBytes($path)); ^
      $new = portableText 'libexec/scoop-import.ps1' $old; ^
      if (-not [string]::Equals($old, $new, [StringComparison]::Ordinal)) { [IO.File]::WriteAllText($path, $new, $utf8) }; ^
    } catch { Write-Host ('ERROR: scoop-portable: Cannot guard Scoopfile imports: ' + $_.Exception.Message); exit 1 }; ^
    #
  powershell -noprofile -ex unrestricted -command "%scoop_patch_functions% %patch_import%" 1>&2
exit /B %errorlevel%



:patch_scoop
  :: ##########################################################################
  :: patch scoop to make it more portable
  :: ##########################################################################
  :: all output goes to stderr: patching may happen before any command, e.g. "scoop prefix <app>",
  :: whose output on stdout is read by scripts
  call :log_TASK Patching scoop 1>&2
  setlocal
  set "scoop_portable_source=%~f0"
  call :define_scoop_patches

  :: 1) core.ps1: replacing '$env:XDG_CONFIG_HOME' is a workaround for https://github.com/ScoopInstaller/Scoop/issues/4498
  ::    to make <USERPROFILE>\.config\scoop\config.json portable
  :: 2) shortcuts.ps1: appended empty functions override the upstream ones, so no start menu shortcuts are created
  :: 3) system.ps1: an appended empty Set-EnvVar overrides the upstream one, the only function that writes
  ::    persistent environment variables (Add-Path, Remove-Path, env_set, env_rm and the PSModulePath
  ::    handling all use it). scoop-portable sets the variables per session from .portable\active_versions.
  ::    It does nothing at all because the upstream one only writes the registry; Add-Path, Remove-Path, env_set and
  ::    env_rm update $env: themselves. The other callers only write the registry: ensure_in_psmodulepath in
  ::    lib\psmodules.ps1, whose modules folder scoop-portable therefore adds to PSModulePath when it loads,
  ::    Complete-ConfigChange in lib\core.ps1, which removes the previous PATH variable when use_isolated_path
  ::    changes, the deprecated env function in lib\system.ps1, and the cleanup below.
  ::    This also blocks the removals scoop writes to the registry, e.g. of a PATH entry an app's installer added
  ::    (ensure_install_dir_not_in_path in lib\install.ps1) or of variables that an older scoop-portable version
  ::    let scoop write. And as the shims and modules folders never get into the registry, scoop reports adding
  ::    them ("Adding ...\shims to your path.", "Adding ...\modules to your PowerShell module path.") whenever it
  ::    creates a shim or installs a module
  :: 4) install.ps1: the generated helper captures app hook settings without registry writes.
  ::    Its source is embedded below to keep distribution to one batch file. The marker is
  ::    written only after both the helper and its load statement are installed.
  ::
  :: $ErrorActionPreference = 'Stop' makes any failure, e.g. a locked file, exit with 1 before the marker is
  :: written, so that the next command retries. A patch whose upstream code or file is gone only warns (code
  :: is checked by counting: the upstream definition plus the appended one), because retrying would not help.
  :: The warnings start with what is gone, so that it stays on the first line when PowerShell wraps them.
  :: Only a missing lib\system.ps1 fails: it holds the Set-EnvVar override and the marker. scoop 0.4.0 and later
  :: cannot run without it anyway, and for older versions the error names a way to update scoop. It fails via
  :: Write-Host and exit, because an uncaught throw would also print an excerpt of this long one-line script as
  :: the error position.
  :: The marker is written last and names the patch set: define_scoop_patches and ensure_scoop_patched
  :: must agree, so that installations patched by an older scoop-portable version get re-patched.
  :: The script is one cmd line built with ^, so every line needs an even number of " and no ! may be used
  :: Read the root from the environment so apostrophes stay path data, not PowerShell syntax.
  set patch_scoop=^
    Set-StrictMode -version latest; ^
    $ErrorActionPreference = 'Stop'; ^
    $lib = $env:SCOOP + '\apps\scoop\current\lib'; ^
    function warn($msg) { Write-Warning ('scoop-portable: ' + $msg + ', so the installation may not be fully portable') }; ^
    function countOf($text, $str) { ([regex]::Matches($text, [regex]::Escape($str))).Count }; ^
    if (-not (Test-Path ($lib + '\system.ps1'))) { Write-Host ('ERROR: scoop-portable: lib\system.ps1 is missing, so scoop cannot be patched: ' + $lib); exit 1 }; ^
    $helper = (Get-Content -LiteralPath $env:scoop_portable_source -Raw) -split '(?m)^^:portable_environment_source\r?\n', 2; ^
    if ($helper.Count -ne 2) { throw 'Missing embedded portable environment helper' }; ^
    Set-Content -LiteralPath ($env:SCOOP + '\.portable\environment.ps1') -Value $helper[1] -NoNewline; ^
    ^
    if (Test-Path ($lib + '\install.ps1')) { ^
      $new = $old = Get-Content -LiteralPath ($lib + '\install.ps1') -Raw; ^
      $new = portableText 'lib/install.ps1' $old; ^
      if (-not $new.contains('function Invoke-HookScript {')) { warn 'function Invoke-HookScript is no longer defined in lib\install.ps1' }; ^
      if ($old -ne $new) { Set-Content -NoNewline -LiteralPath ($lib + '\install.ps1') -Value $new }; ^
    } else { warn 'lib\install.ps1 is missing' }; ^
    ^
    if (Test-Path ($lib + '\core.ps1')) { ^
      $new = $old = Get-Content -path ($lib + '\core.ps1') -raw; ^
      $new = portableText 'lib/core.ps1' $old; ^
      if (-not $new.contains('\"$env:SCOOP\.portable\"')) { warn '$env:XDG_CONFIG_HOME is no longer read in lib\core.ps1' }; ^
      if ($old -ne $new) { Set-Content -noNewline -path ($lib + '\core.ps1') -value $new }; ^
    } else { warn 'lib\core.ps1 is missing' }; ^
    ^
    if (Test-Path ($lib + '\shortcuts.ps1')) { ^
      $new = $old = Get-Content -path ($lib + '\shortcuts.ps1') -raw; ^
      $new = portableText 'lib/shortcuts.ps1' $old; ^
      foreach ($f in $shortcutFunctions) { ^
        if ((countOf $new $f) -lt 2) { warn ($f.split('(')[0] + ' is no longer defined in lib\shortcuts.ps1') }; ^
      }; ^
      if ($old -ne $new) { Set-Content -noNewline -path ($lib + '\shortcuts.ps1') -value $new }; ^
    } else { warn 'lib\shortcuts.ps1 is missing' }; ^
    ^
    $new = $old = Get-Content -path ($lib + '\system.ps1') -raw; ^
    $new = portableText 'lib/system.ps1' $old; ^
    if ((countOf $new 'function Set-EnvVar {') -lt 2) { warn 'function Set-EnvVar is no longer defined in lib\system.ps1' }; ^
    if ($old -ne $new) { Set-Content -noNewline -path ($lib + '\system.ps1') -value $new }; ^
    #

  powershell -noprofile -ex unrestricted -command "%scoop_patch_functions% %patch_scoop%" 1>&2 || (
    REM scoop older than 0.4.0 has no lib\system.ps1. It can update itself once directly, as the
    REM patches of the older scoop-portable version that installed it keep that run portable, but
    REM only with autostash_on_conflict, which scoop has since 0.3.0, see update_scoop
    if not exist "%SCOOP%\apps\scoop\current\lib\system.ps1" (
      >&2 echo scoop is probably older than 0.4.0. Update it once without scoop-portable:
      >&2 echo   "%SCOOP%\shims\scoop.cmd" config autostash_on_conflict true
      >&2 echo   "%SCOOP%\shims\scoop.cmd" update
    )
    exit /B 1
  )
goto :eof



:ensure_scoop_patched
  :: ##########################################################################
  :: patch scoop unless the current patches are in place. Called before each
  :: intercepted command, after scoop updated itself (update_scoop), and again
  :: after commands in case scoop updated itself within them after all.
  :: patch_scoop writes this marker last and only after all patches succeeded.
  :: It names the patch set (keep it in sync with define_scoop_patches), so installations
  :: patched by an older scoop-portable version get the current patches, too.
  :: ##########################################################################
  :: A copied installation or manual cleanup can lose the generated helper while retaining the marker.
  if not exist "%SCOOP%\.portable\environment.ps1" (
    call :patch_scoop
    exit /B
  )
  findstr /L /C:"# scoop-portable-patches: 6" "%SCOOP%\apps\scoop\current\lib\system.ps1" >NUL 2>NUL || call :patch_scoop
goto :eof



:update_scoop_before_command
  :: args: <SCOOP_ARG,...>
  :: for the commands that accept --no-update-scoop (install, download, virustotal): scoop must
  :: not update itself within them (see update_scoop_if_outdated), so it updates itself before,
  :: if needed. Like in scoop itself, the command continues if that update fails, but only if
  :: scoop is still patched. Fails only then.
  :: -u and --no-update-scoop skip the update, like in scoop itself, where they also keep the
  :: command from updating scoop. has_short_option also finds -u in combined short options like -ku
  call :has_short_option u %* && goto :eof
  call :has_arg --no-update-scoop %* && goto :eof
  call :update_scoop_if_outdated || call :ensure_scoop_patched
goto :eof



:update_scoop_if_outdated
  :: ##########################################################################
  :: let scoop update itself in a run of its own (update_scoop) if it would
  :: otherwise do so within the next command. There, the update replaces the
  :: patched lib files on disk while the command runs, and scripts the command
  :: starts afterwards load the unpatched files, e.g. scoop-uninstall.ps1 for a
  :: failed app (ensure_none_failed in lib\install.ps1) or scoop-install.ps1
  :: per app of "scoop import". These then write persistent environment
  :: variables. Fails if scoop could not update itself; it would then try again
  :: within the next command.
  :: ##########################################################################
  call :is_scoop_up_to_date && goto :eof
  call :update_scoop update
goto :eof



:update_scoop
  :: args: <UPDATE_ARG,...>
  :: runs "scoop update" without apps, cleans verified patch-only stashes and re-patches the pulled lib files.
  :: Fails if the update or re-patching failed.
  :: scoop also exits with 0 if it could not update itself, but only a completed update run sets its
  :: last update time, so success is checked with is_scoop_up_to_date. A completed run did not
  :: necessarily pull, e.g. it skips that while scoop is held, and a failed update within 2 hours
  :: after a successful one counts as success, too. Both are harmless: what matters is that scoop
  :: does not try to update itself within the next command, which a recent last update ensures
  setlocal
  :: a git based scoop can only update itself with the patched lib files in place with
  :: autostash_on_conflict: it then stashes them before pulling. Without it, scoop skips its
  :: update ("Uncommitted changes detected. Update aborted."), but still records it as done, so
  :: the check below would not notice. So it is set for this run only, whatever the user or an
  :: imported Scoopfile set before: when scoop still updates itself within another command, e.g.
  :: within an import that runs longer than an hour, it must skip that update instead, as the
  :: scripts that command starts afterwards would load the pulled, unpatched lib files
  call "%SCOOP%\shims\scoop.cmd" config autostash_on_conflict true >NUL || exit /B 1
  :: scoop's unpatched code reads its config from XDG_CONFIG_HOME: after pulling its update, the
  :: parallel bucket sync of PowerShell 7 dot-sources the pulled, unpatched lib\core.ps1 within the
  :: same run. Only set here, in the runs that pull scoop's update, so that the apps and tools
  :: started by other scoop commands keep the user's value, e.g. git reads its config from there.
  :: Trade-off within these runs: git then reads %SCOOP%\.portable\git\config instead of
  :: %USERPROFILE%\.config\git\config, so settings made only there (not in %USERPROFILE%\.gitconfig),
  :: e.g. a proxy, do not apply while scoop updates itself
  set "XDG_CONFIG_HOME=%SCOOP%\.portable"
  call "%SCOOP%\shims\scoop.cmd" %*
  set rc=%errorlevel%
  :: Clean and re-patch also after a failed update: scoop may have stashed the patches before its pull failed.
  :: The setting is removed after re-patching, so that scoop never runs unpatched. If re-patching
  :: fails, it stays set, but no command runs until patching succeeds, and the next update of
  :: scoop removes it
  call :drop_scoop_stashes
  call :ensure_scoop_patched || exit /B 1
  call "%SCOOP%\shims\scoop.cmd" config rm autostash_on_conflict >NUL || call :log_WARN Could not remove autostash_on_conflict from the scoop config. scoop may then pull unpatched lib files when it updates itself within another command
  if not "%rc%" == "0" exit /B %rc%
  call :is_scoop_up_to_date || (
    call :log_WARN scoop could not update itself
    exit /B 1
  )
goto :eof



:drop_scoop_stashes
  :: Scoop's automatic stashes can include user edits in the very same files as our patches.
  :: A matching message or filename is not proof of ownership. Drop only entries whose saved
  :: working tree AND index match the exact current patches applied to that stash's own base.
  :: Keep untracked files, mode changes, unknown/older patches and anything we cannot read.
  :: Stash parents 1, 2 and 3 hold the base, saved index and optional untracked files, respectively.
  :: Git blobs are read as strict UTF-8 bytes: native PowerShell output decoding and line splitting
  :: could hide user edits. Ordinal comparison also preserves case and whitespace differences.
  :: cat-file receives only hexadecimal object IDs from the validated diff, never saved filenames.
  :: The diff disables external helpers and checks submodules; replacement objects are ignored
  :: so verification reads the objects actually saved in the stash. Saved code is never executed.
  :: Drop older entries first and recheck each reference's object ID before dropping it, since
  :: another Git operation may have changed the stash numbering while we inspected its contents.
  :: Cleanup failures only warn: keeping a stash is harmless, guessing could delete user work.
  :: Get-Command can return several git.exe paths. Use the first, as normal command lookup does,
  :: so both native invocation and Process.StartInfo receive one executable path.
  :: The script is one cmd line built with ^; literal ^, | and & need ^^, ^| and ^&.
  setlocal
  call :define_scoop_patches
  set drop_scoop_stashes=^
    $ErrorActionPreference = 'Stop'; ^
    $dir = $env:SCOOP + '\apps\scoop\current'; ^
    if (-not (Test-Path ($dir + '\.git'))) { exit 0 }; ^
    $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue ^| Select-Object -First 1; ^
    if (-not $git) { exit 0 }; ^
    $git = $git.Source; ^
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true); ^
    function readBlob($object) { ^
      $process = New-Object System.Diagnostics.Process; ^
      $bytes = New-Object System.IO.MemoryStream; ^
      try { ^
        $process.StartInfo.FileName = $git; ^
        $process.StartInfo.Arguments = '--no-replace-objects cat-file blob ' + $object; ^
        $process.StartInfo.WorkingDirectory = $dir; ^
        $process.StartInfo.UseShellExecute = $false; ^
        $process.StartInfo.CreateNoWindow = $true; ^
        $process.StartInfo.RedirectStandardOutput = $true; ^
        [void]$process.Start(); ^
        $process.StandardOutput.BaseStream.CopyTo($bytes); ^
        $process.WaitForExit(); ^
        if ($process.ExitCode -ne 0) { throw 'Cannot read stash blob' }; ^
        return $utf8.GetString($bytes.ToArray()); ^
      } finally { $bytes.Dispose(); $process.Dispose() } ^
    }; ^
    function assertPortableTree($base, $tree) { ^
      $changes = @(^& $git --no-replace-objects -C $dir diff-tree -r --no-commit-id --no-abbrev --no-renames --no-ext-diff --no-textconv --ignore-submodules=none $base $tree); ^
      if ($LASTEXITCODE -ne 0) { throw 'Cannot compare stash trees' }; ^
      foreach ($change in $changes) { ^
        if ($change -cnotmatch '^^:(100644^|100755) \1 ([0-9a-f]{40,64}) ([0-9a-f]{40,64}) M\t((?:lib/(?:core^|shortcuts^|system^|install)^|libexec/scoop-import)\.ps1)$') { throw 'Unrecognized stash change' }; ^
        $oldObject = $matches[2]; $newObject = $matches[3]; $file = $matches[4]; ^
        $expected = portableText $file (readBlob $oldObject); ^
        if (-not [string]::Equals($expected, (readBlob $newObject), [StringComparison]::Ordinal)) { throw 'Stash contains other edits' }; ^
      } ^
    }; ^
    $entries = @(^& $git --no-replace-objects -C $dir stash list --format='%%gd %%H %%gs'); ^
    if ($LASTEXITCODE -ne 0) { Write-Warning ('scoop-portable: could not list stashes in ' + $dir); exit 0 }; ^
    [array]::Reverse($entries); ^
    foreach ($entry in $entries) { ^
      if ($entry -notmatch '^^(stash@\{\d+\}) ([0-9a-f]{40,64}) On [^^:]+: WIP at \d{4}-') { continue }; ^
      $ref = $matches[1]; $object = $matches[2]; ^
      try { ^
        $parents = @(^& $git --no-replace-objects -C $dir rev-list --parents -n 1 $object); ^
        if ($LASTEXITCODE -ne 0 -or $parents.Count -ne 1) { throw 'Cannot read stash parents' }; ^
        $parents = $parents[0].Split(' '); ^
        if ($parents.Count -notin 3, 4) { throw 'Unrecognized stash structure' }; ^
        if ($parents.Count -eq 4) { ^
          $untracked = @(^& $git --no-replace-objects -C $dir ls-tree -r --name-only $parents[3]); ^
          if ($LASTEXITCODE -ne 0 -or $untracked.Count) { throw 'Untracked stash content' }; ^
        }; ^
        assertPortableTree $parents[1] $object; ^
        assertPortableTree $parents[1] $parents[2]; ^
      } catch { ^
        Write-Warning ('scoop-portable: kept the stash entry ' + $ref + ' in ' + $dir + ', as it may hold changes of the user'); ^
        continue; ^
      }; ^
      $current = ^& $git --no-replace-objects -C $dir rev-parse --verify $ref; ^
      if ($LASTEXITCODE -ne 0 -or $current -cne $object) { Write-Warning 'scoop-portable: stash list changed during cleanup; remaining entries kept'; exit 0 }; ^
      ^& $git --no-replace-objects -C $dir stash drop -q $ref; ^
      if ($LASTEXITCODE -ne 0) { Write-Warning ('scoop-portable: could not drop the stash entry ' + $ref + ' in ' + $dir); exit 0 }; ^
    }; ^
    #

  powershell -noprofile -command "%scoop_patch_functions% %drop_scoop_stashes%" 1>&2 || call :log_WARN Could not inspect scoop stashes; remaining entries kept
goto :eof



:is_scoop_up_to_date
  :: succeeds if scoop's last update is less than 2 hours ago. scoop updates itself within a
  :: command when it is 3 hours or more ago (is_scoop_outdated in lib\core.ps1), so the hour in
  :: between keeps a command that starts right after this check from doing so. Like there, a
  :: missing or unreadable last update counts as outdated.
  :: The config file is chosen like in lib\core.ps1: %SCOOP%\config.json if it exists, else the
  :: one in .portable (where the patched core.ps1 looks). Only its existence counts, like there:
  :: a broken %SCOOP%\config.json does not fall back to the other file.
  :: $env:SCOOP instead of '%SCOOP%': an apostrophe in the path would end the PowerShell string early.
  :: The script is one cmd line built with ^, so a literal ^ or | is written as ^^ or ^|, and no
  :: " or ! may be used
  setlocal
  set is_scoop_up_to_date=^
    $ErrorActionPreference = 'Stop'; ^
    try { ^
      $file = $env:SCOOP + '\config.json'; ^
      if (-not (Test-Path $file)) { $file = $env:SCOOP + '\.portable\scoop\config.json' }; ^
      $config = Get-Content -raw -path $file ^| ConvertFrom-Json; ^
      if (((Get-Date) - [datetime]$config.last_update).TotalHours -lt 2) { exit 0 } ^
    } catch { }; ^
    exit 1; ^
    #

  powershell -noprofile -command "%is_scoop_up_to_date%"
goto :eof



:set_app_env_vars
  :: ##########################################################################
  :: set app specific env variables
  :: ##########################################################################
  setlocal EnableDelayedExpansion
  for /F %%f in ('dir /B "%SCOOP%\.portable\active_versions\*.env_add_path" 2^>NUL') do (
    call :read_first_line_of_file "%SCOOP%\.portable\active_versions\%%~f" path_to_add
    REM Remove the extension and final numeric suffix, preserving dots in the app name.
    for %%a in ("%%~nf") do set "app_name=%%~na"
    REM Manifest entries are app-relative. Hooks can add absolute paths, e.g. persist\bun\bin.
    REM fix_paths rebases those saved paths when the installation moves.
    if "!path_to_add:~1,1!" == ":" (
      call :extend_PATH "!path_to_add!"
    ) else if "!path_to_add:~0,2!" == "\\" (
      call :extend_PATH "!path_to_add!"
    ) else if "!path_to_add!" == "." (
      call :extend_PATH "%SCOOP%\apps\!app_name!\current"
    ) else (
      call :extend_PATH "%SCOOP%\apps\!app_name!\current\!path_to_add!"
    )
  )
  endlocal & set "PATH=%PATH%"

  setlocal
  for /F %%f in ('dir /B "%SCOOP%\.portable\active_versions\*.env_set.cmd" 2^>NUL') do (
    endlocal & call "%SCOOP%\.portable\active_versions\%%f"
    setlocal
  )
  endlocal

  if exist "%SCOOP%\apps\clink\current\clink.bat" (
    set "CLINK_PROFILE=%SCOOP%\persist\clink"
  )

  if exist "%SCOOP%\apps\nvm\current" (
    set "NVM_HOME=%SCOOP%\apps\nvm\current\nvm.exe"
    set "NVM_SYMLINK=%SCOOP%\persist\nvm\nodejs\nodejs"
    call :extend_PATH "%SCOOP%\persist\nvm\nodejs"
  )

  if exist "%SCOOP%\apps\git-with-openssh\current\git-cmd.exe" (
    call :append_PATH "%SCOOP%\apps\git-with-openssh\current\usr\bin"
    where /Q vi.exe || doskey vi=vim
  ) else if exist "%SCOOP%\apps\git\current\git-cmd.exe" (
    call :append_PATH "%SCOOP%\apps\git\current\usr\bin"
    where /Q vi.exe || doskey vi=vim
  )
goto :eof



:: ############################################################################
:: utility methods
::
:: NOTE: keep label lines free of any text after the label name and document
:: arguments on the next line. In some file layouts cmd executed the rest of a
:: label line as a command when the label was called, e.g. "[<RESULT_VAR>]"
:: created a file named "]".
:: ############################################################################

:append_PATH
  :: args: <PATH>
  call :replace_substrings PATH "%~1;" ""
  call :ends_with "%PATH%" ";" && set "PATH=%PATH%%~1;" || set "PATH=%PATH%;%~1;"
goto :eof

:extend_PATH
  :: args: <PATH>
  call :replace_substrings PATH "%~1;" ""
  set "PATH=%~1;%PATH%"
goto :eof


:exit_with_ERROR
  :: prints the error, waits so it can be read, and returns 1. It does NOT stop the
  :: caller: follow the call with "exit /B 1" where execution must not continue.
  :: only Windows 10+ supports ANSI
  if "%ANSICON%" == "1" (
    echo [91m[%time%] ERROR: %*[0m
  ) else (
    echo [%time%] ERROR: %*
  )
  %SystemRoot%\System32\timeout.exe /T 30
exit /B 1


:save_user_PATH
  :: Called with delayed expansion enabled. Pass the filename through the environment,
  :: not PowerShell source text; neither the raw PATH nor a Unicode filename crosses stdout.
  :: CreateNew in the helper prevents a collision from overwriting a recovery snapshot.
  set "scoop_path_snapshot=!TEMP!\scoop-portable-path-!RANDOM!-!RANDOM!.json"
  powershell -noprofile -ex unrestricted -command ^
    "$ErrorActionPreference = 'Stop'; try {" ^
    "  . ($env:SCOOP + '\.portable\environment.ps1'); Save-ScoopPortableUserPath $env:scoop_path_snapshot;" ^
    "} catch { [Console]::Error.WriteLine('ERROR: Could not save user PATH: ' + $_.Exception.Message); exit 1 }; exit 0"
exit /B


:restore_user_PATH
  :: Registry recovery must not depend on loading Scoop's possibly damaged files after
  :: a failed update. Only load its notifier after restoration has already succeeded.
  :: A failed restore exits before cleanup so its snapshot remains available for recovery.
  :: Scoop's notifier is best effort and does not report native delivery failures.
  :: Notification and snapshot cleanup failures warn; they do not undo a successful restore.
  powershell -noprofile -ex unrestricted -command ^
    "$ErrorActionPreference = 'Stop'; try {" ^
    "  . ($env:SCOOP + '\.portable\environment.ps1'); $changed = Restore-ScoopPortableUserPath $env:scoop_path_snapshot;" ^
    "} catch { [Console]::Error.WriteLine('ERROR: Could not restore user PATH. Snapshot retained at ' + $env:scoop_path_snapshot + ': ' + $_.Exception.Message); exit 1 };" ^
    "if ($changed) { Write-Host 'Restored user PATH.'; try {" ^
    "  . ($env:SCOOP + '\apps\scoop\current\lib\system.ps1'); Publish-EnvVar;" ^
    "} catch { Write-Warning ('User PATH was restored, but could not notify Windows: ' + $_.Exception.Message) } };" ^
    "try { [IO.File]::Delete($env:scoop_path_snapshot) } catch { Write-Warning ('User PATH was restored, but could not remove snapshot ' + $env:scoop_path_snapshot + ': ' + $_.Exception.Message) }; exit 0"
exit /B


:: ============================================================================
:: logging
:: ============================================================================

:log_HEADER
  :: args: <MSG,...>
  if "%ANSICON%" == "1" (
    echo [1m===========================================================[0m
    echo [%time%] [1m%*[0m
    echo [1m===========================================================[0m
  ) else (
    echo ===========================================================
    echo [%time%] %*
    echo ===========================================================
  )
  echo.
goto :eof


:log_TASK
  :: args: <MSG,...>
  :: only Windows 10+ supports ANSI
  if "%ANSICON%" == "1" (
    echo [%time%] [1m%*...[0m
  ) else (
    echo [%time%] %*...
  )
goto :eof


:log_WARN
  :: args: <MSG,...>
  :: only Windows 10+ supports ANSI
  if "%ANSICON%" == "1" (
    echo [%time%] [93mWARNING: %*[0m
  ) else (
    echo [%time%] WARNING: %*
  )
goto :eof


:log_SUCCESS
  :: args: <MSG,...>
  :: only Windows 10+ supports ANSI
  if "%ANSICON%" == "1" (
    echo [%time%] [92mSUCCESS: %*[0m
  ) else (
    echo [%time%] SUCCESS: %*
  )
goto :eof


:: ============================================================================
:: file system operations
:: ============================================================================

:read_first_line_of_file
  :: args: <FILE_PATH> <RESULT_VAR>
  setlocal
  set filePath=%~1
  set result_var=%~2
  set /P content=<"%filePath%"
  endlocal & set "%result_var%=%content%"
goto :eof


:mkdirs
  :: args: <PATH>
  :: like "mkdir -p" on Linux
  setlocal enableextensions
  if not exist %1 md %1
goto :eof


:: ============================================================================
:: string operations
:: ============================================================================
:ends_with
  :: args: <SEARCH_IN> <SEARCH_FOR>
  echo %~1|findstr /E /L %2 >NUL
goto :eof


:has_substring
  :: args: <SEARCH_IN> <SEARCH_FOR>
  setlocal
  set searchIn=%~1
  set searchFor=%~2
  set result=%searchIn%
  call :replace_substrings result "%searchFor%" ""
  if "%searchIn%" == "%result%" (
    REM substring not found
    exit /B 1
  )
goto :eof


:replace_substrings
  :: args: <VAR_NAME> <SEARCH_FOR> <REPLACE_WITH> [<RESULT_VAR>]
  setlocal
  set var_name=%~1
  set searchFor=%~2
  set replaceWith=%~3
  set result_var=%~4
  if "%result_var%"=="" set result_var=%var_name%

  :: CALL reparses expanded values: quote both assignments so directory names containing
  :: CMD metacharacters such as the ampersand in R&D remain literal data in either pass.
  call set "searchIn=%%%var_name%%%"
  call set "result=%%searchIn:%searchFor%=%replaceWith%%%"
  endlocal & set "%result_var%=%result%"
goto :eof


:substring_before
  :: args: <SEARCH_IN> <SEARCH_FOR> <RESULT_VAR>
  setlocal
  set searchIn=%~1
  set separator=%~2
  set result_var=%~3
  for /F "delims=%separator%" %%a in ("%searchIn%") do (
    endlocal & set "%result_var%=%%a"
    exit /B 0
  )
goto :eof


:: ============================================================================
:: arg parsing
:: ============================================================================

:filter_scoop_update_args
  :: args: <COMMAND> <ARG,...>; returns app_update_args and scoop_named.
  :: Called inside the interceptor's SETLOCAL with delayed expansion, so these outputs stay local.
  :: SHIFT avoids wildcard expansion. Compare unquoted values, but forward the raw tokens so
  :: quoted paths, -- and empty "" arguments retain their meaning. A raw empty token ends the list.
  :: SET has no outer quotes because a raw argument can itself quote text containing ampersands.
  set app_update_args=%1
  set "scoop_named="
  shift /1
  :filter_scoop_update_args___NEXT
    set update_arg=%1
    if not defined update_arg exit /B 0
    if /I "%~1" == "scoop" (
      set "scoop_named=true"
    ) else (
      set app_update_args=!app_update_args! !update_arg!
    )
    shift /1
    goto :filter_scoop_update_args___NEXT


:parse_reset_args
  :: args: <COMMAND> <ARG,...>; returns reset_all and reset_apps inside the interceptor's SETLOCAL.
  :: SHIFT keeps "*" literal; FOR would expand even a quoted wildcard to current-directory files.
  :: Unlike the generic flag helpers, reset must honor -- before deciding which apps to save.
  set "reset_all="
  set "reset_apps="
  set "reset_options=true"
  shift /1
  :parse_reset_args___NEXT
    REM Check the raw token so an empty quoted argument does not hide later targets.
    set reset_arg=%1
    if not defined reset_arg exit /B 0
    set "reset_arg=%~1"
    if "!reset_arg!" == "*" (
      set "reset_all=true"
    ) else (
      if defined reset_options (
        if "!reset_arg!" == "--" (
          set "reset_options="
          goto :parse_reset_args___ADVANCE
        )
        if /I "!reset_arg!" == "--all" (
          set "reset_all=true"
          goto :parse_reset_args___ADVANCE
        )
        if "!reset_arg:~0,1!" == "-" if not "!reset_arg!" == "-" (
          REM Reset supports only -a, including repetitions such as -aa and uppercase -A.
          set "reset_option=!reset_arg:~1!"
          set "reset_option=!reset_option:a=!"
          if defined reset_option (
            REM Scoop rejects unknown options before resetting any app. Do not save targets
            REM collected before that error, even if they included a bulk reset.
            set "reset_all="
            set "reset_apps="
            exit /B 0
          )
          set "reset_all=true"
          goto :parse_reset_args___ADVANCE
        )
      )
      set reset_apps=!reset_apps! "!reset_arg!"
    )
    :parse_reset_args___ADVANCE
    shift /1
    goto :parse_reset_args___NEXT


:has_arg
  :: args: <SEARCH_FOR> <ARG,...>
  setlocal
  set "search_for=%~1" & shift /1
  set empty_args=0

  REM not using "for %%a in (%*)" which automatically expands wildcard arguments
  :has_arg___CHECK_NEXT_ARG
    set "arg=%~1"
    REM ignores case like scoop's getopt, which takes e.g. -A for -a and --GLOBAL for --global
    if /I "%arg%" == "%search_for%" exit /B 0
    if "%arg%" == "" (
      REM stop looping if more than 6 empty args in a row were found. this is a workaround for the fact that one cannot
      REM distinguish between an empty "" argument and the end of the argument list
      if %empty_args% == 6 (
        exit /B 1
      ) else (
        set /a empty_args+=1
      )
    ) else (
      set empty_args=0
    )
    shift /1
    goto :has_arg___CHECK_NEXT_ARG


:has_short_option
  :: args: <LETTER> <ARG,...>
  :: succeeds if an argument with a single leading "-" contains the letter, in any case. scoop's
  :: getopt also accepts combined short options like -qa for -q -a, which has_arg cannot find.
  :: Option values and app names do not start with "-" (e.g. "-a 64bit" of scoop install), so
  :: they are not mistaken for options
  setlocal EnableDelayedExpansion
  set "letter=%~1" & shift /1
  set empty_args=0

  REM not using "for %%a in (%*)" which automatically expands wildcard arguments
  :has_short_option___CHECK_NEXT_ARG
    set "arg=%~1"
    if "!arg!" == "" (
      REM see has_arg for why the loop ends after 6 empty args in a row
      if !empty_args! == 6 exit /B 1
      set /a empty_args+=1
    ) else (
      set empty_args=0
      REM "--" starts a long option instead. Removing the letter (which ignores case) changes
      REM the argument only if it contains the letter
      if "!arg:~0,1!" == "-" if not "!arg:~1,1!" == "-" if not "!arg:%letter%=!" == "!arg!" exit /B 0
    )
    shift /1
    goto :has_short_option___CHECK_NEXT_ARG


:get_positional_args
  :: args: <RESULT_VAR>
  setlocal EnableDelayedExpansion
  set result_var=%~1
  set args=
  :: /%* makes the first arg (containing the result var name) a flag so it is ignored in the loop
  for %%a in (/%*) do (
    set a=%%~a
    set first_char=!a:~0,1!
    if not "!first_char!" == "-" (
      if not "!first_char!" == "/" (
          set args=!args! "!a!"
      )
    )
  )
  endlocal & set %result_var%=%args%
goto :eof


:get_1st_positional_arg
  :: args: <RESULT_VAR> <ARG,...>
  call :get_nth_positional_arg 1 %*
goto :eof


:get_2nd_positional_arg
  :: args: <RESULT_VAR> <ARG,...>
  call :get_nth_positional_arg 2 %*
goto :eof


:get_nth_positional_arg
  :: args: <ARG_INDEX> <RESULT_VAR> <ARG,...>
  setlocal EnableDelayedExpansion
  set "wanted_pos_arg_index=%~1" & shift /1
  set "result_var=%~1" & shift /1
  set current_pos_arg_index=0

  REM not using "for %%a in (%*)" which automatically expands wildcard arguments
  :get_nth_positional_arg___CHECK_NEXT_ARG
    set "arg=%~1"
    if "%arg%" == "" (
      REM no more arguments - requested positional argument does not exist
      exit /B 1
    )
    set first_char=%arg:~0,1%
    if not "%first_char%" == "-" (
      if not "%first_char%" == "/" (
         set /A current_pos_arg_index=%current_pos_arg_index%+1
         if !current_pos_arg_index! equ %wanted_pos_arg_index% (
           endlocal & set "%result_var%=%arg%"
           exit /B 0
         )
      )
    )
    shift /1
    goto :get_nth_positional_arg___CHECK_NEXT_ARG


:: The remaining text is extracted as PowerShell data, never executed by CMD.
goto :eof
:portable_environment_source
# Generated as .portable/environment.ps1 from the distribution batch file.
# Captures app-owned hook settings and reconciles the environment of the selected
# version. Hook scripts run only in Scoop's installation process; loading a CMD
# session replays saved data and never writes persistent environment variables.
# Refresh and uninstall share ownership rules for the saved app state.
# Explicit updates also use this helper to restore the user's original registry
# PATH if an app installer changes it outside Scoop's patched environment helpers.

# Set-EnvVar carries no type information. These shared search variables have list
# semantics; guessing from semicolons would turn ordinary scalar settings into lists.
$script:ScoopPortableSearchPaths = @('PKG_CONFIG_PATH', 'CMAKE_PREFIX_PATH')

function Save-ScoopPortableUserPath([string]$SnapshotFile, [string]$RegistrySubKey = 'Environment') {
    $ErrorActionPreference = 'Stop'
    # RegistrySubKey is internal: tests use an isolated HKCU key, while the wrapper
    # always uses Environment. Never store a destination key in the snapshot itself.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistrySubKey)
    $snapshot = @{ exists = $false; kind = $null; value = $null }
    try {
        if ($key -and ($key.GetValueNames() -contains 'Path')) {
            $snapshot.exists = $true
            $snapshot.kind = $key.GetValueKind('Path').ToString()
            # Refuse an unexpected type before updating, rather than coercing and
            # potentially destroying a registry value we cannot faithfully restore.
            if ($snapshot.kind -notin 'String', 'ExpandString') { throw 'User PATH has an unsupported registry type' }
            # Keep %NAME% references literal instead of freezing their current expansion.
            $snapshot.value = $key.GetValue('Path', $null, 'DoNotExpandEnvironmentNames')
        }
    } finally {
        if ($key) { $key.Dispose() }
    }

    # Exclusive creation protects retained snapshots, and explicit UTF-16 preserves
    # Unicode in Windows PowerShell regardless of its default text-file encoding.
    $stream = [IO.File]::Open($SnapshotFile, 'CreateNew', 'Write', 'None')
    $writer = $null
    try {
        $writer = [IO.StreamWriter]::new($stream, [Text.Encoding]::Unicode)
        $writer.Write(($snapshot | ConvertTo-Json -Compress))
    } finally {
        if ($writer) { $writer.Dispose() } else { $stream.Dispose() }
    }
}

function Restore-ScoopPortableUserPath([string]$SnapshotFile, [string]$RegistrySubKey = 'Environment') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    $snapshot = Get-Content -LiteralPath $SnapshotFile -Raw -Encoding Unicode | ConvertFrom-Json
    # A damaged recovery file must fail before any registry write. In particular,
    # a missing/null value must not be interpreted as a request to remove PATH.
    if ($snapshot.exists -isnot [bool] -or ($snapshot.exists -and
        ($snapshot.kind -notin 'String', 'ExpandString' -or $snapshot.value -isnot [string]))) {
        throw 'Invalid user PATH snapshot'
    }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistrySubKey)
    try {
        $exists = $key -and ($key.GetValueNames() -contains 'Path')
        # Compare raw text exactly, including case. Reading first also lets an
        # unchanged PATH succeed without write permission or creating a missing key.
        if ($snapshot.exists -eq $exists -and (-not $exists -or
            ($snapshot.kind -eq $key.GetValueKind('Path').ToString() -and
            [string]::Equals($snapshot.value, $key.GetValue('Path', $null, 'DoNotExpandEnvironmentNames'), 'Ordinal')))) {
            return $false
        }
    } finally {
        if ($key) { $key.Dispose() }
    }

    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($RegistrySubKey)
    try {
        # SetValue preserves an existing empty string; DeleteValue is only for an
        # originally absent PATH. Scoop's setter conflates these and is patched out.
        if ($snapshot.exists) { $key.SetValue('Path', $snapshot.value, [Microsoft.Win32.RegistryValueKind]$snapshot.kind) }
        else { $key.DeleteValue('Path', $false) }
    } finally {
        $key.Dispose()
    }
    # The wrapper owns notification and file cleanup. Keeping them outside registry
    # restoration leaves this function usable for isolated tests and manual recovery.
    return $true
}

function Get-ScoopPortableStateOwner([IO.FileInfo]$File) {
    # The final numeric component of a PATH filename is an index, even when an
    # app such as foo.1 exists. Snapshots have only their fixed extension.
    if ($File.Name -match '^(.+)\.(?:json|env_hooks)$' -or
        $File.Name -match '^(.+)\.[0-9]+\.env_add_path$') {
        return $Matches[1]
    }
    if ($File.Name.EndsWith('.env_set.cmd', [StringComparison]::OrdinalIgnoreCase)) {
        # Both app and variable names can contain dots. Read the generated SET
        # name as data, never execute the script or guess from another app's prefix.
        # Older versions wrote unquoted assignments; their files remain loadable.
        $firstLine = Get-Content -LiteralPath $File.FullName -TotalCount 1 -ErrorAction Stop
        if ($firstLine -match '^@set "?([^"=]+)=') {
            $suffix = ".$($Matches[1]).env_set.cmd"
            if ($File.Name.Length -gt $suffix.Length -and
                $File.Name.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
                return $File.Name.Substring(0, $File.Name.Length - $suffix.Length)
            }
        }
    }
    throw "Cannot identify the owner of portable settings file: $($File.FullName)"
}

function Remove-ScoopPortableInactiveVersions {
    $ErrorActionPreference = 'Stop'
    $envDir = Join-Path $env:SCOOP '.portable\active_versions'
    if (-not (Test-Path -LiteralPath $envDir)) { return }
    # Resolve ownership before deleting anything. A damaged script cannot safely
    # be assigned to an app, and an earlier cleanup may have lost its manifest.
    $inactiveFiles = @(foreach ($file in Get-ChildItem -LiteralPath $envDir -File) {
        if ($file.Name -notmatch '\.(json|env_hooks|env_add_path|env_set\.cmd)$') { continue }
        $appName = Get-ScoopPortableStateOwner $file
        if (-not (Test-Path -LiteralPath (Join-Path $env:SCOOP "apps\$appName\current"))) { $file }
    })
    # Keep version records until all derived state is removed. A failed deletion
    # leaves the records available for diagnosis and another cleanup attempt.
    foreach ($file in ($inactiveFiles | Sort-Object { $_.Extension -eq '.json' })) {
        Remove-Item -LiteralPath $file.FullName -Force
    }
}

function Save-ScoopPortableEnvironment([string]$AppName, [string]$SaveMode) {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    $envDir = Join-Path $env:SCOOP '.portable\active_versions'
    $appDir = Join-Path $env:SCOOP "apps\$AppName\current"
    $manifest = Get-Content -LiteralPath "$envDir\$AppName.json" -Raw | ConvertFrom-Json

    # Scoop replaces an entire property with a truthy architecture override.
    # Use the installed architecture, which need not match this machine.
    $architectures = $manifest.PSObject.Properties['architecture']
    if ($architectures -and $architectures.Value) {
        $architecture = (Get-Content -LiteralPath "$appDir\install.json" -Raw | ConvertFrom-Json).architecture
        $selected = $architectures.Value.PSObject.Properties[$architecture]
        if ($selected -and $selected.Value) {
            foreach ($name in 'env_set', 'env_add_path') {
                $property = $selected.Value.PSObject.Properties[$name]
                if ($property -and $property.Value) {
                    $manifest | Add-Member -NotePropertyName $name -NotePropertyValue $property.Value -Force
                }
            }
        }
    }

    $hooks = $null
    if (Test-Path -LiteralPath "$appDir\.scoop-portable-env.json") {
        $hooks = Get-Content -LiteralPath "$appDir\.scoop-portable-env.json" -Raw | ConvertFrom-Json
        # Like the manifest snapshot, this records the input, not successful generation.
        # It also prevents bulk scans from repeatedly selecting an unchanged, inactive JDK.
        Copy-Item -LiteralPath "$appDir\.scoop-portable-env.json" -Destination "$envDir\$AppName.env_hooks" -Force
    } elseif (Test-Path -LiteralPath "$envDir\$AppName.env_hooks") {
        Remove-Item -LiteralPath "$envDir\$AppName.env_hooks" -Force
    }
    function Convert-HookValue([string]$Value) {
        # Records belong to an installed version. Bind its original directory to
        # "current" and rebase other Scoop paths, including persist and dependencies.
        # One literal replacement pass avoids rebasing the new path again when the
        # installation moves into a subdirectory of its former root.
        $pattern = '(?:(?<app>' + [regex]::Escape($hooks.app_dir.TrimEnd('\')) + ')|' +
            [regex]::Escape($hooks.scoop_dir.TrimEnd('\')) + ')(?=[\\/]|$|[;"\s])'
        return [regex]::Replace($Value, $pattern, [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            if ($match.Groups['app'].Success) { $appDir } else { $env:SCOOP }
        }, 'IgnoreCase')
    }

    $envValues = @{}
    $envPathValues = @{}
    function Read-HookEnvironment($Phase) {
        $lists = $Phase.PSObject.Properties['env_path']
        foreach ($property in $Phase.env_set.PSObject.Properties) {
            $envValues[$property.Name] = Convert-HookValue $property.Value
            $envPathValues.Remove($property.Name)
            if ($lists) {
                $paths = $lists.Value.PSObject.Properties[$property.Name]
                if ($paths) {
                    $envPathValues[$property.Name] = @($paths.Value | ForEach-Object { Convert-HookValue $_ })
                }
            }
        }
    }
    $pathEntries = @()
    if ($hooks) {
        Read-HookEnvironment $hooks.before
        $pathEntries += @($hooks.before.env_add_path | ForEach-Object { Convert-HookValue $_ })
    }
    $envSet = $manifest.PSObject.Properties['env_set']
    if ($envSet -and $envSet.Value) {
        foreach ($property in $envSet.Value.PSObject.Properties) {
            # Keep the existing declarative substitution contract. Hook values have
            # already been evaluated by Scoop and must not be executed again.
            $envValues[$property.Name] = $property.Value.Replace('$dir', $appDir).Replace('$persist_dir', "$env:SCOOP\persist\$AppName")
            # A declaration replaces an earlier hook setting; only a later hook can
            # turn this value back into contributions to a shared search list.
            $envPathValues.Remove($property.Name)
        }
    }
    $envPath = $manifest.PSObject.Properties['env_add_path']
    if ($envPath -and $envPath.Value) { $pathEntries += @($envPath.Value) }
    if ($hooks) {
        # Installer hooks precede declarative settings; post_install follows them.
        # Post-hook removals affect only paths this app owns, never the caller's PATH.
        foreach ($removed in $hooks.after.env_remove_path) {
            $pattern = Convert-HookValue $removed
            $pathEntries = @($pathEntries | Where-Object {
                $path = if ([IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $appDir $_ }
                $path -notlike $pattern
            })
        }
        $pathEntries += @($hooks.after.env_add_path | ForEach-Object { Convert-HookValue $_ })
        Read-HookEnvironment $hooks.after
    }

    $savedFiles = @(Get-ChildItem -LiteralPath $envDir -File)
    $otherJdks = @($savedFiles | Where-Object { $_.Name -like '*.JAVA_HOME.env_set.cmd' -and $_.Name -ne "$AppName.JAVA_HOME.env_set.cmd" })
    # Bulk updates and resets must not select an unselected JDK, including one whose hook sets JAVA_HOME.
    if ($SaveMode -eq 'keep_selected_jdk' -and $envValues.ContainsKey('JAVA_HOME') -and $otherJdks.Count) { return }

    # Render all outputs before touching existing files. The caller already saved
    # the raw manifest for relocation; that snapshot is not a generation-success marker.
    $envFiles = @{}
    foreach ($name in $envValues.Keys) {
        if ($envPathValues.ContainsKey($name)) {
            $paths = @($envPathValues[$name] | Select-Object -Unique)
            if (-not $paths.Count) { continue }
            # Replay only this app's contributions. Whole-value snapshots let the
            # last file erase other apps, or retain them after their hooks disappear.
            # Sentinel separators make duplicate removal match whole entries, including
            # the first and last; each reload can then prepend the group exactly once.
            $lines = @('@set "' + $name + '=;%' + $name + '%;"')
            foreach ($path in $paths) {
                $lines += '@set "' + $name + '=%' + $name + ':;' + $path + ';=;%"'
            }
            $lines += '@set "' + $name + '=%' + $name + ':~1,-1%"'
            $prefix = $paths -join ';'
            $lines += '@if defined ' + $name + ' (set "' + $name + '=' + $prefix + ';%' + $name +
                '%") else set "' + $name + '=' + $prefix + '"'
            $envFiles["$AppName.$name.env_set.cmd"] = $lines
            continue
        }
        # Quotes keep spaces and ampersands in ordinary environment values literal in CMD.
        $envFiles["$AppName.$name.env_set.cmd"] = '@set "' + $name + '=' + $envValues[$name] + '"'
    }
    $index = 0
    foreach ($path in $pathEntries) {
        $index++
        $envFiles["$AppName.$index.env_add_path"] = $path
    }
    # Writes are not transactional. Fail before pruning if a write fails; reset
    # retries generation from the manifest and captured hook record without rerunning hooks.
    foreach ($entry in $envFiles.GetEnumerator()) {
        Set-Content -LiteralPath (Join-Path $envDir $entry.Key) -Value $entry.Value
    }
    # Do not read files being regenerated: reset must repair even truncated outputs.
    # A prefix only selects candidates; foo's refresh must not prune foo.extra's files.
    foreach ($file in $savedFiles) {
        if (-not $file.Name.StartsWith("$AppName.", [StringComparison]::OrdinalIgnoreCase) -or
            $file.Name -notmatch '\.(env_set\.cmd|env_add_path)$' -or $envFiles.ContainsKey($file.Name)) { continue }
        if ((Get-ScoopPortableStateOwner $file) -eq $AppName) {
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
    if ($envFiles.ContainsKey("$AppName.JAVA_HOME.env_set.cmd")) {
        foreach ($jdk in $otherJdks) {
            $prefix = $jdk.Name.Substring(0, $jdk.Name.Length - 'JAVA_HOME.env_set.cmd'.Length)
            foreach ($file in $savedFiles) {
                if ($file.Name -match ('^' + [regex]::Escape($prefix) + '\d+\.env_add_path$')) {
                    Remove-Item -LiteralPath $file.FullName -Force
                }
            }
            Remove-Item -LiteralPath $jdk.FullName -Force
        }
    }
}

# install.ps1 defines the upstream function before dot-sourcing this helper.
# The separate saver process also loads this file, but never invokes hooks.
if (Test-Path function:\Invoke-HookScript) {
    $script:ScoopPortableInvokeHookScript = ${function:Invoke-HookScript}
}

function Invoke-HookScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('installer', 'pre_install', 'post_install', 'uninstaller', 'pre_uninstall', 'post_uninstall')]
        [string]$HookType,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject]$Manifest,
        [Parameter(Mandatory = $true)]
        [Alias('Arch', 'Architecture')]
        [ValidateSet('32bit', '64bit', 'arm64')]
        [string]$ProcessorArchitecture
    )

    # install_app supplies original_dir before creating the "current" junction.
    # Keep records inside that version so reset and updates select the matching data.
    # Only local installs own such records; global and uninstall calls continue
    # through the upstream function under the registry no-op.
    $portableOriginalDir = Get-Variable original_dir -ValueOnly -ErrorAction SilentlyContinue
    if ($HookType -notin @('pre_install', 'installer', 'post_install') -or $global -or -not $portableOriginalDir) {
        & $script:ScoopPortableInvokeHookScript @PSBoundParameters
        return
    }
    $portableFile = Join-Path $portableOriginalDir '.scoop-portable-env.json'
    $portableState = @{
        scoop_dir = $env:SCOOP
        app_dir = $portableOriginalDir
        before = @{ env_set = @{}; env_path = @{}; env_add_path = @() }
        after = @{ env_set = @{}; env_path = @{}; env_add_path = @(); env_remove_path = @() }
    }
    # Start a new record even when a reinstall removed all hooks. Otherwise old
    # additions could survive indefinitely in a reused installation directory.
    if ($HookType -ne 'pre_install' -and (Test-Path -LiteralPath $portableFile)) {
        $saved = Get-Content -LiteralPath $portableFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($phase in 'before', 'after') {
            foreach ($property in $saved.$phase.env_set.PSObject.Properties) {
                $portableState[$phase].env_set[$property.Name] = $property.Value
            }
            $lists = $saved.$phase.PSObject.Properties['env_path']
            if ($lists) {
                foreach ($property in $lists.Value.PSObject.Properties) {
                    $portableState[$phase].env_path[$property.Name] = @($property.Value)
                }
            }
            $portableState[$phase].env_add_path = @($saved.$phase.env_add_path)
        }
        $portableState.after.env_remove_path = @($saved.after.env_remove_path)
    }
    $portablePhase = if ($HookType -eq 'post_install') { 'after' } else { 'before' }
    $portableTarget = $portableState[$portablePhase]
    $portableManifestEnv = if ($portablePhase -eq 'after') { arch_specific 'env_set' $Manifest $ProcessorArchitecture }
    $portableVirtual = @{ PATH = $env:PATH }
    $portableOwnedPaths = '^(?:' + [regex]::Escape((Join-Path $env:SCOOP "apps\$app")) + '|' +
        [regex]::Escape((Join-Path $env:SCOOP "persist\$app")) + ')(?:\\|$)'
    $portableGetEnv = ${function:Get-EnvVar}
    $portableAddPath = ${function:Add-Path}
    $portableRemovePath = ${function:Remove-Path}

    # These overrides exist only while this hook executes. Read-after-write sees
    # captured values, while the global Set-EnvVar remains a no-op outside hooks.
    function Get-EnvVar {
        param([string]$Name, [switch]$Global)
        if ($Global) { return (& $portableGetEnv @PSBoundParameters) }
        if ($Name -eq 'PATH') { return $portableVirtual.PATH }
        if ($portableState.after.env_set.ContainsKey($Name)) { return $portableState.after.env_set[$Name] }
        if ($portableManifestEnv -and $portableManifestEnv.PSObject.Properties[$Name]) {
            return [Environment]::GetEnvironmentVariable($Name, 'Process')
        }
        if ($portableState.before.env_set.ContainsKey($Name)) { return $portableState.before.env_set[$Name] }
        if ($Name -in $script:ScoopPortableSearchPaths) {
            # Other portable apps live in the process environment, not the registry.
            # Exclude this app's inherited directories before recapturing it, so a
            # reinstall both records unchanged contributions and drops obsolete ones.
            $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
            if ($null -eq $value) { $value = & $portableGetEnv @PSBoundParameters }
            $paths = @($value -split ';' | Where-Object {
                $_ -and $_.Replace('/', '\') -notmatch $portableOwnedPaths
            })
            if ($paths.Count) { return ($paths -join ';') }
            # Preserve upstream's null result for an unset variable.
            return
        }
        & $portableGetEnv @PSBoundParameters
    }
    function Remove-PortableHookPath([string[]]$Path) {
        foreach ($phase in 'before', 'after') {
            $discarded, $kept = Split-PathLikeEnvVar $Path ($portableState[$phase].env_add_path -join ';')
            $portableState[$phase].env_add_path = @($kept -split ';' | Where-Object { $_ })
        }
    }
    function Set-EnvVar {
        param([string]$Name, [string]$Value, [switch]$Global)
        if ($Global) { return }
        if ($Name -ne 'PATH') {
            if ($Name -in $script:ScoopPortableSearchPaths) {
                $previous = @((Get-EnvVar $Name) -split ';' | Where-Object { $_ })
                $owned = @($portableState.before.env_path[$Name]) + @($portableState.after.env_path[$Name])
                # Keep the full value for read-after-write, but persist ownership
                # separately. Inherited entries from other apps or the caller must
                # not become this app's permanent contributions. App-local entries
                # also remain owned when they came from this app's declaration.
                $portableTarget.env_path[$Name] = @($Value -split ';' | Where-Object {
                    $_ -and ($_ -notin $previous -or $_ -in $owned -or
                        $_.Replace('/', '\') -match $portableOwnedPaths)
                })
            }
            $portableTarget.env_set[$Name] = $Value
            return
        }
        # Direct PATH assignments capture their additions, not a snapshot of the
        # host's registry or machine PATH. Add-Path/Remove-Path record their explicit
        # arguments below, including an addition already present in the current PATH.
        if (-not (Get-Variable portablePathHelper -ValueOnly -ErrorAction SilentlyContinue)) {
            $previous = @($portableVirtual.PATH -split ';' | Where-Object { $_ })
            $requested = @($Value -split ';' | Where-Object { $_ })
            $removed = @($previous | Where-Object { $_ -notin $requested })
            if ($removed.Count) { Remove-PortableHookPath $removed }
            if ($portablePhase -eq 'after') { $portableState.after.env_remove_path += $removed }
            $added = @($requested | Where-Object { $_ -notin $previous })
            [array]::Reverse($added)
            $portableTarget.env_add_path += $added
        }
        # Keep the value written through the helper, which can differ from $env:PATH
        # after a direct Set-EnvVar. Later Add-Path/Remove-Path calls must read it back.
        $portableVirtual.PATH = $Value
    }
    function Add-Path {
        param([string[]]$Path, [string]$TargetEnvVar = 'PATH', [switch]$Global, [switch]$Force, [switch]$Quiet)
        $portablePathHelper = $true
        & $portableAddPath @PSBoundParameters
        if ($Global) { return }
        Remove-PortableHookPath $Path
        $added = @(($Path -join ';') -split ';' | Where-Object { $_ })
        # The batch loader prepends one entry at a time, so store each group in
        # replay order. This preserves Scoop's ordering without freezing caller PATH.
        [array]::Reverse($added)
        $portableTarget.env_add_path += $added
    }
    function Remove-Path {
        param([string[]]$Path, [string]$TargetEnvVar = 'PATH', [switch]$Global, [switch]$Quiet, [switch]$PassThru)
        $portablePathHelper = $true
        & $portableRemovePath @PSBoundParameters
        if ($Global) { return }
        Remove-PortableHookPath $Path
        # Scoop accepts both arrays and semicolon-separated removal patterns.
        if ($portablePhase -eq 'after') {
            $portableState.after.env_remove_path += @(($Path -join ';') -split ';' | Where-Object { $_ })
        }
    }

    & $script:ScoopPortableInvokeHookScript @PSBoundParameters

    $hasSettings = $portableState.before.env_set.Count -or $portableState.before.env_add_path.Count -or
        $portableState.after.env_set.Count -or $portableState.after.env_add_path.Count -or $portableState.after.env_remove_path.Count
    if ($hasSettings -or (Test-Path -LiteralPath $portableFile)) {
        try {
            # Replace only after writing a complete JSON document. A failed hook or
            # blocked write must not silently advertise successfully captured settings.
            $portableState | ConvertTo-Json -Depth 6 |
                Set-Content -LiteralPath ($portableFile + '.tmp') -Encoding UTF8 -NoNewline -ErrorAction Stop
            Move-Item -LiteralPath ($portableFile + '.tmp') -Destination $portableFile -Force -ErrorAction Stop
        } catch {
            throw "scoop-portable: could not save hook settings for '$app'. Correct access to '$portableFile' and retry the install or update."
        }
    }
}
