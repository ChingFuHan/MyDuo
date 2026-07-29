[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'Common.ps1')

function Assert-WindowsBundle {
    param(
        [Parameter(Mandatory)]
        [string] $Directory
    )
    $required = @(
        'myduo.exe',
        'flutter_windows.dll',
        'sqlite3.dll',
        'data',
        'data\flutter_assets',
        'data\flutter_assets\assets\data\seed_entries.json',
        'data\flutter_assets\assets\licenses\STARTER_DATA.md',
        'data\flutter_assets\THIRD_PARTY_NOTICES.md',
        'data\app.so'
    )
    foreach ($relative in $required) {
        $path = Join-Path -Path $Directory -ChildPath $relative
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Windows bundle item missing: $path"
        }
    }
    $dlls = Get-ChildItem -LiteralPath $Directory -Filter '*.dll' -File
    if (-not ($dlls.Name -contains 'flutter_windows.dll') -or
        -not ($dlls.Name -contains 'sqlite3.dll')) {
        throw 'Windows DLL verification failed.'
    }
}

$root = Get-ProjectRoot
$toolchain = Use-MyDuoToolchain
if (-not $toolchain.Flutter) {
    throw 'Flutter 3.24.5 is required.'
}

Push-Location -LiteralPath $root
$temporary = $null
try {
    Invoke-Checked -FilePath $toolchain.Flutter `
        -ArgumentList @('build', 'windows', '--release') `
        -FailureMessage 'Windows release build failed'
    $release = Join-Path -Path $root `
        -ChildPath 'build\windows\x64\runner\Release'
    Assert-WindowsBundle -Directory $release

    $dist = Join-Path -Path $root -ChildPath 'dist\windows'
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    $zip = Join-Path -Path $dist `
        -ChildPath 'myduo-windows-portable.zip'
    if (Test-Path -LiteralPath $zip) {
        Remove-Item -LiteralPath $zip -Force
    }
    Compress-Archive -Path (Join-Path -Path $release -ChildPath '*') `
        -DestinationPath $zip -CompressionLevel Optimal

    $temporary = Join-Path -Path ([IO.Path]::GetTempPath()) `
        -ChildPath ('myduo-portable-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $temporary -Force
    Assert-WindowsBundle -Directory $temporary

    $smokeResult = Join-Path -Path $temporary `
        -ChildPath 'smoke-test-result.json'
    $exe = Join-Path -Path $temporary -ChildPath 'myduo.exe'
    $smokeOutputArgument = '--smoke-output="{0}"' -f $smokeResult
    $process = Start-Process -FilePath $exe `
        -ArgumentList @('--smoke-test', $smokeOutputArgument) `
        -WorkingDirectory $temporary -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(60000)) {
        $process.Kill()
        throw 'Windows release smoke test timed out after 60 seconds.'
    }
    if ($process.ExitCode -ne 0) {
        throw "Windows release smoke test failed: exit $($process.ExitCode)"
    }
    if (-not (Test-Path -LiteralPath $smokeResult -PathType Leaf)) {
        throw 'Windows release smoke result file is missing.'
    }
    $result = Get-Content -LiteralPath $smokeResult -Raw | ConvertFrom-Json
    foreach ($check in @(
        'offline_query', 'favorite', 'history', 'fts5', 'tts_fallback', 'success'
    )) {
        if (-not ($result.PSObject.Properties.Name -contains $check) -or
            $result.$check -ne $true) {
            throw "Windows smoke check failed: $check"
        }
    }

    $checksumPath = Join-Path -Path $dist -ChildPath 'SHA256SUMS.txt'
    $line = "$(Get-Sha256 -LiteralPath $zip)  $(Split-Path -Leaf $zip)"
    [IO.File]::WriteAllText(
        $checksumPath,
        $line + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    $checksum = (Get-Content -LiteralPath $checksumPath) -split '\s{2}', 2
    if ((Get-Sha256 -LiteralPath $zip) -ne $checksum[0]) {
        throw 'Windows ZIP checksum verification failed.'
    }

    Write-Host "Windows bundle verified: $release"
    Write-Host "Portable ZIP extracted and verified: $zip"
    Write-Host "Offline query/favorite/history/FTS5/TTS smoke passed."
} finally {
    Pop-Location
    if ($temporary) {
        $tempRoot = [IO.Path]::GetTempPath()
        $safeTemporary = Assert-PathWithin -Root $tempRoot -Target $temporary
        if (Test-Path -LiteralPath $safeTemporary) {
            Remove-Item -LiteralPath $safeTemporary -Recurse -Force
        }
    }
}
