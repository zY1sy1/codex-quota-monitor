function Test-PackagedRelayHostIntegrity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RootPath)

    $fullRoot = [IO.Path]::GetFullPath($RootPath)
    $exe = Join-Path $fullRoot 'Bin\relay-quota-host.exe'
    $manifest = Join-Path $fullRoot 'Bin\relay-quota-host.sha256'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or
        -not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw [IO.InvalidDataException]::new('Packaged relay host integrity check failed.')
    }

    $manifestText = [IO.File]::ReadAllText($manifest)
    if ($manifestText -notmatch '^[0-9A-Fa-f]{64}\r?\n?$') {
        throw [IO.InvalidDataException]::new('Packaged relay host integrity check failed.')
    }
    $expectedHash = $manifestText.Trim()
    if ($expectedHash -cne $expectedHash.ToUpperInvariant()) {
        throw [IO.InvalidDataException]::new('Packaged relay host integrity check failed.')
    }
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToUpperInvariant()
    if ($actualHash -cne $expectedHash) {
        throw [IO.InvalidDataException]::new('Packaged relay host integrity check failed.')
    }

    return $true
}

function Assert-MonitorSourceLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    $fullSource = [IO.Path]::GetFullPath($SourcePath)
    if (-not (Test-Path -LiteralPath $fullSource -PathType Container)) {
        throw [ArgumentException]::new('The monitor source directory does not exist.', 'SourcePath')
    }

    foreach ($relativePath in @(
            'CodexQuotaMonitor.psd1'
            'CodexQuotaMonitor.psm1'
            'Start-CodexQuotaMonitor.ps1'
            'Start-CodexQuotaMonitor.vbs'
            'Private'
            'UI'
            'Bin\relay-quota-host.exe'
            'Bin\relay-quota-host.sha256'
            'Presets\relay-usage.json'
            'ThirdPartyNotices.txt'
        )) {
        if (-not (Test-Path -LiteralPath (Join-Path $fullSource $relativePath))) {
            throw [ArgumentException]::new('The monitor source directory is incomplete.', 'SourcePath')
        }
    }

    $stagePath = [IO.Path]::GetFullPath((Join-Path $TargetRoot 'app.new'))
    $sourcePrefix = $fullSource.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    if ($stagePath.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw [ArgumentException]::new(
            'The monitor source cannot contain its own installation staging directory.',
            'SourcePath'
        )
    }

    $null = Test-PackagedRelayHostIntegrity -RootPath $fullSource

    return $fullSource
}

function Test-MonitorInstalledLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Paths)

    return (
        (Test-Path -LiteralPath $Paths.App -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $Paths.App 'CodexQuotaMonitor.psd1') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Paths.App 'CodexQuotaMonitor.psm1') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Paths.App 'Start-CodexQuotaMonitor.ps1') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Paths.App 'Bin\relay-quota-host.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Paths.App 'Bin\relay-quota-host.sha256') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Paths.App 'Presets\relay-usage.json') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Paths.App 'ThirdPartyNotices.txt') -PathType Leaf)
    )
}

function Repair-MonitorInterruptedPublishState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Paths)

    $stagePath = Join-Path $Paths.ProgramRoot 'app.new'
    $backupPath = Join-Path $Paths.ProgramRoot 'app.old'
    $failedPath = Join-Path $Paths.ProgramRoot 'app.failed'
    if (Test-Path -LiteralPath $backupPath -PathType Container) {
        Restore-MonitorPublishedApplication `
            -Paths $Paths `
            -PublishState ([pscustomobject]@{
                Published = Test-Path -LiteralPath $Paths.App -PathType Container
                HadPrevious = $true
                StagePath = $stagePath
                BackupPath = $backupPath
            })
        return
    }
    if (-not (Test-Path -LiteralPath $Paths.App) -and
        (Test-Path -LiteralPath $failedPath -PathType Container)) {
        Move-Item -LiteralPath $failedPath -Destination $Paths.App -ErrorAction Stop
    }
    elseif (Test-Path -LiteralPath $failedPath) {
        Remove-MonitorManagedItem -Path $failedPath -Root $Paths.ProgramRoot
    }
    if (Test-Path -LiteralPath $stagePath) {
        Remove-MonitorManagedItem -Path $stagePath -Root $Paths.ProgramRoot
    }
}

function Publish-MonitorApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][object]$Paths
    )

    $stagePath = Join-Path $Paths.ProgramRoot 'app.new'
    $backupPath = Join-Path $Paths.ProgramRoot 'app.old'
    Repair-MonitorInterruptedPublishState -Paths $Paths
    [IO.Directory]::CreateDirectory($stagePath) | Out-Null
    try {
        foreach ($item in @(Get-ChildItem -LiteralPath $SourcePath -Force)) {
            Copy-Item `
                -LiteralPath $item.FullName `
                -Destination $stagePath `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }
        foreach ($required in @(
                'CodexQuotaMonitor.psd1'
                'CodexQuotaMonitor.psm1'
                'Start-CodexQuotaMonitor.ps1'
                'Start-CodexQuotaMonitor.vbs'
                'Private'
                'UI'
                'Bin\relay-quota-host.exe'
                'Bin\relay-quota-host.sha256'
                'Presets\relay-usage.json'
                'ThirdPartyNotices.txt'
            )) {
            if (-not (Test-Path -LiteralPath (Join-Path $stagePath $required))) {
                throw [IO.InvalidDataException]::new('The staged monitor application is incomplete.')
            }
        }
        $null = Test-PackagedRelayHostIntegrity -RootPath $stagePath

        $hadPrevious = Test-Path -LiteralPath $Paths.App -PathType Container
        if ($hadPrevious) {
            Move-Item -LiteralPath $Paths.App -Destination $backupPath -ErrorAction Stop
        }
        try {
            Move-Item -LiteralPath $stagePath -Destination $Paths.App -ErrorAction Stop
        }
        catch {
            if ($hadPrevious -and -not (Test-Path -LiteralPath $Paths.App) -and
                (Test-Path -LiteralPath $backupPath)) {
                Move-Item -LiteralPath $backupPath -Destination $Paths.App -ErrorAction Stop
            }
            throw
        }

        return [pscustomobject]@{
            Published = $true
            HadPrevious = [bool]$hadPrevious
            StagePath = $stagePath
            BackupPath = $backupPath
        }
    }
    catch {
        if (Test-Path -LiteralPath $stagePath) {
            try { Remove-MonitorManagedItem -Path $stagePath -Root $Paths.ProgramRoot } catch { }
        }
        throw
    }
}

function Restore-MonitorPublishedApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][object]$PublishState
    )

    $failedPath = Join-Path $Paths.ProgramRoot 'app.failed'
    if ($PublishState.HadPrevious -and
        -not (Test-Path -LiteralPath $PublishState.BackupPath -PathType Container)) {
        throw [InvalidOperationException]::new(
            'The previous monitor application backup is unavailable for rollback.'
        )
    }
    if (Test-Path -LiteralPath $failedPath) {
        Remove-MonitorManagedItem -Path $failedPath -Root $Paths.ProgramRoot
    }

    $currentMoved = $false
    try {
        if ($PublishState.Published -and (Test-Path -LiteralPath $Paths.App)) {
            Move-Item -LiteralPath $Paths.App -Destination $failedPath -ErrorAction Stop
            $currentMoved = $true
        }
        if ($PublishState.HadPrevious) {
            Move-Item `
                -LiteralPath $PublishState.BackupPath `
                -Destination $Paths.App `
                -ErrorAction Stop
        }
    }
    catch {
        if ($currentMoved -and -not (Test-Path -LiteralPath $Paths.App) -and
            (Test-Path -LiteralPath $failedPath -PathType Container)) {
            try {
                Move-Item -LiteralPath $failedPath -Destination $Paths.App -ErrorAction Stop
            }
            catch {
            }
        }
        throw
    }

    if (Test-Path -LiteralPath $failedPath) {
        Remove-MonitorManagedItem -Path $failedPath -Root $Paths.ProgramRoot
    }
    if (Test-Path -LiteralPath $PublishState.StagePath) {
        Remove-MonitorManagedItem -Path $PublishState.StagePath -Root $Paths.ProgramRoot
    }
}

function Complete-MonitorPublishedApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][object]$PublishState
    )

    if (Test-Path -LiteralPath $PublishState.BackupPath) {
        Remove-MonitorManagedItem -Path $PublishState.BackupPath -Root $Paths.ProgramRoot
    }
    if (Test-Path -LiteralPath $PublishState.StagePath) {
        Remove-MonitorManagedItem -Path $PublishState.StagePath -Root $Paths.ProgramRoot
    }
}
