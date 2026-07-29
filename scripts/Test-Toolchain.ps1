[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'Common.ps1')

$toolchain = Use-MyDuoToolchain
$failures = [Collections.Generic.List[string]]::new()

Write-Check -Name 'PowerShell' -Passed ($PSVersionTable.PSVersion.Major -ge 5) `
    -Detail $PSVersionTable.PSVersion.ToString()

$git = Resolve-CommandPath -Name 'git.exe'
if ($git) {
    $gitVersion = (& $git --version) -join ' '
    Write-Check -Name 'Git' -Passed $true -Detail $gitVersion
} else {
    Write-Check -Name 'Git' -Passed $false `
        -Detail 'winget install --id Git.Git -e'
    $failures.Add('Git')
}

if ($toolchain.Flutter) {
    $flutterText = (& $toolchain.Flutter --version) -join "`n"
    $flutterOk = $flutterText -match 'Flutter 3\.24\.5'
    Write-Check -Name 'Flutter 3.24.5' -Passed $flutterOk `
        -Detail (($flutterText -split "`n")[0])
    if (-not $flutterOk) {
        $failures.Add('Flutter 3.24.5 exact version')
    }
} else {
    Write-Check -Name 'Flutter 3.24.5' -Passed $false `
        -Detail '.\scripts\Install-LocalToolchain.ps1'
    $failures.Add('Flutter 3.24.5')
}

$java = if ($toolchain.JavaHome) {
    Join-Path -Path $toolchain.JavaHome -ChildPath 'bin\java.exe'
} else {
    $null
}
if ($java -and (Test-Path -LiteralPath $java)) {
    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $javaText = (& $java -version 2>&1) -join ' '
        $javaExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorPreference
    }
    $javaOk = $javaExitCode -eq 0 -and $javaText -match 'version "17\.'
    Write-Check -Name 'JDK 17' -Passed $javaOk -Detail $javaText
    if (-not $javaOk) {
        $failures.Add('JDK 17')
    }
} else {
    Write-Check -Name 'JDK 17' -Passed $false `
        -Detail 'winget install --id EclipseAdoptium.Temurin.17.JDK -e'
    $failures.Add('JDK 17')
}

$sdk = $toolchain.AndroidSdk
if ($sdk) {
    $platform = Join-Path -Path $sdk -ChildPath 'platforms\android-35\android.jar'
    $buildTools = Join-Path -Path $sdk -ChildPath 'build-tools\35.0.0'
    $adb = Join-Path -Path $sdk -ChildPath 'platform-tools\adb.exe'
    $apiOk = Test-Path -LiteralPath $platform -PathType Leaf
    $buildToolsOk = (Test-Path -LiteralPath (
        Join-Path -Path $buildTools -ChildPath 'aapt.exe'
    )) -and (Test-Path -LiteralPath (
        Join-Path -Path $buildTools -ChildPath 'apksigner.bat'
    ))
    $adbOk = Test-Path -LiteralPath $adb -PathType Leaf
    Write-Check -Name 'Android SDK API 35' -Passed $apiOk -Detail $platform
    Write-Check -Name 'Android Build Tools 35.0.0' -Passed $buildToolsOk `
        -Detail $buildTools
    Write-Check -Name 'adb' -Passed $adbOk -Detail $adb
    if (-not $apiOk) { $failures.Add('Android SDK API 35') }
    if (-not $buildToolsOk) { $failures.Add('Android Build Tools 35.0.0') }
    if (-not $adbOk) { $failures.Add('adb') }
} else {
    Write-Check -Name 'Android SDK' -Passed $false `
        -Detail '.\scripts\Install-LocalToolchain.ps1 -InstallAndroidSystemImage'
    $failures.Add('Android SDK')
}

$vswhere = Join-Path -Path ${env:ProgramFiles(x86)} `
    -ChildPath 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = $null
if (Test-Path -LiteralPath $vswhere) {
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
}
$vsOk = [bool]$vsPath
Write-Check -Name 'Visual Studio 2022 Desktop C++' -Passed $vsOk `
    -Detail $(if ($vsOk) {
        $vsPath
    } else {
        'winget install --id Microsoft.VisualStudio.2022.BuildTools -e ' +
        '--override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools ' +
        '--includeRecommended"'
    })
if (-not $vsOk) {
    $failures.Add('Visual Studio 2022 Desktop C++')
}

$cmake = $null
$ninja = $null
if ($vsOk) {
    $cmakeRoot = Join-Path -Path $vsPath -ChildPath (
        'Common7\IDE\CommonExtensions\Microsoft\CMake'
    )
    $cmake = Get-ChildItem -LiteralPath $cmakeRoot -Recurse -Filter 'cmake.exe' `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    $ninja = Get-ChildItem -LiteralPath $cmakeRoot -Recurse -Filter 'ninja.exe' `
        -ErrorAction SilentlyContinue | Select-Object -First 1
}
Write-Check -Name 'CMake' -Passed ([bool]$cmake) `
    -Detail $(if ($cmake) { $cmake.FullName } else { 'Install VS C++ CMake tools' })
Write-Check -Name 'Ninja' -Passed ([bool]$ninja) `
    -Detail $(if ($ninja) { $ninja.FullName } else { 'Install VS C++ CMake tools' })
if (-not $cmake) { $failures.Add('CMake') }
if (-not $ninja) { $failures.Add('Ninja') }

$windowsSdkRoot = Join-Path -Path ${env:ProgramFiles(x86)} `
    -ChildPath 'Windows Kits\10\Include'
$windowsSdk = Get-ChildItem -LiteralPath $windowsSdkRoot -Directory `
    -ErrorAction SilentlyContinue | Sort-Object Name -Descending |
    Select-Object -First 1
Write-Check -Name 'Windows SDK' -Passed ([bool]$windowsSdk) `
    -Detail $(if ($windowsSdk) {
        $windowsSdk.Name
    } else {
        'Visual Studio Installer: Windows 11 SDK'
    })
if (-not $windowsSdk) { $failures.Add('Windows SDK') }

if ($failures.Count -gt 0) {
    Write-Error ('Missing or incompatible: ' + ($failures -join ', '))
    exit 1
}

if ($toolchain.Flutter) {
    Invoke-Checked -FilePath $toolchain.Flutter -ArgumentList @('doctor', '-v') `
        -FailureMessage 'flutter doctor failed'
}
Write-Host 'Toolchain check passed.'
