#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $PSScriptRoot '..\companion\Bin'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'native') -Filter '*.cs' -File | Sort-Object Name)
if ($sourceFiles.Count -ne 3) { throw 'The native helper sources are incomplete.' }
$sourceText = ($sourceFiles | ForEach-Object {
    $_.Name + "`n" + [IO.File]::ReadAllText($_.FullName).Replace("`r`n", "`n")
}) -join "`n"
$sourceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sourceText)))
$destinationPath = [IO.Path]::GetFullPath($Destination)
$assemblyPath = Join-Path $destinationPath 'CodexQuotaMonitor.Native.dll'
$manifestPath = Join-Path $destinationPath 'CodexQuotaMonitor.Native.json'
if (-not $Force -and [IO.File]::Exists($assemblyPath) -and [IO.File]::Exists($manifestPath)) {
    $previous = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($previous.SourceSha256 -ceq $sourceHash -and
        (Get-FileHash -LiteralPath $assemblyPath -Algorithm SHA256).Hash -ceq $previous.AssemblySha256) {
        return
    }
}

# Build against the Windows .NET Framework reference surface: these helpers
# use only APIs shared with .NET 8+, and can run in PowerShell 7.4 and later.
# No compiler or separate .NET installation is required on recipient PCs.
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw 'The Windows C# compiler was not found on the build computer.'
}
$buildDirectory = Join-Path $repoRoot ('outputs\native\' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $buildDirectory, $destinationPath -Force
$compiledPath = Join-Path $buildDirectory 'CodexQuotaMonitor.Native.dll'
$compilerArguments = @('/nologo', '/target:library', '/optimize+', '/platform:anycpu', "/out:$compiledPath", '/reference:System.dll', '/reference:System.Core.dll') + @($sourceFiles.FullName)
& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($compiledPath)) { throw 'The native helper build failed.' }
Copy-Item -LiteralPath $compiledPath -Destination $assemblyPath -Force
[IO.File]::WriteAllText($manifestPath, ([ordered]@{
    SchemaVersion = 1
    SourceSha256 = $sourceHash
    AssemblySha256 = (Get-FileHash -LiteralPath $assemblyPath -Algorithm SHA256).Hash
} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
