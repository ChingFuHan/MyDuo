[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'Common.ps1')

$root = Get-ProjectRoot
$toolchain = Use-MyDuoToolchain
if (-not $toolchain.Flutter -or -not $toolchain.AndroidSdk -or -not $toolchain.JavaHome) {
    throw 'Flutter, Android SDK, and JDK 17 are required.'
}

Push-Location -LiteralPath $root
try {
    Invoke-Checked -FilePath $toolchain.Flutter `
        -ArgumentList @('build', 'apk', '--release') `
        -FailureMessage 'Universal release APK build failed'
    Invoke-Checked -FilePath $toolchain.Flutter `
        -ArgumentList @('build', 'appbundle', '--release') `
        -FailureMessage 'Test-signed release AAB build failed'

    $sourceApk = Join-Path -Path $root `
        -ChildPath 'build\app\outputs\flutter-apk\app-release.apk'
    $sourceAab = Join-Path -Path $root `
        -ChildPath 'build\app\outputs\bundle\release\app-release.aab'
    if (-not (Test-Path -LiteralPath $sourceApk -PathType Leaf)) {
        throw "APK missing: $sourceApk"
    }
    if (-not (Test-Path -LiteralPath $sourceAab -PathType Leaf)) {
        throw "AAB missing: $sourceAab"
    }

    $dist = Join-Path -Path $root -ChildPath 'dist\android'
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    $apk = Join-Path -Path $dist -ChildPath 'myduo-test.apk'
    $aab = Join-Path -Path $dist -ChildPath 'myduo-test.aab'
    Copy-Item -LiteralPath $sourceApk -Destination $apk -Force
    Copy-Item -LiteralPath $sourceAab -Destination $aab -Force

    $buildTools = Join-Path -Path $toolchain.AndroidSdk `
        -ChildPath 'build-tools\35.0.0'
    $apksigner = Join-Path -Path $buildTools -ChildPath 'apksigner.bat'
    $aapt = Join-Path -Path $buildTools -ChildPath 'aapt.exe'
    $jar = Join-Path -Path $toolchain.JavaHome -ChildPath 'bin\jar.exe'
    $jarsigner = Join-Path -Path $toolchain.JavaHome -ChildPath 'bin\jarsigner.exe'
    foreach ($requiredTool in @($apksigner, $aapt, $jar, $jarsigner)) {
        if (-not (Test-Path -LiteralPath $requiredTool -PathType Leaf)) {
            throw "Verification tool missing: $requiredTool"
        }
    }

    Invoke-Checked -FilePath $apksigner `
        -ArgumentList @('verify', '--verbose', '--print-certs', $apk) `
        -FailureMessage 'APK signature verification failed'
    $badging = (& $aapt dump badging $apk) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw 'aapt dump badging failed.'
    }
    if ($badging -notmatch "package: name='io\.github\.chingfuhan\.myduo'") {
        throw 'APK package name is incorrect.'
    }
    if ($badging -notmatch (
        "launchable-activity: name='io\.github\.chingfuhan\.myduo\.MainActivity'"
    )) {
        throw 'APK launchable Activity is incorrect.'
    }
    $manifestTree = (& $aapt dump xmltree $apk AndroidManifest.xml) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $manifestTree -notmatch 'android.intent.action.MAIN') {
        throw 'APK AndroidManifest.xml MAIN intent verification failed.'
    }

    $apkEntries = & $jar tf $apk
    if ($LASTEXITCODE -ne 0 -or
        $apkEntries -notcontains 'AndroidManifest.xml' -or
        -not ($apkEntries -contains 'lib/armeabi-v7a/libflutter.so') -or
        -not ($apkEntries -contains 'lib/arm64-v8a/libflutter.so') -or
        -not ($apkEntries -contains 'lib/x86_64/libflutter.so') -or
        -not ($apkEntries -contains 'lib/armeabi-v7a/libsqlite3.so') -or
        -not ($apkEntries -contains 'lib/arm64-v8a/libsqlite3.so') -or
        -not ($apkEntries -contains 'lib/x86_64/libsqlite3.so')) {
        throw 'APK file structure verification failed.'
    }
    $aabEntries = & $jar tf $aab
    if ($LASTEXITCODE -ne 0 -or
        $aabEntries -notcontains 'base/manifest/AndroidManifest.xml' -or
        -not ($aabEntries -match '^base/lib/.+/libflutter\.so$') -or
        -not ($aabEntries -match '^base/lib/.+/libsqlite3\.so$')) {
        throw 'AAB file structure verification failed.'
    }
    $null = & $jarsigner -verify -verbose -certs $aab
    if ($LASTEXITCODE -ne 0) {
        throw 'AAB JAR signature verification failed.'
    }

    $checksumPath = Join-Path -Path $dist -ChildPath 'SHA256SUMS.txt'
    $checksumLines = @(
        "$(Get-Sha256 -LiteralPath $apk)  $(Split-Path -Leaf $apk)",
        "$(Get-Sha256 -LiteralPath $aab)  $(Split-Path -Leaf $aab)"
    )
    [IO.File]::WriteAllLines(
        $checksumPath,
        $checksumLines,
        [Text.UTF8Encoding]::new($false)
    )
    foreach ($line in Get-Content -LiteralPath $checksumPath) {
        $parts = $line -split '\s{2}', 2
        $target = Join-Path -Path $dist -ChildPath $parts[1]
        if ((Get-Sha256 -LiteralPath $target) -ne $parts[0]) {
            throw "Checksum verification failed: $target"
        }
    }

    Write-Host "Android artifacts verified: $apk"
    Write-Host "Android artifacts verified: $aab"
    Write-Host "Checksums verified: $checksumPath"
} finally {
    Pop-Location
}
