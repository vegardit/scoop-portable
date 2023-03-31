:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:: config parameters for initial installation
:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

::set PROXY=http://myproxy.local:8080
set PROXY=

:: if set to true the Windows credentials of the logged-in user are used for proxy authentication
set PROXY_USE_WINDOWS_CREDENTIALS=false

:: if PROXY_USE_WINDOWS_CREDENTIALS is set to false, then use these credentials for proxy authentication
set PROXY_USER=
set PROXY_PASSWORD=

:: additional scoop buckets to register by default
set SCOOP_BUCKETS=extras java

:: packages to install by default
set SCOOP_PACKAGES=7zip ^
  bc ^
  clink ^
  cwrsync ^
  far ^
  gpg ^
  git-with-openssh ^
  jq ^
  netcat ^
  nodejs-lts ^
  openssl-mingw ^
  pulumi ^
  unzip ^
  upx ^
  yq ^
  wget ^
  zstd
