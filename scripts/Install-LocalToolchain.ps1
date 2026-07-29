[CmdletBinding()]
param(
    [switch] $InstallAndroidSystemImage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'Common.ps1')

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = Get-ProjectRoot
$cache = Join-Path -Path $root -ChildPath '.toolcache'
$tools = Join-Path -Path $root -ChildPath '.tools'
New-Item -ItemType Directory -Path $cache, $tools -Force | Out-Null

$flutterArchive = Join-Path -Path $cache `
    -ChildPath 'flutter_windows_3.24.5-stable.zip'
Save-ResumableDownload `
    -Uri 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.24.5-stable.zip' `
    -Destination $flutterArchive `
    -Sha256 'b8a7485acd3c6fb23a76b7ac09f89e8d93d62fbff7147c6f5f8c5686d949eeac'
$flutterRoot = Join-Path -Path $tools -ChildPath 'flutter'
$flutter = Join-Path -Path $flutterRoot -ChildPath 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutter -PathType Leaf)) {
    Expand-Archive -LiteralPath $flutterArchive -DestinationPath $tools -Force
}

$jdkArchive = Join-Path -Path $cache `
    -ChildPath 'OpenJDK17U-jdk_x64_windows_hotspot_17.0.20_8.zip'
Save-ResumableDownload `
    -Uri 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20%2B8/OpenJDK17U-jdk_x64_windows_hotspot_17.0.20_8.zip' `
    -Destination $jdkArchive `
    -Sha256 '418497be5cf585bdd2203d6486a565d66d3f5e992d5630d45104cb873fab8122'
$jdkRoot = Join-Path -Path $tools -ChildPath 'jdk-17'
$java = Get-ChildItem -LiteralPath $jdkRoot -Recurse -Filter 'java.exe' `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\bin\\java\.exe$' } |
    Select-Object -First 1
if (-not $java) {
    New-Item -ItemType Directory -Path $jdkRoot -Force | Out-Null
    Expand-Archive -LiteralPath $jdkArchive -DestinationPath $jdkRoot -Force
    $java = Get-ChildItem -LiteralPath $jdkRoot -Recurse -Filter 'java.exe' |
        Where-Object { $_.FullName -match '\\bin\\java\.exe$' } |
        Select-Object -First 1
}
$env:JAVA_HOME = $java.Directory.Parent.FullName
$env:Path = (Join-Path $env:JAVA_HOME 'bin') +
    [IO.Path]::PathSeparator + $env:Path

$androidArchive = Join-Path -Path $cache `
    -ChildPath 'commandlinetools-win-15859902_latest.zip'
Save-ResumableDownload `
    -Uri 'https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip' `
    -Destination $androidArchive `
    -Sha256 '90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a'
$sdkRoot = Join-Path -Path $tools -ChildPath 'android-sdk'
$commandLineRoot = Join-Path -Path $sdkRoot -ChildPath 'cmdline-tools'
$sdkManager = Join-Path -Path $commandLineRoot `
    -ChildPath 'latest\bin\sdkmanager.bat'
if (-not (Test-Path -LiteralPath $sdkManager -PathType Leaf)) {
    New-Item -ItemType Directory -Path $commandLineRoot -Force | Out-Null
    Expand-Archive -LiteralPath $androidArchive `
        -DestinationPath $commandLineRoot -Force
    $extracted = Join-Path -Path $commandLineRoot -ChildPath 'cmdline-tools'
    $safeExtracted = Assert-PathWithin -Root $tools -Target $extracted
    if (-not (Test-Path -LiteralPath $safeExtracted -PathType Container)) {
        throw 'Android command-line archive layout changed.'
    }
    Rename-Item -LiteralPath $safeExtracted -NewName 'latest'
}
$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot

$answers = 1..100 | ForEach-Object { 'y' }
$answers | & $sdkManager "--sdk_root=$sdkRoot" --licenses | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Android license acceptance failed: exit $LASTEXITCODE"
}
$packages = @(
    'platform-tools',
    'platforms;android-35',
    'build-tools;35.0.0',
    'emulator'
)
if ($InstallAndroidSystemImage) {
    $packages += 'system-images;android-35;google_apis;x86_64'
}
Invoke-Checked -FilePath $sdkManager `
    -ArgumentList (@("--sdk_root=$sdkRoot") + $packages) `
    -FailureMessage 'Android SDK package install failed'

Invoke-Checked -FilePath $flutter -ArgumentList @(
    'config', '--no-analytics', '--android-sdk', $sdkRoot,
    '--jdk-dir', $env:JAVA_HOME
) -FailureMessage 'Flutter configuration failed'

& (Join-Path -Path $PSScriptRoot -ChildPath 'Test-Toolchain.ps1')
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
