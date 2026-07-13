[CmdletBinding()]
param(
    [ValidateSet('Unit', 'Integration', 'All')]
    [string]$Suite = 'All',

    [switch]$CI
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'Restore-TestDependencies.ps1')

$testPaths = switch ($Suite) {
    'Unit' { Join-Path $repoRoot 'tests\Unit' }
    'Integration' { Join-Path $repoRoot 'tests\Integration' }
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
if ($result.FailedCount -gt 0) {
    exit 1
}
