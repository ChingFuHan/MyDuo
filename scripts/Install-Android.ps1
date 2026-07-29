[CmdletBinding()]
param(
    [string] $ApkPath,
    [switch] $StartEmulator,
    [string] $AvdName = 'MyDuo_API35'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'Common.ps1')

$root = Get-ProjectRoot
$toolchain = Use-MyDuoToolchain
if (-not $toolchain.AndroidSdk) {
    throw 'Android SDK is required.'
}
if (-not $ApkPath) {
    $ApkPath = Join-Path -Path $root `
        -ChildPath 'dist\android\myduo-test.apk'
}
$ApkPath = [IO.Path]::GetFullPath($ApkPath)
if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
    throw "APK not found: $ApkPath"
}

$adb = Join-Path -Path $toolchain.AndroidSdk -ChildPath 'platform-tools\adb.exe'
$emulator = Join-Path -Path $toolchain.AndroidSdk -ChildPath 'emulator\emulator.exe'
$avdManager = Join-Path -Path $toolchain.AndroidSdk `
    -ChildPath 'cmdline-tools\latest\bin\avdmanager.bat'

function Get-ReadyDevices {
    $lines = & $adb devices
    return @(
        $lines |
        Where-Object { $_ -match '^(\S+)\s+device$' } |
        ForEach-Object { $Matches[1] }
    )
}

$devices = @(Get-ReadyDevices)
if ($devices.Count -eq 0 -and $StartEmulator) {
    if (-not (Test-Path -LiteralPath $emulator -PathType Leaf) -or
        -not (Test-Path -LiteralPath $avdManager -PathType Leaf)) {
        throw 'Android emulator or avdmanager is missing.'
    }
    $avds = & $emulator -list-avds
    if ($avds -notcontains $AvdName) {
        $answer = 'no'
        $answer | & $avdManager create avd --force --name $AvdName `
            --package 'system-images;android-35;google_apis;x86_64' `
            --device 'pixel_6'
        if ($LASTEXITCODE -ne 0) {
            throw 'AVD creation failed.'
        }
    }
    $null = Start-Process -FilePath $emulator -ArgumentList @(
        '-avd', $AvdName,
        '-no-snapshot-save',
        '-no-boot-anim'
    ) -WindowStyle Hidden -PassThru

    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        Start-Sleep -Seconds 5
        $devices = @(Get-ReadyDevices)
        if ($devices.Count -gt 0) {
            $booted = (& $adb -s $devices[0] shell getprop sys.boot_completed) -join ''
            if ($booted.Trim() -eq '1') {
                break
            }
        }
    } while ([DateTime]::UtcNow -lt $deadline)
}

$devices = @(Get-ReadyDevices)
if ($devices.Count -eq 0) {
    throw (
        'No authorized Android device. Connect a device with USB debugging, or run ' +
        '.\scripts\Install-Android.ps1 -StartEmulator'
    )
}
$device = $devices[0]
Invoke-Checked -FilePath $adb -ArgumentList @(
    '-s', $device, 'install', '-r', $ApkPath
) -FailureMessage 'adb install -r failed'
Invoke-Checked -FilePath $adb -ArgumentList @(
    '-s', $device, 'shell', 'am', 'force-stop',
    'io.github.chingfuhan.myduo'
) -FailureMessage 'adb force-stop failed'
Invoke-Checked -FilePath $adb -ArgumentList @(
    '-s', $device, 'shell', 'am', 'start', '-W', '-n',
    'io.github.chingfuhan.myduo/io.github.chingfuhan.myduo.MainActivity'
) -FailureMessage 'Android Activity launch failed'

$packagePath = (& $adb -s $device shell pm path io.github.chingfuhan.myduo) -join ''
if ($LASTEXITCODE -ne 0 -or $packagePath -notmatch '^package:') {
    throw 'Installed Android package was not found.'
}
$focus = (& $adb -s $device shell dumpsys window) -join "`n"
if ($focus -notmatch 'io\.github\.chingfuhan\.myduo') {
    throw 'MyDuo is not visible in Android window state.'
}
Write-Host "Android install and launch verified on $device"
Write-Host $packagePath
