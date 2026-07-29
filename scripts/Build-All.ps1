[CmdletBinding()]
param(
    [switch] $SkipAndroid,
    [switch] $SkipWindows
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'Common.ps1')

$root = Get-ProjectRoot
$toolchain = Use-MyDuoToolchain
if (-not $toolchain.Flutter) {
    throw 'Flutter 3.24.5 is required. Run .\scripts\Install-LocalToolchain.ps1'
}
$dart = Join-Path -Path (Split-Path -Parent $toolchain.Flutter) `
    -ChildPath 'dart.bat'
$python = Resolve-CommandPath -Name 'python.exe'
if (-not $python) {
    throw 'Python 3 is required for dictionary tooling checks.'
}

Push-Location -LiteralPath $root
try {
    & (Join-Path -Path $PSScriptRoot -ChildPath 'Test-Toolchain.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw 'Toolchain check failed.'
    }
    Invoke-Checked -FilePath $toolchain.Flutter -ArgumentList @(
        'create', '--platforms=android,windows',
        '--org', 'io.github.chingfuhan',
        '--project-name', 'myduo',
        '.'
    ) -FailureMessage 'flutter create failed'
    Invoke-Checked -FilePath $toolchain.Flutter -ArgumentList @('pub', 'get') `
        -FailureMessage 'flutter pub get failed'
    Invoke-Checked -FilePath $dart -ArgumentList @(
        'format', '--set-exit-if-changed', 'lib', 'test'
    ) -FailureMessage 'dart format changed files or failed'
    Invoke-Checked -FilePath $toolchain.Flutter -ArgumentList @('analyze') `
        -FailureMessage 'flutter analyze failed'
    Invoke-Checked -FilePath $toolchain.Flutter -ArgumentList @('test') `
        -FailureMessage 'flutter test failed'
    Invoke-Checked -FilePath $python -ArgumentList @(
        '-m', 'compileall', '-q', 'tools'
    ) -FailureMessage 'Python syntax check failed'
    Invoke-Checked -FilePath $python -ArgumentList @(
        '-m', 'unittest', 'discover', '-s', 'tools\tests', '-v'
    ) -FailureMessage 'Python tooling tests failed'

    if (-not $SkipAndroid) {
        & (Join-Path -Path $PSScriptRoot -ChildPath 'Build-Android.ps1')
        if ($LASTEXITCODE -ne 0) {
            throw 'Android build script failed.'
        }
    }
    if (-not $SkipWindows) {
        & (Join-Path -Path $PSScriptRoot -ChildPath 'Build-Windows.ps1')
        if ($LASTEXITCODE -ne 0) {
            throw 'Windows build script failed.'
        }
    }
    Write-Host 'Full build and verification completed.'
} finally {
    Pop-Location
}
