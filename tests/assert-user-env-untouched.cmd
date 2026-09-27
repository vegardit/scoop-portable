@echo off
:: CI test helper: fails (exit 1, like eval.cmd) if a persistent user environment variable
:: contains the path of the scoop-portable installation in %SCOOP%, i.e. if scoop wrote
:: e.g. JAVA_HOME or its shims folder to the user environment instead of scoop-portable
:: setting them per session. Shared by test-scoop.cmd and test-update.cmd.
:: Compares text, so it relies on scoop writing paths in the same form as %SCOOP%, which
:: holds in CI; a different spelling of the same folder would not be detected
echo ::group::no user environment variable points into [%SCOOP%]
:: PowerShell because findstr treats backslashes in search strings as escapes.
:: Stop: a failed registry read must fail the check, otherwise it finds nothing and passes
powershell -noprofile -command ^
  "$ErrorActionPreference = 'Stop';" ^
  "$key = Get-Item 'HKCU:\Environment';" ^
  "$hits = $key.GetValueNames() | Where-Object { ([string]$key.GetValue($_, '', 'DoNotExpandEnvironmentNames')).IndexOf($env:SCOOP, [StringComparison]::OrdinalIgnoreCase) -ge 0 };" ^
  "$hits | ForEach-Object { Write-Host ('ERROR: user environment variable [' + $_ + '] points into [' + $env:SCOOP + ']!') };" ^
  "if ($hits) { exit 1 }" || exit 1
echo ::endgroup::
