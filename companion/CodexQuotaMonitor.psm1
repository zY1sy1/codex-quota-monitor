$privateFiles = @(
    'ObjectAccess.ps1'
    'QuotaNormalization.ps1'
    'Presentation.ps1'
    'JsonRpc.ps1'
    'Settings.ps1'
    'WindowPlacement.ps1'
    'Logging.ps1'
    'AppServerProcess.ps1'
    'SessionController.ps1'
    'SingleInstance.ps1'
    'StartupShortcut.ps1'
    'WpfView.ps1'
    'TrayView.ps1'
    'InteractionController.ps1'
)

foreach ($privateFile in $privateFiles) {
    . (Join-Path $PSScriptRoot "Private\$privateFile")
}

$installationPath = Join-Path $PSScriptRoot 'Private\Installation.ps1'
if (Test-Path -LiteralPath $installationPath -PathType Leaf) {
    . $installationPath
}

function Write-MonitorRuntimeHealthFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [Collections.IDictionary]$Health
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = "$fullPath.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    $utf8WithoutBom = [Text.UTF8Encoding]::new($false)
    try {
        $json = ($Health | ConvertTo-Json -Depth 8) + [Environment]::NewLine
        [IO.File]::WriteAllText($temporaryPath, $json, $utf8WithoutBom)
        [IO.File]::Move($temporaryPath, $fullPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            [IO.File]::Delete($temporaryPath)
        }
    }
}

function Invoke-CodexQuotaMonitorRuntime {
    [CmdletBinding()]
    param(
        [switch]$Headless,

        [string]$AppServerExecutable,

        [AllowEmptyCollection()]
        [string[]]$AppServerArguments,

        [string]$LocalAppData = $env:LOCALAPPDATA,

        [string]$Startup = [Environment]::GetFolderPath('Startup'),

        [ValidateNotNullOrEmpty()]
        [string]$InstancePrefix = 'Local\CodexQuotaMonitor',

        [ValidateRange(0, 86400)]
        [int]$RunForSeconds = 0,

        [ValidateRange(25, 1000)]
        [int]$TickMilliseconds = 100,

        [ValidateRange(1, 300)]
        [int]$RequestTimeoutSeconds = 10,

        [switch]$PassThru
    )

    if (-not $IsWindows -or $PSVersionTable.PSVersion -lt [version]'7.4') {
        throw 'Codex quota monitor requires PowerShell 7.4 or later on Windows.'
    }
    if (-not $Headless -and
        [Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw 'Codex quota monitor requires an STA thread for desktop mode.'
    }

    $functions = [pscustomobject][ordered]@{
        GetPaths = ${function:Get-MonitorPaths}
        ReadSettings = ${function:Read-MonitorSettings}
        WriteSettings = ${function:Write-MonitorSettings}
        EnterInstance = ${function:Enter-MonitorInstance}
        CloseInstance = ${function:Close-MonitorInstance}
        FindCodex = ${function:Find-CodexExecutable}
        StartProcess = ${function:Start-AppServerProcess}
        StopProcess = ${function:Stop-AppServerProcess}
        Receive = ${function:Receive-AppServerRecord}
        Send = ${function:Send-AppServerMessage}
        NewSession = ${function:New-SessionState}
        Handshake = ${function:Start-SessionHandshake}
        UpdateMessage = ${function:Update-SessionFromMessage}
        UpdateNotification = ${function:Update-SessionFromNotification}
        RequestExpired = ${function:Test-RequestExpired}
        ReconnectDelay = ${function:Get-ReconnectDelaySeconds}
        PresentationRows = ${function:ConvertTo-QuotaPresentationRow}
        Severity = ${function:Get-QuotaSeverity}
        Tooltip = ${function:Get-TrayTooltip}
        NewWindow = ${function:New-QuotaWindowView}
        NewTray = ${function:New-TrayView}
        NewInteraction = ${function:New-MonitorInteractionController}
        WriteHealth = ${function:Write-MonitorRuntimeHealthFile}
        SetStartupPreference = if ($null -ne (Get-Command Set-MonitorStartupPreference -ErrorAction SilentlyContinue)) {
            ${function:Set-MonitorStartupPreference}
        }
        else {
            $null
        }
    }

    $pathsFunction = $functions.GetPaths
    $paths = & $pathsFunction -LocalAppData $LocalAppData -Startup $Startup
    [IO.Directory]::CreateDirectory($paths.Data) | Out-Null
    [IO.Directory]::CreateDirectory($paths.Logs) | Out-Null

    $enterInstanceFunction = $functions.EnterInstance
    $instance = & $enterInstanceFunction -Prefix $InstancePrefix -Signal Activate
    if (-not $instance.IsPrimary) {
        if ($PassThru) {
            return [pscustomobject][ordered]@{
                Status = 'AlreadyRunning'
                PlanType = $null
                QuotaWindows = @()
                LastSuccessAt = $null
                HealthPath = $paths.Health
            }
        }
        return
    }

    $runtime = [pscustomobject][ordered]@{
        Functions = $functions
        Paths = $paths
        Settings = $null
        Instance = $instance
        Transport = $null
        Session = & $functions.NewSession
        WindowView = $null
        TrayView = $null
        Interaction = $null
        RefreshEvent = [Threading.AutoResetEvent]::new($false)
        ResumeEvent = [Threading.AutoResetEvent]::new($false)
        PowerHandler = $null
        DispatcherTimer = $null
        DispatcherTickHandler = $null
        StopRequested = $false
        FatalError = $null
        ErrorCategory = $null
        ReconnectAttempt = 0
        NextReconnectAt = [DateTimeOffset]::MinValue
        NextDefensiveRefreshAt = [DateTimeOffset]::UtcNow.AddSeconds(60)
        LastResetRefreshKey = $null
        LastQuotaWindows = @()
        LastPlanType = $null
        LastSuccessAt = $null
        LastHealthSignature = $null
        NextUiRefreshAt = [DateTimeOffset]::MinValue
        StartedAt = [DateTimeOffset]::UtcNow
        Deadline = if ($RunForSeconds -gt 0) {
            [DateTimeOffset]::UtcNow.AddSeconds($RunForSeconds)
        }
        else {
            [DateTimeOffset]::MaxValue
        }
    }

    $sendActions = {
        param([AllowEmptyCollection()][object[]]$Actions)

        $sendFunction = $runtime.Functions.Send
        foreach ($action in @($Actions | Where-Object { $null -ne $_ })) {
            & $sendFunction -Transport $runtime.Transport -Message $action
        }
    }.GetNewClosure()

    $publishHealth = {
        param([switch]$Force)

        $session = $runtime.Session
        $displayWindows = if ($session.Status -eq 'Live') {
            @($session.QuotaWindows)
        }
        else {
            @($runtime.LastQuotaWindows)
        }
        $planType = if (-not [string]::IsNullOrWhiteSpace([string]$session.PlanType)) {
            [string]$session.PlanType
        }
        else {
            $runtime.LastPlanType
        }
        $lastSuccess = if ($null -ne $session.LastSuccessAt) {
            [DateTimeOffset]$session.LastSuccessAt
        }
        else {
            $runtime.LastSuccessAt
        }
        $errorMessage = if ([string]::IsNullOrWhiteSpace([string]$session.LastError)) {
            $null
        }
        else {
            [string]$session.LastError
        }
        $signature = @(
            [string]$session.Status,
            [string]$planType,
            [string]$displayWindows.Count,
            [string]$lastSuccess,
            [string]$runtime.ErrorCategory,
            [string]$errorMessage
        ) -join '|'
        if (-not $Force -and $signature -ceq $runtime.LastHealthSignature) {
            return
        }

        $health = [ordered]@{
            SchemaVersion = 1
            Status = [string]$session.Status
            PlanType = $planType
            QuotaWindowCount = [int]$displayWindows.Count
            LastSuccessAt = if ($null -eq $lastSuccess) { $null } else { $lastSuccess.ToUniversalTime().ToString('o') }
            LastErrorCategory = $runtime.ErrorCategory
            LastErrorMessage = $errorMessage
            ProcessId = [int]$PID
            UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $writeHealthFunction = $runtime.Functions.WriteHealth
        & $writeHealthFunction -Path $runtime.Paths.Health -Health $health
        $runtime.LastHealthSignature = $signature
    }.GetNewClosure()

    $stopTransport = {
        if ($null -ne $runtime.Transport) {
            $stopFunction = $runtime.Functions.StopProcess
            try { & $stopFunction -Transport $runtime.Transport -TimeoutMilliseconds 2000 } catch { }
            $runtime.Transport = $null
        }
    }.GetNewClosure()

    $failTransport = {
        param(
            [Parameter(Mandatory)][string]$Category,
            [Parameter(Mandatory)][string]$Message,
            [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
        )

        & $stopTransport
        $delayFunction = $runtime.Functions.ReconnectDelay
        $delay = & $delayFunction -Attempt $runtime.ReconnectAttempt
        $runtime.ReconnectAttempt = [int]($runtime.ReconnectAttempt + 1)
        $runtime.NextReconnectAt = $Now.AddSeconds($delay)
        $newSessionFunction = $runtime.Functions.NewSession
        $runtime.Session = & $newSessionFunction
        $runtime.Session.Status = 'Reconnecting'
        $runtime.Session.LastError = $Message
        $runtime.ErrorCategory = $Category
    }.GetNewClosure()

    $startTransport = {
        param([DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)

        if ([string]::IsNullOrWhiteSpace($AppServerExecutable)) {
            $findFunction = $runtime.Functions.FindCodex
            $discovery = & $findFunction
            if (-not $discovery.Found) {
                throw [InvalidOperationException]::new('The Codex App Server executable was not found.')
            }
            $resolvedExecutable = [string]$discovery.ExecutablePath
            $resolvedArguments = @('app-server')
        }
        else {
            $resolvedExecutable = $AppServerExecutable
            $resolvedArguments = @($AppServerArguments)
        }

        $startFunction = $runtime.Functions.StartProcess
        $runtime.Transport = & $startFunction `
            -ExecutablePath $resolvedExecutable `
            -ArgumentList $resolvedArguments `
            -WorkingDirectory $PSScriptRoot
        $newSessionFunction = $runtime.Functions.NewSession
        $runtime.Session = & $newSessionFunction
        $runtime.ErrorCategory = $null
        $handshakeFunction = $runtime.Functions.Handshake
        $actions = @(& $handshakeFunction -State $runtime.Session -Now $Now)
        & $sendActions $actions
    }.GetNewClosure()

    $requestQuotaRefresh = {
        param([DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)

        if ($null -eq $runtime.Transport -or -not $runtime.Session.Initialized) {
            return
        }
        $notificationFunction = $runtime.Functions.UpdateNotification
        $actions = @(& $notificationFunction `
            -State $runtime.Session `
            -Method 'account/rateLimits/updated' `
            -Now $Now)
        & $sendActions $actions
    }.GetNewClosure()

    $refreshUi = {
        param([DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)

        if ($Headless -or $null -eq $runtime.WindowView -or $null -eq $runtime.TrayView) {
            return
        }

        $session = $runtime.Session
        $displayWindows = if ($session.Status -eq 'Live') {
            @($session.QuotaWindows)
        }
        else {
            @($runtime.LastQuotaWindows)
        }
        $presentationFunction = $runtime.Functions.PresentationRows
        $rows = @(& $presentationFunction -QuotaWindows $displayWindows -Now $Now)
        & $runtime.WindowView.Render $rows

        $remaining = @(
            $displayWindows |
                ForEach-Object { $_.RemainingPercent } |
                Where-Object { $null -ne $_ }
        )
        $minimum = if ($remaining.Count -eq 0) { $null } else { ($remaining | Measure-Object -Minimum).Minimum }
        $severityFunction = $runtime.Functions.Severity
        $severity = & $severityFunction -MinimumRemaining $minimum -Offline:($session.Status -ne 'Live')
        & $runtime.TrayView.SetSeverity $severity

        $tooltipFunction = $runtime.Functions.Tooltip
        $tooltip = & $tooltipFunction -QuotaWindows $displayWindows
        & $runtime.TrayView.SetTooltip ([string]$tooltip)

        if ($session.Status -eq 'Live') {
            & $runtime.WindowView.SetFreshness $true ''
        }
        else {
            $freshness = if ($null -ne $runtime.LastSuccessAt) {
                '最后同步：' + $runtime.LastSuccessAt.ToLocalTime().ToString('HH:mm') + '，正在重连'
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$session.LastError)) {
                [string]$session.LastError
            }
            else {
                '正在连接 Codex'
            }
            & $runtime.WindowView.SetFreshness $false $freshness
        }
    }.GetNewClosure()

    $tick = {
        $now = [DateTimeOffset]::UtcNow
        if ($runtime.Instance.ExitEvent.WaitOne(0) -or $now -ge $runtime.Deadline) {
            $runtime.StopRequested = $true
            return
        }
        if ($runtime.Instance.ActivateEvent.WaitOne(0) -and $null -ne $runtime.Interaction) {
            & $runtime.Interaction.ShowAndActivate
        }

        if ($null -eq $runtime.Transport) {
            if ($now -ge $runtime.NextReconnectAt) {
                try {
                    & $startTransport $now
                }
                catch {
                    & $failTransport 'AppServerStart' 'Unable to start the Codex App Server.' $now
                }
            }
        }
        else {
            $hasExited = $true
            try { $hasExited = $runtime.Transport.Process.HasExited } catch { $hasExited = $true }
            if ($hasExited) {
                & $failTransport 'TransportClosed' 'The Codex App Server connection closed; reconnecting.' $now
            }
            else {
                $receiveFunction = $runtime.Functions.Receive
                $records = @(& $receiveFunction -Transport $runtime.Transport -Maximum 200)
                foreach ($record in $records) {
                    if ($record.Stream -ne 'stdout') {
                        continue
                    }

                    try {
                        $message = $record.Line | ConvertFrom-Json -Depth 100 -ErrorAction Stop
                    }
                    catch {
                        & $failTransport 'MalformedResponse' 'Codex App Server returned an invalid response; reconnecting.' $now
                        break
                    }

                    try {
                        $updateFunction = $runtime.Functions.UpdateMessage
                        $actions = @(& $updateFunction -State $runtime.Session -Message $message -Now $now)
                        & $sendActions $actions
                        if ($runtime.Session.Status -eq 'Error') {
                            $requestError = if ([string]::IsNullOrWhiteSpace([string]$runtime.Session.LastError)) {
                                'A Codex App Server request failed; reconnecting.'
                            }
                            else {
                                [string]$runtime.Session.LastError
                            }
                            & $failTransport 'RequestFailed' $requestError $now
                            break
                        }
                    }
                    catch {
                        & $failTransport 'TransportClosed' 'The Codex App Server connection closed; reconnecting.' $now
                        break
                    }
                }

                if ($null -ne $runtime.Transport) {
                    $expiredFunction = $runtime.Functions.RequestExpired
                    $expired = $false
                    foreach ($pending in @($runtime.Session.Pending.Values)) {
                        if (& $expiredFunction `
                            -SentAt $pending.SentAt `
                            -Now $now `
                            -TimeoutSeconds $RequestTimeoutSeconds) {
                            $expired = $true
                            break
                        }
                    }
                    if ($expired) {
                        & $failTransport 'RequestTimeout' 'Codex App Server did not respond in time; reconnecting.' $now
                    }
                }
            }
        }

        if ($runtime.Session.Status -eq 'Live') {
            $runtime.LastQuotaWindows = @($runtime.Session.QuotaWindows)
            $runtime.LastPlanType = $runtime.Session.PlanType
            $runtime.LastSuccessAt = $runtime.Session.LastSuccessAt
            $runtime.ReconnectAttempt = 0
            $runtime.ErrorCategory = $null
        }
        elseif ($runtime.Session.Status -in @('AuthRequired', 'Unavailable')) {
            $runtime.LastQuotaWindows = @()
            $runtime.LastPlanType = $null
            $runtime.LastSuccessAt = $null
            $runtime.LastResetRefreshKey = $null
        }

        $manualRefresh = $runtime.RefreshEvent.WaitOne(0)
        $resumeRefresh = $runtime.ResumeEvent.WaitOne(0)
        $defensiveRefresh = $now -ge $runtime.NextDefensiveRefreshAt
        if ($defensiveRefresh) {
            $runtime.NextDefensiveRefreshAt = $now.AddSeconds(60)
        }
        if ($manualRefresh -or $resumeRefresh -or $defensiveRefresh) {
            try { & $requestQuotaRefresh $now } catch {
                & $failTransport 'TransportClosed' 'The Codex App Server connection closed; reconnecting.' $now
            }
        }

        if ($runtime.Session.Status -eq 'Live') {
            $expiredResetKeys = @(
                foreach ($window in @($runtime.Session.QuotaWindows)) {
                    if ([long]$window.ResetsAt -gt 0 -and [long]$window.ResetsAt -le $now.ToUnixTimeSeconds()) {
                        [string]$window.Key
                    }
                }
            )
            if ($expiredResetKeys.Count -gt 0) {
                $resetKey = ($expiredResetKeys | Sort-Object) -join '|'
                if ($resetKey -cne $runtime.LastResetRefreshKey) {
                    $runtime.LastResetRefreshKey = $resetKey
                    try { & $requestQuotaRefresh $now } catch {
                        & $failTransport 'TransportClosed' 'The Codex App Server connection closed; reconnecting.' $now
                    }
                }
            }
        }

        if ($now -ge $runtime.NextUiRefreshAt) {
            $runtime.NextUiRefreshAt = $now.AddSeconds(1)
            & $refreshUi $now
        }
        & $publishHealth
    }.GetNewClosure()
    $runtime | Add-Member -NotePropertyName Tick -NotePropertyValue $tick

    $primaryError = $null
    try {
        $readSettingsFunction = $functions.ReadSettings
        $runtime.Settings = & $readSettingsFunction -Path $paths.Settings
        if (-not (Test-Path -LiteralPath $paths.Settings -PathType Leaf)) {
            $writeSettingsFunction = $functions.WriteSettings
            & $writeSettingsFunction -Path $paths.Settings -Settings $runtime.Settings
        }

        if (-not $Headless) {
            $newWindowFunction = $functions.NewWindow
            $runtime.WindowView = & $newWindowFunction
            $newTrayFunction = $functions.NewTray
            $runtime.TrayView = & $newTrayFunction -Visible:$false

            & $runtime.WindowView.SetTopmost ([bool]$runtime.Settings.Window.Topmost)
            if ($null -ne $runtime.Settings.Window.Left) {
                $runtime.WindowView.Window.Left = [double]$runtime.Settings.Window.Left
            }
            if ($null -ne $runtime.Settings.Window.Top) {
                $runtime.WindowView.Window.Top = [double]$runtime.Settings.Window.Top
            }

            $saveSettingsFunction = $functions.WriteSettings
            $saveSettingsAction = {
                param($Settings)
                & $saveSettingsFunction -Path $paths.Settings -Settings $Settings
            }.GetNewClosure()
            $startupPreferenceFunction = $functions.SetStartupPreference
            $startupAction = {
                param([bool]$Enabled)
                if ($null -eq $startupPreferenceFunction) {
                    throw 'Startup preference management is unavailable until the monitor is installed.'
                }
                & $startupPreferenceFunction `
                    -Enabled $Enabled `
                    -Paths $paths `
                    -RuntimeScriptPath (Join-Path $PSScriptRoot 'Start-CodexQuotaMonitor.ps1')
            }.GetNewClosure()
            $requestRefreshAction = {
                $runtime.RefreshEvent.Set() | Out-Null
            }.GetNewClosure()
            $openTargetAction = {
                param([string]$Target)
                Start-Process -FilePath $Target | Out-Null
            }

            $newInteractionFunction = $functions.NewInteraction
            $runtime.Interaction = & $newInteractionFunction `
                -Settings $runtime.Settings `
                -WindowView $runtime.WindowView `
                -TrayView $runtime.TrayView `
                -SaveSettings $saveSettingsAction `
                -ApplyStartupPreference $startupAction `
                -RequestRefresh $requestRefreshAction `
                -ExitEvent $runtime.Instance.ExitEvent `
                -OpenTarget $openTargetAction `
                -LogDirectory $paths.Logs

            & $runtime.TrayView.SetVisible $true
            if ([bool]$runtime.Settings.Window.Visible) {
                & $runtime.WindowView.Show
            }
            else {
                & $runtime.WindowView.Hide
            }

            try {
                $powerHandlerScript = {
                    param($Sender, $EventArgs)
                    if ($EventArgs.Mode -eq [Microsoft.Win32.PowerModes]::Resume) {
                        $runtime.ResumeEvent.Set() | Out-Null
                    }
                }.GetNewClosure()
                $runtime.PowerHandler = [Microsoft.Win32.PowerModeChangedEventHandler]$powerHandlerScript
                [Microsoft.Win32.SystemEvents]::add_PowerModeChanged($runtime.PowerHandler)
            }
            catch {
                $runtime.PowerHandler = $null
            }
        }

        & $publishHealth -Force
        try {
            & $startTransport ([DateTimeOffset]::UtcNow)
        }
        catch {
            & $failTransport 'AppServerStart' 'Unable to start the Codex App Server.' ([DateTimeOffset]::UtcNow)
        }

        if ($Headless) {
            while (-not $runtime.StopRequested) {
                & $runtime.Tick
                if (-not $runtime.StopRequested) {
                    [Threading.Thread]::Sleep($TickMilliseconds)
                }
            }
        }
        else {
            $runtime.DispatcherTimer = [Windows.Threading.DispatcherTimer]::new()
            $runtime.DispatcherTimer.Interval = [TimeSpan]::FromMilliseconds($TickMilliseconds)
            $dispatcherHandlerScript = {
                param($Sender, $EventArgs)
                try {
                    & $runtime.Tick
                }
                catch {
                    $runtime.FatalError = $_
                    $runtime.StopRequested = $true
                }
                if ($runtime.StopRequested) {
                    $runtime.DispatcherTimer.Stop()
                    [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvokeShutdown(
                        [Windows.Threading.DispatcherPriority]::Normal
                    )
                }
            }.GetNewClosure()
            $runtime.DispatcherTickHandler = [EventHandler]$dispatcherHandlerScript
            $runtime.DispatcherTimer.add_Tick($runtime.DispatcherTickHandler)
            $runtime.DispatcherTimer.Start()
            [Windows.Threading.Dispatcher]::Run()
            if ($null -ne $runtime.FatalError) {
                throw $runtime.FatalError
            }
        }
    }
    catch {
        $primaryError = $_
        $runtime.ErrorCategory = 'RuntimeError'
        $runtime.Session.Status = 'Error'
        $runtime.Session.LastError = 'The Codex quota monitor encountered an internal error.'
        try { & $publishHealth -Force } catch { }
    }
    finally {
        if ($null -ne $runtime.PowerHandler) {
            try { [Microsoft.Win32.SystemEvents]::remove_PowerModeChanged($runtime.PowerHandler) } catch { }
        }
        if ($null -ne $runtime.DispatcherTimer) {
            try { $runtime.DispatcherTimer.Stop() } catch { }
            if ($null -ne $runtime.DispatcherTickHandler) {
                try { $runtime.DispatcherTimer.remove_Tick($runtime.DispatcherTickHandler) } catch { }
            }
        }
        if ($null -ne $runtime.Interaction) {
            try { & $runtime.Interaction.Dispose } catch { }
        }
        if ($null -ne $runtime.WindowView) {
            try { & $runtime.WindowView.Dispose } catch { }
        }
        if ($null -ne $runtime.TrayView) {
            try { & $runtime.TrayView.Dispose } catch {
                try { & $runtime.TrayView.Dispose } catch { }
            }
        }
        & $stopTransport
        $runtime.RefreshEvent.Dispose()
        $runtime.ResumeEvent.Dispose()
        $closeInstanceFunction = $functions.CloseInstance
        try { & $closeInstanceFunction -Instance $runtime.Instance } catch {
            if ($null -eq $primaryError) { $primaryError = $_ }
        }
    }

    if ($null -ne $primaryError) {
        throw $primaryError
    }
    if ($PassThru) {
        return [pscustomobject][ordered]@{
            Status = [string]$runtime.Session.Status
            PlanType = if ($null -ne $runtime.Session.PlanType) { $runtime.Session.PlanType } else { $runtime.LastPlanType }
            QuotaWindows = if ($runtime.Session.Status -eq 'Live') { @($runtime.Session.QuotaWindows) } else { @($runtime.LastQuotaWindows) }
            LastSuccessAt = if ($null -ne $runtime.Session.LastSuccessAt) { $runtime.Session.LastSuccessAt } else { $runtime.LastSuccessAt }
            HealthPath = $runtime.Paths.Health
        }
    }
}

$publicFunctions = @(
    'Install-CodexQuotaMonitor'
    'Repair-CodexQuotaMonitor'
    'Uninstall-CodexQuotaMonitor'
    'Start-CodexQuotaMonitor'
    'Stop-CodexQuotaMonitor'
    'Get-CodexQuotaMonitorStatus'
    'Test-CodexQuotaMonitorHealth'
)
$availablePublicFunctions = @(
    foreach ($name in $publicFunctions) {
        if ($null -ne (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) {
            $name
        }
    }
)
Export-ModuleMember -Function $availablePublicFunctions
