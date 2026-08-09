[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$manifest = Join-Path $PSScriptRoot '..\sidecar\relay-quota-host\Cargo.toml'
$crateRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $manifest)).Path
$target = Join-Path $crateRoot 'target'
$destination = Join-Path $PSScriptRoot '..\companion\Bin'
$sourceExe = Join-Path $target 'release\relay-quota-host.exe'
$destinationExe = Join-Path $destination 'relay-quota-host.exe'
$manifestPath = Join-Path $destination 'relay-quota-host.sha256'

& cargo build --manifest-path $manifest --release --locked
if ($LASTEXITCODE -ne 0) {
    throw 'Relay host release build failed.'
}

if (-not (Test-Path -LiteralPath $sourceExe -PathType Leaf)) {
    throw 'Relay host release binary was not produced.'
}

[IO.Directory]::CreateDirectory($destination) | Out-Null
Copy-Item -LiteralPath $sourceExe -Destination $destinationExe -Force
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destinationExe).Hash.ToUpperInvariant()
[IO.File]::WriteAllText(
    $manifestPath,
    "$hash`n",
    [Text.UTF8Encoding]::new($false)
)

Write-Output 'Relay quota host packaged.'
