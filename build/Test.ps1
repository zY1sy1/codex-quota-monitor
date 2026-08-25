[CmdletBinding()]
param(
    [ValidateSet('Unit', 'Integration', 'EndToEnd', 'Installer', 'All')]
    [string]$Suite = 'All',

    [switch]$CI
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'Restore-TestDependencies.ps1')

$testPaths = switch ($Suite) {
    'Unit' { Join-Path $repoRoot 'tests\Unit' }
    'Integration' { Join-Path $repoRoot 'tests\Integration' }
    'EndToEnd' { Join-Path $repoRoot 'tests\Integration\RelayEndToEnd.Tests.ps1' }
    'Installer' {
        Join-Path $repoRoot 'tests\Unit\InstallerRuntime.Tests.ps1'
        Join-Path $repoRoot 'tests\Unit\InnoInstallerContract.Tests.ps1'
        Join-Path $repoRoot 'tests\Integration\InstallerSupportScripts.Tests.ps1'
        Join-Path $repoRoot 'tests\Integration\InstallerPayload.Tests.ps1'
        Join-Path $repoRoot 'tests\Integration\InstallerBuild.Tests.ps1'
    }
    'All' {
        Join-Path $repoRoot 'tests\Unit'
        Join-Path $repoRoot 'tests\Integration'
    }
}

$configuration = New-PesterConfiguration
$configuration.Run.Path = $testPaths
$configuration.Run.PassThru = $true
$configuration.Run.Exit = $false
$configuration.Output.Verbosity = if ($CI) { 'Detailed' } else { 'Normal' }

$resultDirectory = Join-Path $repoRoot 'outputs\test-results'
New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputFormat = 'JUnitXml'
$configuration.TestResult.OutputPath = Join-Path $resultDirectory "$Suite.xml"

$result = Invoke-Pester -Configuration $configuration
if ($result.Result -ne 'Passed') {
    exit 1
}

if ($Suite -eq 'Installer') {
    & (Join-Path $PSScriptRoot 'Test-WindowsInstaller.ps1')
    if ($LASTEXITCODE -ne 0) {
        exit 1
    }
}
