@echo off

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

popd
