[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-PackagedRelayHost {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Get-PeMachine {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        Assert-PackagedRelayHost ($reader.ReadUInt32() -eq 0x00004550) 'Packaged relay host is not a PE image.'
        return $reader.ReadUInt16()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$companionRoot = Join-Path $repoRoot 'companion'
$binRoot = Join-Path $companionRoot 'Bin'
$exe = Join-Path $binRoot 'relay-quota-host.exe'
$manifest = Join-Path $binRoot 'relay-quota-host.sha256'
$notices = Join-Path $companionRoot 'ThirdPartyNotices.txt'

Assert-PackagedRelayHost (Test-Path -LiteralPath $exe -PathType Leaf) 'Packaged relay host executable is missing.'
Assert-PackagedRelayHost (Test-Path -LiteralPath $manifest -PathType Leaf) 'Packaged relay host hash manifest is missing.'
Assert-PackagedRelayHost (Test-Path -LiteralPath $notices -PathType Leaf) 'Third-party notices are missing.'

$manifestText = [IO.File]::ReadAllText($manifest)
Assert-PackagedRelayHost ($manifestText -match '^[0-9A-Fa-f]{64}\r?\n?$') 'Packaged relay host hash manifest is invalid.'
$expectedHash = $manifestText.Trim()
Assert-PackagedRelayHost ($expectedHash -ceq $expectedHash.ToUpperInvariant()) 'Packaged relay host hash is not uppercase.'
$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToUpperInvariant()
Assert-PackagedRelayHost ($actualHash -ceq $expectedHash) 'Packaged relay host hash does not match.'
Assert-PackagedRelayHost ((Get-PeMachine -Path $exe) -eq 0x8664) 'Packaged relay host is not Windows x64.'

$expectedFiles = @('relay-quota-host.exe', 'relay-quota-host.sha256')
$actualFiles = @(Get-ChildItem -LiteralPath $binRoot -Force | ForEach-Object Name | Sort-Object)
Assert-PackagedRelayHost (($actualFiles -join "`n") -ceq (($expectedFiles | Sort-Object) -join "`n")) 'Packaged relay host directory contains unexpected files.'

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $exe
$startInfo.ArgumentList.Add('--self-test')
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$process = [Diagnostics.Process]::Start($startInfo)
try {
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    Assert-PackagedRelayHost ($process.WaitForExit(5000)) 'Packaged relay host self-test timed out.'
    Assert-PackagedRelayHost ($process.ExitCode -eq 0) 'Packaged relay host self-test failed.'
    Assert-PackagedRelayHost ($stdout -ceq "relay-quota-host: ok`n") 'Packaged relay host self-test output is invalid.'
    Assert-PackagedRelayHost ($stderr -ceq '') 'Packaged relay host self-test wrote unexpected diagnostics.'
}
finally {
    if (-not $process.HasExited) {
        try { $process.Kill($true) } catch { }
    }
    $process.Dispose()
}

Write-Output 'Packaged relay host: verified.'
