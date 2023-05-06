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
set SCOOP_BUCKETS=extras java sysinternals

:: packages to install by default
set SCOOP_PACKAGES=7zip ^
  bc ^
  cwrsync ^
  far ^
  git-with-openssh ^
  gsudo ^
  jq ^
  netcat ^
  nodejs-lts ^
  openssl-mingw ^
  pskill ^
  pslist ^
  psshutdown ^
  python ^
  upx ^
  yq ^
  wget ^
  zip ^
  zstd

:: install terminal extensions
set SCOOP_PACKAGES=%SCOOP_PACKAGES% ^
  clink ^
  clink-completions ^
  clink-flex-prompt ^
  conemu

:: install DevOps tools
set SCOOP_PACKAGES=%SCOOP_PACKAGES% ^
  ab ^
  act ^
  ctop ^
  gh ^
  k6 ^
  k9s ^
  kubectl ^
  kustomize ^
  lazydocker ^
  packer ^
  pulumi

:: install Java runtimes and tools
set SCOOP_PACKAGES=%SCOOP_PACKAGES% ^
  temurin8-jdk ^
  temurin11-jdk ^
  graalvm-jdk17 ^
  maven ^
  keystore-explorer

:: install Haxe compiler and runtimes
set SCOOP_PACKAGES=%SCOOP_PACKAGES% ^
  haxe ^
  hashlink ^
  neko
