#requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Development', 'Release')][string]$Configuration = 'Development',
    [AllowNull()][string]$IsccPath,
    [switch]$SkipApplicationTests,
    [switch]$SkipRustTests
)

$ErrorActionPreference = 'Stop'

function ConvertTo-InstallerVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Version)

    if ($Version -notmatch '^(?<Core>\d+\.\d+\.\d+)(?:\+(?<Metadata>[0-9A-Za-z.-]+))?$') {
        throw [FormatException]::new('The plugin version is not supported by the Windows installer.')
    }
    $coreParts = @($Matches.Core.Split('.') | ForEach-Object { [int]$_ })
    if ($coreParts.Count -ne 3 -or @($coreParts | Where-Object { $_ -gt 65535 }).Count -gt 0) {
        throw [FormatException]::new('The plugin version exceeds Windows version limits.')
    }

    $build = 0
    if (-not [string]::IsNullOrWhiteSpace($Matches.Metadata)) {
        $digits = $Matches.Metadata -replace '\D', ''
        if (-not [string]::IsNullOrWhiteSpace($digits)) {
            $tail = $digits.Substring([Math]::Max(0, $digits.Length - 5))
            $build = [int64]$tail % 65536
        }
    }

    [pscustomobject][ordered]@{
        DisplayVersion = $Version
        NumericVersion = '{0}.{1}.{2}.{3}' -f $coreParts[0], $coreParts[1], $coreParts[2], $build
        OutputBaseName = "CodexQuotaMonitor-Setup-$Version-x64"
    }
}

function Get-InstallerGitState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $commit = (& git -C $RepoRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw [InvalidOperationException]::new('The installer build requires a Git worktree.')
    }
    $status = @(& git -C $RepoRoot status --porcelain --untracked-files=all 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw [InvalidOperationException]::new('The Git worktree state could not be read.')
    }

    [pscustomobject][ordered]@{
        Commit = ([string]$commit).Trim()
        Dirty = $status.Count -gt 0
    }
}

function Assert-InstallerBuildConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Development', 'Release')][string]$Configuration,
        [switch]$Dirty
    )

    if ($Configuration -eq 'Release' -and $Dirty) {
        throw [InvalidOperationException]::new(
            'Release installer builds require a clean Git worktree.'
        )
    }
}

function Resolve-InnoCompiler {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ExplicitPath,
        [AllowNull()][string]$PathValue = $env:PATH,
        [AllowNull()][string[]]$StandardPaths
    )

    $candidates = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $candidates.Add([IO.Path]::GetFullPath($ExplicitPath))
    }
    if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
        foreach ($directory in $PathValue.Split([IO.Path]::PathSeparator)) {
            if (-not [string]::IsNullOrWhiteSpace($directory)) {
                $candidates.Add((Join-Path $directory.Trim('"') 'ISCC.exe'))
            }
        }
    }
    if ($null -eq $StandardPaths) {
        $StandardPaths = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
            (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
        )
    }
    foreach ($candidate in $StandardPaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $candidates.Add([IO.Path]::GetFullPath($candidate))
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw [IO.FileNotFoundException]::new(
        'The Inno Setup 6 compiler (ISCC.exe) was not found. Install Inno Setup 6 or pass -IsccPath.'
    )
}

function Select-BuildCommandPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyCollection()][object[]]$Commands
    )

    $paths = @($Commands | ForEach-Object {
            if ($null -ne $_ -and
                $null -ne $_.PSObject.Properties['Source'] -and
                -not [string]::IsNullOrWhiteSpace([string]$_.Source) -and
                (Test-Path -LiteralPath ([string]$_.Source) -PathType Leaf)) {
                [IO.Path]::GetFullPath([string]$_.Source)
            }
        })
    $selected = $paths |
        Sort-Object @{ Expression = { if ([IO.Path]::GetExtension($_) -ieq '.exe') { 0 } else { 1 } } },
            @{ Expression = { $_ } } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace([string]$selected)) {
        throw [PlatformNotSupportedException]::new("$Name is required for this build.")
    }
    return [string]$selected
}

function Write-InstallerHashFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SetupPath)

    $setupFullPath = [IO.Path]::GetFullPath($SetupPath)
    if (-not (Test-Path -LiteralPath $setupFullPath -PathType Leaf)) {
        throw [IO.FileNotFoundException]::new('The compiled setup executable is missing.')
    }
    $sha256 = (Get-FileHash -LiteralPath $setupFullPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $hashPath = $setupFullPath + '.sha256'
    [IO.File]::WriteAllText(
        $hashPath,
        "$sha256  $([IO.Path]::GetFileName($setupFullPath))`n",
        [Text.UTF8Encoding]::new($false)
    )

    [pscustomobject][ordered]@{
        SetupPath = $setupFullPath
        HashPath = $hashPath
        Sha256 = $sha256
    }
}

function New-InstallerBuildManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$NumericVersion,
        [AllowNull()][string]$GitCommit,
        [switch]$Dirty,
        [Parameter(Mandatory)][string]$PowerShellVersion,
        [Parameter(Mandatory)][string]$RelayHostSha256,
        [Parameter(Mandatory)][string]$SetupSha256,
        [Parameter(Mandatory)][string]$SetupFileName
    )

    [pscustomobject][ordered]@{
        SchemaVersion = 1
        Version = $Version
        NumericVersion = $NumericVersion
        GitCommit = $GitCommit
        Dirty = [bool]$Dirty
        BuiltAt = [DateTimeOffset]::UtcNow.ToString('o')
        Architecture = 'x64'
        PowerShellVersion = $PowerShellVersion
        RelayHostSha256 = $RelayHostSha256
        SetupFileName = $SetupFileName
        SetupSha256 = $SetupSha256
        SigningStatus = 'Unsigned'
    }
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$pluginManifestPath = Join-Path $repoRoot '.codex-plugin\plugin.json'
$pluginManifest = Get-Content -LiteralPath $pluginManifestPath -Raw | ConvertFrom-Json
$version = ConvertTo-InstallerVersion -Version ([string]$pluginManifest.version)
$gitState = Get-InstallerGitState -RepoRoot $repoRoot
Assert-InstallerBuildConfiguration -Configuration $Configuration -Dirty:$gitState.Dirty

$outputsRoot = Join-Path $repoRoot 'outputs'
$runtimeDestination = Join-Path $outputsRoot 'staging\runtime\pwsh'
$stagingRoot = Join-Path $outputsRoot 'staging\installer'
$installerOutput = Join-Path $outputsRoot 'installer'
$runtime = & (Join-Path $PSScriptRoot 'Acquire-PowerShellRuntime.ps1') `
    -CacheRoot (Join-Path $outputsRoot 'cache\powershell') `
    -Destination $runtimeDestination

if (-not $SkipApplicationTests) {
    & $runtime.PwshPath -NoLogo -NoProfile -NonInteractive `
        -File (Join-Path $PSScriptRoot 'Test.ps1') -Suite All -CI
    if ($LASTEXITCODE -ne 0) {
        throw [InvalidOperationException]::new('PowerShell application tests failed under the bundled runtime.')
    }
}

if (-not $SkipRustTests) {
    & $runtime.PwshPath -NoLogo -NoProfile -NonInteractive `
        -File (Join-Path $PSScriptRoot 'Verify-PackagedRelayHost.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw [InvalidOperationException]::new('The packaged relay host verification failed.')
    }
    $cargoPath = Select-BuildCommandPath `
        -Name 'Cargo' `
        -Commands @(Get-Command cargo -CommandType Application -ErrorAction SilentlyContinue)
    $cargoManifest = Join-Path $repoRoot 'sidecar\relay-quota-host\Cargo.toml'
    & $cargoPath fmt --manifest-path $cargoManifest -- --check
    if ($LASTEXITCODE -ne 0) { throw 'cargo fmt failed.' }
    & $cargoPath clippy --manifest-path $cargoManifest --all-targets --locked -- -D warnings
    if ($LASTEXITCODE -ne 0) { throw 'cargo clippy failed.' }
    & $cargoPath test --manifest-path $cargoManifest --locked
    if ($LASTEXITCODE -ne 0) { throw 'cargo test failed.' }
}

$staging = & (Join-Path $PSScriptRoot 'New-InstallerPayload.ps1') `
    -RepoRoot $repoRoot `
    -RuntimeRoot $runtime.RuntimeRoot `
    -Destination $stagingRoot `
    -Version $version.DisplayVersion `
    -GitCommit $gitState.Commit `
    -Dirty:$gitState.Dirty
$compiler = Resolve-InnoCompiler -ExplicitPath $IsccPath
$null = New-Item -ItemType Directory -Path $installerOutput -Force
$setupPath = Join-Path $installerOutput ($version.OutputBaseName + '.exe')
foreach ($oldPath in @($setupPath, $setupPath + '.sha256', (Join-Path $installerOutput 'manifest.json'))) {
    if (Test-Path -LiteralPath $oldPath -PathType Leaf) {
        Remove-Item -LiteralPath $oldPath -Force
    }
}

$issPath = Join-Path $repoRoot 'installer\CodexQuotaMonitor.iss'
$compilerArguments = @(
    "/DSourceRoot=$($staging.StagingRoot)"
    "/DOutputDir=$installerOutput"
    "/DAppVersion=$($version.DisplayVersion)"
    "/DNumericVersion=$($version.NumericVersion)"
    "/DOutputBaseName=$($version.OutputBaseName)"
    $issPath
)
& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
    throw [InvalidOperationException]::new('Inno Setup did not produce the expected setup executable.')
}

$hash = Write-InstallerHashFile -SetupPath $setupPath
$manifest = New-InstallerBuildManifest `
    -Version $version.DisplayVersion `
    -NumericVersion $version.NumericVersion `
    -GitCommit $gitState.Commit `
    -Dirty:$gitState.Dirty `
    -PowerShellVersion $runtime.Version `
    -RelayHostSha256 $staging.RelayHostSha256 `
    -SetupSha256 $hash.Sha256 `
    -SetupFileName ([IO.Path]::GetFileName($setupPath))
$manifestPath = Join-Path $installerOutput 'manifest.json'
[IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json -Depth 5),
    [Text.UTF8Encoding]::new($false)
)

& $runtime.PwshPath -NoLogo -NoProfile -NonInteractive `
    -File (Join-Path $PSScriptRoot 'Test-WindowsInstaller.ps1') `
    -SetupPath $setupPath
if ($LASTEXITCODE -ne 0) {
    throw [InvalidOperationException]::new('The compiled Windows installer failed validation.')
}

[pscustomobject][ordered]@{
    Configuration = $Configuration
    SetupPath = $setupPath
    HashPath = $hash.HashPath
    ManifestPath = $manifestPath
    Version = $version.DisplayVersion
    NumericVersion = $version.NumericVersion
    Dirty = [bool]$gitState.Dirty
    Sha256 = $hash.Sha256
    SigningStatus = 'Unsigned'
}
