[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Uri] $ManifestUri,
    [Parameter(Mandatory)]
    [string] $PublicKey,
    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'Common.ps1')

$root = Get-ProjectRoot
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path -Path $root -ChildPath '.packages'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

if ($ManifestUri.Scheme -ne 'https' -and
    -not (
        $ManifestUri.Scheme -eq 'http' -and
        $ManifestUri.Host -in @('localhost', '127.0.0.1')
    )) {
    throw 'HTTPS is required for data pack downloads.'
}
$python = Resolve-CommandPath -Name 'python.exe'
if (-not $python) {
    throw 'Python 3 is required for Ed25519 verification.'
}

$manifest = Join-Path -Path $OutputDirectory -ChildPath 'manifest.json'
$signature = "$manifest.sig"
$manifestTemporary = "$manifest.new"
$signatureTemporary = "$signature.new"
Invoke-WebRequest -UseBasicParsing -Uri $ManifestUri `
    -OutFile $manifestTemporary
Invoke-WebRequest -UseBasicParsing -Uri ([Uri]::new("$ManifestUri.sig")) `
    -OutFile $signatureTemporary
Move-Item -LiteralPath $manifestTemporary -Destination $manifest -Force
Move-Item -LiteralPath $signatureTemporary -Destination $signature -Force

$pipeline = Join-Path -Path $root -ChildPath 'tools\dictionary_pipeline.py'
Invoke-Checked -FilePath $python -ArgumentList @(
    $pipeline, 'verify',
    '--manifest', $manifest,
    '--signature', $signature,
    '--public-key', $PublicKey
) -FailureMessage 'Manifest Ed25519 verification failed'

$document = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
if ($document.schema -ne 1 -or -not $document.version) {
    throw 'Unsupported data pack manifest.'
}
$versionDirectory = Join-Path -Path $OutputDirectory `
    -ChildPath ([string]$document.version)
New-Item -ItemType Directory -Path $versionDirectory -Force | Out-Null
foreach ($artifact in $document.artifacts) {
    if (-not $artifact.url -or
        ([string]$artifact.sha256) -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'Artifact metadata is incomplete.'
    }
    $artifactUri = [Uri]::new($ManifestUri, [string]$artifact.url)
    $fileName = [IO.Path]::GetFileName($artifactUri.LocalPath)
    if (-not $fileName) {
        throw "Artifact URL has no file name: $artifactUri"
    }
    $destination = Join-Path -Path $versionDirectory -ChildPath $fileName
    Save-ResumableDownload -Uri $artifactUri -Destination $destination `
        -Sha256 ([string]$artifact.sha256)
    if ((Get-Item -LiteralPath $destination).Length -ne [long]$artifact.size) {
        throw "Artifact size mismatch: $destination"
    }
}
Copy-Item -LiteralPath $manifest, $signature `
    -Destination $versionDirectory -Force
Write-Host "Signed data pack downloaded and verified: $versionDirectory"
