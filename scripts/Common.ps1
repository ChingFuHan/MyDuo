Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = [IO.Path]::GetFullPath(
    (Join-Path -Path $PSScriptRoot -ChildPath '..')
)

function Get-ProjectRoot {
    return $script:ProjectRoot
}

function Import-CompatibleFileHash {
    if (Get-Command -Name Get-FileHash -ErrorAction SilentlyContinue) {
        return
    }
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $manifest = Join-Path -Path $PSHOME -ChildPath (
            'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1'
        )
        if (Test-Path -LiteralPath $manifest) {
            Import-Module -Name $manifest -Force -ErrorAction Stop
        }
    }
    if (-not (Get-Command -Name Get-FileHash -ErrorAction SilentlyContinue)) {
        throw 'Get-FileHash is unavailable in this PowerShell installation.'
    }
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory)]
        [string] $LiteralPath
    )
    Import-CompatibleFileHash
    return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Save-ResumableDownload {
    param(
        [Parameter(Mandatory)]
        [Uri] $Uri,
        [Parameter(Mandatory)]
        [string] $Destination,
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{64}$')]
        [string] $Sha256
    )
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    $destinationDirectory = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        if ((Get-Sha256 -LiteralPath $destinationPath) -eq $Sha256.ToLowerInvariant()) {
            Write-Host "Verified cached download: $destinationPath"
            return
        }
    }
    $partial = "$destinationPath.part"
    if (Test-Path -LiteralPath $partial -PathType Leaf) {
        if ((Get-Sha256 -LiteralPath $partial) -eq $Sha256.ToLowerInvariant()) {
            Move-Item -LiteralPath $partial -Destination $destinationPath -Force
            return
        }
    }
    $existing = if (Test-Path -LiteralPath $partial) {
        (Get-Item -LiteralPath $partial).Length
    } else {
        0L
    }
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.UserAgent = 'MyDuo-PowerShell/1.0'
    $request.AllowAutoRedirect = $true
    if ($existing -gt 0) {
        $request.AddRange($existing)
    }
    $response = $request.GetResponse()
    try {
        $append = $existing -gt 0 -and
            [int]$response.StatusCode -eq [int][Net.HttpStatusCode]::PartialContent
        $mode = if ($append) {
            [IO.FileMode]::Append
        } else {
            [IO.FileMode]::Create
        }
        $file = [IO.File]::Open(
            $partial,
            $mode,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try {
            $stream = $response.GetResponseStream()
            try {
                $stream.CopyTo($file)
                $file.Flush($true)
            } finally {
                $stream.Dispose()
            }
        } finally {
            $file.Dispose()
        }
    } finally {
        $response.Dispose()
    }
    $actual = Get-Sha256 -LiteralPath $partial
    if ($actual -ne $Sha256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $partial -Force
        throw "SHA-256 mismatch for $Uri. Expected $Sha256, got $actual"
    }
    Move-Item -LiteralPath $partial -Destination $destinationPath -Force
}

function Resolve-CommandPath {
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [string[]] $Candidates = @()
    )
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) {
        return $command.Source
    }
    return $null
}

function Get-JavaHome {
    $localJdk = Join-Path -Path $script:ProjectRoot -ChildPath '.tools\jdk-17'
    if (Test-Path -LiteralPath $localJdk -PathType Container) {
        $java = Get-ChildItem -LiteralPath $localJdk -Recurse -Filter 'java.exe' |
            Where-Object { $_.FullName -match '\\bin\\java\.exe$' } |
            Select-Object -First 1
        if ($java) {
            return $java.Directory.Parent.FullName
        }
    }
    if ($env:JAVA_HOME) {
        $java = Join-Path -Path $env:JAVA_HOME -ChildPath 'bin\java.exe'
        if (Test-Path -LiteralPath $java -PathType Leaf) {
            return [IO.Path]::GetFullPath($env:JAVA_HOME)
        }
    }
    $javaCommand = Resolve-CommandPath -Name 'java.exe'
    if ($javaCommand) {
        return (Split-Path -Parent (Split-Path -Parent $javaCommand))
    }
    return $null
}

function Get-AndroidSdkRoot {
    $localSdk = Join-Path -Path $script:ProjectRoot -ChildPath '.tools\android-sdk'
    if (Test-Path -LiteralPath $localSdk -PathType Container) {
        return [IO.Path]::GetFullPath($localSdk)
    }
    foreach ($candidate in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Use-MyDuoToolchain {
    $flutter = Resolve-CommandPath -Name 'flutter.bat' -Candidates @(
        (Join-Path -Path $script:ProjectRoot -ChildPath '.tools\flutter\bin\flutter.bat')
    )
    $javaHome = Get-JavaHome
    $androidSdk = Get-AndroidSdkRoot

    if ($javaHome) {
        $env:JAVA_HOME = $javaHome
    }
    if ($androidSdk) {
        $env:ANDROID_HOME = $androidSdk
        $env:ANDROID_SDK_ROOT = $androidSdk
    }

    $pathParts = [Collections.Generic.List[string]]::new()
    if ($flutter) {
        $pathParts.Add((Split-Path -Parent $flutter))
    }
    if ($javaHome) {
        $pathParts.Add((Join-Path -Path $javaHome -ChildPath 'bin'))
    }
    if ($androidSdk) {
        $pathParts.Add((Join-Path -Path $androidSdk -ChildPath 'platform-tools'))
        $pathParts.Add((Join-Path -Path $androidSdk -ChildPath 'emulator'))
    }
    $pathParts.Add($env:Path)
    $env:Path = $pathParts -join [IO.Path]::PathSeparator

    return [pscustomobject]@{
        Flutter   = $flutter
        JavaHome  = $javaHome
        AndroidSdk = $androidSdk
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,
        [Parameter()]
        [string[]] $ArgumentList = @(),
        [string] $FailureMessage = 'Command failed'
    )
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage (exit $LASTEXITCODE): $FilePath"
    }
}

function Assert-PathWithin {
    param(
        [Parameter(Mandatory)]
        [string] $Root,
        [Parameter(Mandatory)]
        [string] $Target
    )
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $resolvedTarget = [IO.Path]::GetFullPath($Target)
    if (-not $resolvedTarget.StartsWith(
        $resolvedRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Unsafe path outside root: $resolvedTarget"
    }
    return $resolvedTarget
}

function New-CleanDirectory {
    param(
        [Parameter(Mandatory)]
        [string] $Root,
        [Parameter(Mandatory)]
        [string] $Path
    )
    $safePath = Assert-PathWithin -Root $Root -Target $Path
    if (Test-Path -LiteralPath $safePath) {
        Remove-Item -LiteralPath $safePath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $safePath -Force | Out-Null
    return $safePath
}

function Write-Check {
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [bool] $Passed,
        [Parameter(Mandatory)]
        [string] $Detail
    )
    $prefix = if ($Passed) { '[OK]' } else { '[MISSING]' }
    Write-Host "$prefix $Name - $Detail"
}
