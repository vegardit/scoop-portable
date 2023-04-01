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
  where /Q scoop && (
    goto :exit_with_ERROR Cannot install scoop, 'scoop' command already on PATH
  )

  :: https://github.com/ScoopInstaller/Scoop/wiki/Quick-Start#installing-scoop
  :: ==========================================================================
  :: default config, can be overridden via scoop-portable-config.cmd
  :: ==========================================================================
  setlocal EnableDelayedExpansion

  ::set PROXY=http://myproxy.local:8080
  set PROXY=

  :: if set to true the Windows credentials of the logged-in user are used for proxy authentication
  set PROXY_USE_WINDOWS_CREDENTIALS=false

  :: if PROXY_USE_WINDOWS_CREDENTIALS is set to false, then use these credentials for proxy authentication
  set PROXY_USER=
  set PROXY_PASSWORD=

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
    if ((Get-ExecutionPolicy).ToString() -notin @('Unrestricte', 'RemoteSigne', 'ByPass')) { ^
      Write-Host "[$(Get-Date -Format 'HH:mm:ss,ff')] Setting PowerShell ExecutionPolicy [RemoteSigned]..."; ^
      Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser ^
    }


  :: ==========================================================================
  call :log_TASK Downloading scoop installer
  :: ==========================================================================
  :: https://github.com/lukesampson/scoop/wiki/Using-Scoop-behind-a-proxy
  if not "%SCOOP_PROXY%" == "" (
    call :log_TASK Downloading scoop installer using proxy %SCOOP_PROXY%
    set "scoopProxy=[net.webrequest]::defaultwebproxy = new-object net.webproxy '%SCOOP_PROXY%';"
    if "%SCOOP_PROXY_USE_WINDOWS_CREDENTIALS%" == "true" (
      set "scoopProxy=!scoopProxy!; [net.webrequest]::defaultwebproxy.credentials = [net.credentialcache]::defaultcredentials;"
    ) else if not "%SCOOP_PROXY_USER%" == "" (
      set "scoopProxy=!scoopProxy!; [net.webrequest]::defaultwebproxy.credentials = new-object net.networkcredential '%SCOOP_PROXY_USER%', '%SCOOP_PROXY_PASSWORD%';"
    )
  )

  call :mkdirs "%SCOOP%\.portable"

  :: 1) replacing '$env:USERPROFILE\.config' is a workaround for https://github.com/ScoopInstaller/Scoop/issues/4498
  ::    to make <USERPROFILE>\.config\scoop\config.json portable
  :: 2) replacing '  Add-ShimsDirToPath' to prevent shim dir being permanently added to %PATH%
  powershell -noprofile -command !scoopProxy! ^
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; ^
    $installer_script = (New-Object System.Net.WebClient).DownloadString('https://get.scoop.sh'); ^
    $installer_script = $installer_script.replace('$env:XDG_CONFIG_HOME', '\"$env:SCOOP\.portable\"'); ^
    $installer_script = $installer_script -replace '\s\s+Add-ShimsDirToPath', ''; ^
    Invoke-Expression $installer_script || exit /B 1

  call :patch_scoop

  :: installing itself as scoop wrapper
  copy /Y "%~f0" "%SCOOP%\.portable\scoop.cmd" >NUL

  echo %USERDOMAIN%\%USERNAME%>"%SCOOP%\.portable\last.user"

  if not "%SCOOP_BUCKETS%" == "" (
    REM install git if not present - required for adding buckets
    where /Q git.exe
    if errorlevel 1 (
      call :has_substring "%SCOOP_PACKAGES%" "git-with-openssh"
      if errorlevel 1 (
        call :log_TASK Installing [git]
        call "%SCOOP%\.portable\scoop.cmd" install git
      ) else (
        call :log_TASK Installing [git-with-openssh]
        call "%SCOOP%\.portable\scoop.cmd" install git-with-openssh
      )
    )

    for %%b in (%SCOOP_BUCKETS%) do (
      call :log_TASK Adding scoop bucket [%%b]
      call "%SCOOP%\.portable\scoop.cmd" bucket add %%b
    )
  )

  if not "%SCOOP_PACKAGES%" == "" (
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

  set fix_paths=^
    Set-StrictMode -version latest; ^
    $curr_dir = (Get-Content -path '%SCOOP%\.portable\current.dir' -first 1).trim() + '\'; ^
    $last_dir = (Get-Content -path '%SCOOP%\.portable\last.dir'    -first 1).trim() + '\'; ^
    $last_dir_pattern = [regex]::escape($last_dir); ^
    ^
    function replaceScoopPaths($file_path) { ^
      if (Test-Path -path $file_path) { ^
        $old = Get-Content -path $file_path -raw; ^
        $new = $old -replace $last_dir_pattern,$curr_dir; ^
        if ($old -ne $new) { ^
          Write-Host "[$(Get-Date -Format 'HH:mm:ss,ff')] --^> Path updated in: $file_path"; ^
          Set-Content -noNewline -path $file_path -value $new; ^
        } ^
      } ^
    } ^
    ^
    replaceScoopPaths '%SCOOP%\.portable\scoop\config.json'; ^
    replaceScoopPaths '%SCOOP%\shims\scoop'; ^
    replaceScoopPaths '%SCOOP%\shims\scoop.cmd'; ^
    replaceScoopPaths '%SCOOP%\shims\scoop.ps1'; ^
    ^
    Get-ChildItem '%SCOOP%\.portable\active_versions' -file -filter *.env_set.cmd  ^| Foreach-Object { replaceScoopPaths $_.FullName }; ^
    Get-ChildItem '%SCOOP%\apps'                      -file -filter *.ini -recurse ^| Foreach-Object { replaceScoopPaths $_.FullName }; ^
    Get-ChildItem '%SCOOP%\shims'                     -file -filter *.shim         ^| Foreach-Object { replaceScoopPaths $_.FullName }; ^
    ^
    function fixAppCurrentVersionSymlinks($app_curr_ver_path) { ^
      $app_name = $app_curr_ver_path.Parent.Name; ^
      if ($app_name -eq 'scoop') { return; } ^
      $app_manifest = Get-Content -path "%SCOOP%\.portable\active_versions\$app_name.json" -raw ^| ConvertFrom-Json; ^
      $app_curr_ver = $app_manifest.version; ^
      fsutil reparsepoint delete $app_curr_ver_path ^| out-null; ^
      Remove-Item $app_curr_ver_path -recurse -force; ^
      New-Item -itemType Junction -path $app_curr_ver_path -target "%SCOOP%\apps\$app_name\$app_curr_ver" ^| out-null; ^
      Write-Host "[$(Get-Date -Format 'HH:mm:ss,ff')] --^> Junction updated: $app_curr_ver_path"; ^
      ^
      if ('persist' -in $app_manifest.PSobject.Properties.Name) { ^
        $app_manifest.persist ^| ForEach-Object { ^
          $app_persist_path = $_; ^
          if ((Get-Item "%SCOOP%\persist\$app_name\$app_persist_path") -is [System.IO.DirectoryInfo]) { ^
            fsutil reparsepoint delete "$app_curr_ver_path\$app_persist_path" ^| out-null; ^
            Remove-Item "$app_curr_ver_path\$app_persist_path" -recurse -force; ^
            New-Item -itemType Junction -path "$app_curr_ver_path\$app_persist_path" -target "%SCOOP%\persist\$app_name\$app_persist_path" ^| out-null; ^
            Write-Host "[$(Get-Date -Format 'HH:mm:ss,ff')] --^> Junction updated: $app_curr_ver_path\$app_persist_path"; ^
          } else { ^
            Remove-Item "$app_curr_ver_path\$app_persist_path" -force; ^
            New-Item -itemType HardLink -path "$app_curr_ver_path\$app_persist_path" -target "%SCOOP%\persist\$app_name\$app_persist_path" ^| out-null; ^
            Write-Host "[$(Get-Date -Format 'HH:mm:ss,ff')] --^> HardLink updated: $app_curr_ver_path\$app_persist_path"; ^
          } ^
        } ^
      } ^
    } ^
    ^
    Get-ChildItem '%SCOOP%\apps\*\*' -directory -filter current ^| Foreach-Object { fixAppCurrentVersionSymlinks $_ }; ^
    #

  powershell -noprofile -ex unrestricted -command "%fix_paths%" || exit /B 1
goto :eof



:intercept_scoop_command
  :: ##########################################################################
  :: wrapper for shims\scoop.cmd
  :: ##########################################################################

  :: ==========================================================================
  :: check if scoop [command] --help is requested
  :: ==========================================================================
  call :has_arg --help %* && (
    call "%SCOOP%\shims\scoop.cmd" %*
    goto :eof
  )

  setlocal EnableDelayedExpansion
  set scoop_command=%1

  :: ==========================================================================
  :: INTERCEPT scoop update
  :: ==========================================================================
  if "%scoop_command%" == "update" (
    call :get_2nd_positional_arg app_name %*
    if "!app_name!" == "" (
      set app_name=scoop
    )

    if !app_name! == scoop (
      call :unpatch_scoop
      set "XDG_CONFIG_HOME=%SCOOP%\.portable"
    )
    call "%SCOOP%\shims\scoop.cmd" %*
    set rc=!errorlevel!
    if !app_name! == scoop (
      call :patch_scoop
    ) else (
      REM /%* makes the first arg (the command) a flag so it is not treated as an app name
      call :get_positional_args apps /%*
      for %%a in (!apps!) do call :save_active_version %%a
    )
    exit /B !rc!
  )

  :: ==========================================================================
  :: INTERCEPT scoop install
  :: ==========================================================================
  if "%scoop_command%" == "install" (
    call :has_arg --global %* && set global_install=true
    call :has_arg -g %* && set global_install=true
    if "!global_install!" == "true" (
      goto :exit_with_ERROR Installing applications globally is not supported by scoop-portable.
    )

    call "%SCOOP%\shims\scoop.cmd" %*
    set rc=%errorlevel%

    REM /%* makes the first arg (the command) a flag so it is not treated as an app name
    call :get_positional_args apps /%*
    for %%a in (!apps!) do call :save_active_version %%a

    REM save app states of dependencies (if any)
    call :save_active_versions_of_new_apps
    endlocal
    call :set_app_env_vars
    exit /B !rc!
  )

  :: ==========================================================================
  :: INTERCEPT scoop uninstall
  :: ==========================================================================
  if "%scoop_command%" == "uninstall" (
    call :get_2nd_positional_arg app_name %*
    call "%SCOOP%\shims\scoop.cmd" %*
    set rc=%errorlevel%
    call :cleanup_active_versions
    exit /B !rc!
  )

  :: ==========================================================================
  :: INTERCEPT scoop reset
  :: ==========================================================================
  if "%scoop_command%" == "reset" (
    call "%SCOOP%\shims\scoop.cmd" %*
    set rc=%errorlevel%

    REM /%* makes the first arg (the command) a flag so it is not treated as an app name
    call :get_positional_args apps /%*
    for %%a in (!apps!) do call :save_active_version %%a

    endlocal
    call :set_app_env_vars
    exit /B !rc!
  )

  :: ==========================================================================
  :: EXECUTE other scoop command
  :: ==========================================================================
  call "%SCOOP%\shims\scoop.cmd" %*
  exit /B %errorlevel%
goto :eof



:save_active_versions_of_new_apps
  setlocal
  for /F %%f in ('dir /B "%SCOOP%\apps\*" 2^>NUL') do (
    if not exist "%SCOOP%\.portable\active_versions\%%~f.json" (
      call :save_active_version %%~f
    )
  )
goto :eof



:save_active_version <APP_NAME(@<APP_VERSION>)>
  setlocal
  call :mkdirs "%SCOOP%\.portable\active_versions"

  set app=%~1

  :: extract appname from app@version
  call :substring_before %app% @ app_name

  if not exist "%SCOOP%\apps\%app_name%\current\manifest.json" exit /B 0

  copy /Y "%SCOOP%\apps\%app_name%\current\manifest.json" "%SCOOP%\.portable\active_versions\%app_name%.json" >NUL

  :: check if expensive json parsing via powershell is necessary
  findstr /C:env_set /C:env_add_path "%SCOOP%\.portable\active_versions\%app_name%.json" >NUL
  if %errorlevel% == 1 exit /B 0

  :: the "if ($env_key -eq 'JAVA_HOME')" branch is for switching between different java versions to ensure only one is on PATH
  set save_env_additions= ^
    Set-StrictMode -version latest; ^
    $app_manifest = (Get-Content -path '%SCOOP%\.portable\active_versions\%app_name%.json' -raw ^| ConvertFrom-Json); ^
    if ('env_set' -in $app_manifest.PSobject.Properties.Name) { ^
      $app_manifest.env_set.PSObject.Properties ^| ForEach-Object { ^
        $env_key = $_.Name; ^
        $env_val = $_.Value.replace('$dir', '%SCOOP%\shims\%app_name%\current').replace('$persist_dir', '%SCOOP%\persist\%app_name%'); ^
        if ($env_key -eq 'JAVA_HOME') { ^
          Get-ChildItem -path '%SCOOP%\.portable\active_versions\*.JAVA_HOME.env_set.cmd' ^| ForEach-Object { ^
            $jdk_name = $_.Name.split('.JAVA_HOME')[0]; ^
            Remove-Item -path """%SCOOP%\.portable\active_versions\$jdk_name.*.env_add_path"""; ^
            Remove-Item  $_ -force; ^
          } ^
        } ^
        $env_cmd = """@set $env_key=$env_val"""; ^
        Set-Content -path """%SCOOP%\.portable\active_versions\%app_name%.$env_key.env_set.cmd""" -value $env_cmd; ^
      } ^
    } ^
    if ('env_add_path' -in $app_manifest.PSobject.Properties.Name) { ^
      $app_manifest.env_add_path ^| ForEach-Object -Begin {$i = 0} -Process { ^
        $i++; ^
        $env_add_path = $_; ^
        Set-Content -path """%SCOOP%\.portable\active_versions\%app_name%.$i.env_add_path""" -value $env_add_path; ^
      } ^
    } ^
    #

  powershell -noprofile -command "%save_env_additions%"
goto :eof



:cleanup_active_versions
  setlocal EnableDelayedExpansion

  for /F %%f in ('dir /B "%SCOOP%\.portable\active_versions\*.json" 2^>NUL') do (
    call :substring_before "%%~f" . app_name
    if not exist "%SCOOP%\apps\!app_name!\current" (
      del /F "%SCOOP%\.portable\active_versions\%%~f" >NUL
    )
  )

  for /F %%f in ('dir /B "%SCOOP%\.portable\active_versions\*.env_add_path" 2^>NUL') do (
    call :substring_before "%%~f" . app_name
    if not exist "%SCOOP%\apps\!app_name!\current" (
      del /F "%SCOOP%\.portable\active_versions\%%~f" >NUL
    )
  )

  for /F %%f in ('dir /B "%SCOOP%\.portable\active_versions\*.env_set.cmd" 2^>NUL') do (
    call :substring_before "%%~f" . app_name
    if not exist "%SCOOP%\apps\!app_name!\current" (
      del /F "%SCOOP%\.portable\active_versions\%%~f" >NUL
    )
  )
goto :eof



:patch_scoop
  :: ##########################################################################
  :: patch scoop to make it more portable
  :: ##########################################################################
  call :log_TASK Patching scoop
  setlocal

  :: replacing '$env:USERPROFILE\.config' is a workaround for https://github.com/ScoopInstaller/Scoop/issues/4498
  ::   to make <USERPROFILE>\.config\scoop\config.json portable
  ::
  :: -replace '\n\s+env 'PATH'.*?\r?\n', '' to prevent persistent changes to global PATH variable in core.ps1
  :: -replace '\n\s+env \$name.*?\r?\n', '' to prevent persistent changes to global PATH variable in install.ps1
  set patch_scoop=^
    Set-StrictMode -version latest; ^
    $new = $old = Get-Content -path '%SCOOP%\apps\scoop\current\lib\core.ps1' -raw; ^
    $new = $new.replace('$env:XDG_CONFIG_HOME', '\"$env:SCOOP\.portable\"'); ^
    $new = $new -replace '\n\s+env ''PATH''.*?\r?\n', ''; ^
    if ($old -ne $new) { Set-Content -noNewline -path '%SCOOP%\apps\scoop\current\lib\core.ps1' -value $new } ^
    ^
    $new = $old = Get-Content -path '%SCOOP%\apps\scoop\current\lib\install.ps1' -raw; ^
    $new = $new -replace '\n\s+env \$name.*?\r?\n', ''; ^
    if ($old -ne $new) { Set-Content -noNewline -path '%SCOOP%\apps\scoop\current\lib\install.ps1' -value $new } ^
    #

  powershell -noprofile -ex unrestricted -command "%patch_scoop%" || exit /B 1
goto :eof



:unpatch_scoop
  :: ##########################################################################
  :: revert scoop patches
  :: ##########################################################################
  if exist "%SCOOP%\apps\scoop\current\.git" (
    call :log_TASK Reverting scoop patch
    pushd "%SCOOP%\apps\scoop\current"
      git checkout "lib\core.ps1"
      git checkout "lib\install.ps1"
    popd
  )
goto :eof



:set_app_env_vars
  :: ##########################################################################
  :: set app specific env variables
  :: ##########################################################################
  setlocal EnableDelayedExpansion
  for /F %%f in ('dir /B "%SCOOP%\.portable\active_versions\*.env_add_path" 2^>NUL') do (
    call :read_first_line_of_file "%SCOOP%\.portable\active_versions\%%~f" path_to_add
    call :substring_before "%%~f" . app_name
    if "!path_to_add!" == "." (
      call :extend_PATH "%SCOOP%\apps\!app_name!\current"
    ) else (
      call :extend_PATH "%SCOOP%\apps\!app_name!\current\!path_to_add!"
    )
  )
  endlocal & set "PATH=%PATH%"

  for /F %%f in ('dir /B "%SCOOP%\.portable\active_versions\*.env_set.cmd" 2^>NUL') do (
    endlocal & call "%SCOOP%\.portable\active_versions\%%f"
    setlocal
  )

  if exist "%SCOOP%\apps\clink\current\clink.bat" (
    set "CLINK_PROFILE=%SCOOP%\persist\clink"
  )

  if exist "%SCOOP%\apps\nvm\current" (
    set "NVM_HOME=%SCOOP%\apps\nvm\current\nvm.exe"
    set "NVM_SYMLINK=%SCOOP%\persist\nvm\nodejs\nodejs"
    call :extend_PATH "%SCOOP%\persist\nvm\nodejs"
  )

  if exist "%SCOOP%\apps\git-with-openssh\current\git-cmd.exe" (
    set "GIT_INSTALL_ROOT=%SCOOP%\apps\git-with-openssh\current"
    call :append_PATH "%SCOOP%\apps\git-with-openssh\current\usr\bin"
    where /Q vi.exe || doskey vi=vim
  ) else if exist "%SCOOP%\apps\git\current\git-cmd.exe" (
    set "GIT_INSTALL_ROOT=%SCOOP%\apps\git\current"
    call :append_PATH "%SCOOP%\apps\git\\currentusr\bin"
    where /Q vi.exe || doskey vi=vim
  )
goto :eof



:: ############################################################################
:: utility methods
:: ############################################################################

:append_PATH <PATH>
  call :replace_substrings "%PATH%" "%~1;" "" PATH
  call :ends_with "%PATH%" ";" && set "PATH=%PATH%%~1;" || set "PATH=%PATH%;%%~1;"
goto :eof

:extend_PATH <PATH>
  call :replace_substrings "%PATH%" "%~1;" "" PATH
  set "PATH=%~1;%PATH%"
goto :eof


:exit_with_ERROR
  :: only Windows 10+ supports ANSI
  if "%ANSICON%" == "1" (
    echo [91m[%time%] ERROR: %*[0m
  ) else (
    echo [%time%] ERROR: %*
  )
  %SystemRoot%\System32\timeout.exe /T 30
exit /B 1


:: ============================================================================
:: logging
:: ============================================================================

:log_HEADER <MSG,...>
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


:log_TASK <MSG,...>
  :: only Windows 10+ supports ANSI
  if "%ANSICON%" == "1" (
    echo [%time%] [1m%*...[0m
  ) else (
    echo [%time%] %*...
  )
goto :eof


:log_WARN <MSG,...>
  :: only Windows 10+ supports ANSI
  if "%ANSICON%" == "1" (
    echo [%time%] [93mWARNING: %*[0m
  ) else (
    echo [%time%] WARNING: %*
  )
goto :eof


:log_SUCCESS <MSG,...>
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

:read_first_line_of_file <FILE_PATH> <RESULT_VAR>
  setlocal
  set filePath=%~1
  set result_var=%~2
  set /P content=<"%filePath%"
  endlocal & set "%result_var%=%content%"
goto :eof


:mkdirs <PATH>
  :: like "mkdir -p" on Linux
  setlocal enableextensions
  if not exist %1 md %1
goto :eof


:: ============================================================================
:: string operations
:: ============================================================================
:ends_with <SEARCH_IN> <SEARCH_FOR>
  echo %~1|findstr /E /L %2 >NUL
goto :eof


:has_substring <SEARCH_IN> <SEARCH_FOR>
  setlocal
  set searchIn=%~1
  set searchFor=%~2
  call :replace_substrings "%searchIn%" "%searchFor%" "" "result"
  if "%searchIn%" == "%result%" (
    REM substring not found
    exit /B 1
  )
goto :eof


:replace_substrings <SEARCH_IN> <SEARCH_FOR> <REPLACE_WITH> <RESULT_VAR>
  setlocal
  set searchIn=%~1
  set searchFor=%~2
  set replaceWith=%~3
  set result_var=%~4

  call set result=%%searchIn:%searchFor%=%replaceWith%%%
  endlocal & set "%result_var%=%result%"
goto :eof


:substring_before <SEARCH_IN> <SEARCH_FOR> <RESULT_VAR>
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

:has_arg <ARG_VALUE>
  setlocal
  set flag=%~1
  for %%a in (skipFirst%*) do (
    if "%%~a"=="%flag%" exit /B 0
  )
exit /B 1


:get_positional_args <RESULT_VAR>
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


:get_1st_positional_arg <RESULT_VAR> <ARG,...>
  call :get_nth_positional_arg 1 %*
goto :eof


:get_2nd_positional_arg <RESULT_VAR> <ARG,...>
  call :get_nth_positional_arg 2 %*
goto :eof


:get_nth_positional_arg <ARG_INDEX> <RESULT_VAR> <ARG,...>
  setlocal EnableDelayedExpansion
  set wanted_pos_arg_index=%~1
  set result_var=%~2
  set current_pos_arg_index=-2
  for %%a in (%*) do (
    set a=%%~a
    set first_char=!a:~0,1!
    if not "!first_char!" == "-" (
      if not "!first_char!" == "/" (
        set /A current_pos_arg_index=!current_pos_arg_index!+1
        if !current_pos_arg_index! equ %wanted_pos_arg_index% (
          endlocal & set "%result_var%=%%a"
          exit /B 0
        )
      )
    )
  )
goto :eof
