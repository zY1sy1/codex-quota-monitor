$privateFiles = @(
    'ObjectAccess.ps1'
    'QuotaNormalization.ps1'
    'Presentation.ps1'
    'JsonRpc.ps1'
    'Settings.ps1'
    'RelayCredentials.ps1'
    'RelayProviderStore.ps1'
    'RelayCache.ps1'
    'RelayState.ps1'
    'RelayScriptClient.ps1'
    'RelayScheduler.ps1'
    'RelayPresentation.ps1'
    'WindowPlacement.ps1'
    'Logging.ps1'
    'AppServerProcess.ps1'
    'SessionController.ps1'
    'SingleInstance.ps1'
    'StartupShortcut.ps1'
    'Theme.ps1'
    'WpfView.ps1'
    'CompactBarView.ps1'
    'QuotaOrbView.ps1'
    'DisplayModeController.ps1'
    'RelayManagerView.ps1'
    'CcSwitchUsageImport.ps1'
    'RelayImportLinkStore.ps1'
    'CcSwitchImportView.ps1'
    'CcSwitchImportController.ps1'
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

        [AllowNull()]
        [string]$ProgramRoot,

        [ValidateNotNullOrEmpty()]
        [string]$InstancePrefix = 'Local\CodexQuotaMonitor',

        [ValidateRange(0, 86400)]
        [int]$RunForSeconds = 0,

        [ValidateRange(25, 1000)]
        [int]$TickMilliseconds = 100,

        [ValidateRange(1, 300)]
        [int]$RequestTimeoutSeconds = 10,

        [Parameter(DontShow)]
        [AllowNull()]
        [System.Collections.IDictionary]$FunctionOverrides,

        [Parameter(DontShow)]
        [switch]$RequestRefreshWhenReady,

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
        ObjectField = ${function:Get-ObjectField}
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
        ReadRelayProviders = ${function:Read-RelayProviderStore}
        WriteRelayProviders = ${function:Write-RelayProviderStore}
        DiscoverCcSwitch = ${function:Invoke-CcSwitchUsageDiscovery}
        ReadRelayImportLinks = ${function:Read-RelayImportLinkStore}
        WriteRelayImportLinks = ${function:Write-RelayImportLinkStore}
        WriteRelayImportTransaction = ${function:Write-RelayProviderImportTransaction}
        ReadRelayCache = ${function:Read-RelayCache}
        WriteRelayCache = ${function:Write-RelayCache}
        ProtectRelaySecret = ${function:Protect-RelaySecret}
        UnprotectRelaySecret = ${function:Unprotect-RelaySecret}
        StartRelayClient = ${function:Start-RelayScriptClient}
        StopRelayClient = ${function:Stop-RelayScriptClient}
        QueryRelay = ${function:Invoke-RelayScriptQuery}
        NewRelayState = ${function:New-RelayProviderState}
        StartRelayAttempt = ${function:Start-RelayProviderAttempt}
        CompleteRelaySuccess = ${function:Complete-RelayProviderSuccess}
        CompleteRelayFailure = ${function:Complete-RelayProviderFailure}
        NewRelayScheduler = ${function:New-RelaySchedulerState}
        RelaySchedulerActions = ${function:Get-RelaySchedulerActions}
        CompleteRelayScheduler = ${function:Complete-RelaySchedulerAction}
        RelayFailurePolicy = ${function:Get-RelaySchedulerFailurePolicy}
        RelayPresentationRows = ${function:ConvertTo-RelayPresentationRow}
        MergePresentationRows = ${function:Merge-MonitorPresentationRows}
        CombinedSeverity = ${function:Get-CombinedQuotaSeverity}
        CombinedTooltip = ${function:Get-CombinedTrayTooltip}
        WorkAreas = ${function:Get-MonitorWorkAreas}
        SetPlacement = ${function:Set-ResolvedWindowPlacement}
        InitializeDesktop = ${function:Initialize-MonitorDesktopPresentation}
        NewWindow = ${function:New-QuotaWindowView}
        NewCompactBar = ${function:New-CompactBarView}
        NewOrb = ${function:New-QuotaOrbView}
        NewDisplay = ${function:New-MonitorDisplayModeController}
        NewRelayManager = ${function:New-RelayManagerView}
        NewCcSwitchImportView = ${function:New-CcSwitchImportView}
        NewCcSwitchImportController = ${function:New-CcSwitchImportController}
        NewRelayManagerController = ${function:New-RelayManagerController}
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

    if ($null -ne $FunctionOverrides) {
        foreach ($entry in $FunctionOverrides.GetEnumerator()) {
            $name = [string]$entry.Key
            $property = $functions.PSObject.Properties[$name]
            if ($null -eq $property) {
                throw [ArgumentException]::new('Runtime function override name is not supported.')
            }
            if ($entry.Value -isnot [scriptblock]) {
                throw [ArgumentException]::new('Runtime function overrides must be script blocks.')
            }

            $property.Value = [scriptblock]$entry.Value
        }
    }

    $pathsFunction = $functions.GetPaths
    $paths = & $pathsFunction `
        -LocalAppData $LocalAppData `
        -Startup $Startup `
        -ProgramRoot $ProgramRoot
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
        RelayProviders = @()
        RelayCache = $null
        RelayStates = [ordered]@{}
        RelayScheduler = $null
        RelayClient = $null
        RelayHostState = 'Disabled'
        RelayHostStartFailures = 0
        NextRelayHostStartAt = [DateTimeOffset]::MinValue
        RelayManualRefreshPending = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        RelayRows = @()
        CombinedRows = @()
        WindowView = $null
        CompactBarView = $null
        OrbView = $null
        DisplayController = $null
        RelayManagerView = $null
        RelayManagerController = $null
        CcSwitchImportView = $null
        CcSwitchImportController = $null
        TrayView = $null
        Interaction = $null
        RefreshEvent = [Threading.AutoResetEvent]::new($false)
        ResumeEvent = [Threading.AutoResetEvent]::new($false)
        RefreshWhenReady = [bool]$RequestRefreshWhenReady
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
        $displayWindows = @(
            if ($session.Status -eq 'Live') {
                $session.QuotaWindows
            }
            else {
                $runtime.LastQuotaWindows
            }
        )
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
        $relayStates = @($runtime.RelayStates.Values)
        $relayLiveCount = @($relayStates | Where-Object Status -eq 'Live').Count
        $relayStaleCount = @($relayStates | Where-Object Status -eq 'Stale').Count
        $relayInvalidCount = @(
            $relayStates | Where-Object Status -in @('AuthRequired', 'InvalidScript')
        ).Count
        $objectFieldFunction = $runtime.Functions.ObjectField
        $appearance = & $objectFieldFunction -InputObject $runtime.Settings -Name 'Appearance'
        $displayMode = [string](& $objectFieldFunction -InputObject $appearance -Name 'DisplayMode')
        if ($displayMode -notin @('Full', 'CompactBar', 'Orb')) {
            $displayMode = 'Full'
        }
        $theme = [string](& $objectFieldFunction -InputObject $appearance -Name 'Theme')
        if ($theme -notin @('Light', 'Dark')) {
            $theme = 'Dark'
        }
        $signature = @(
            [string]$session.Status,
            [string]$planType,
            [string]$displayWindows.Count,
            [string]$lastSuccess,
            [string]$runtime.ErrorCategory,
            [string]$errorMessage,
            [string]$runtime.RelayProviders.Count,
            [string]$relayLiveCount,
            [string]$relayStaleCount,
            [string]$relayInvalidCount,
            [string]$runtime.RelayHostState,
            [string]$displayMode,
            [string]$theme
        ) -join '|'
        if (-not $Force -and $signature -ceq $runtime.LastHealthSignature) {
            return
        }

        $health = [ordered]@{
            SchemaVersion = 2
            Status = [string]$session.Status
            PlanType = $planType
            QuotaWindowCount = [int]$displayWindows.Count
            LastSuccessAt = if ($null -eq $lastSuccess) { $null } else { $lastSuccess.ToUniversalTime().ToString('o') }
            LastErrorCategory = $runtime.ErrorCategory
            LastErrorMessage = $errorMessage
            ProcessId = [int]$PID
            UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
            RelayProviderCount = [int]$runtime.RelayProviders.Count
            RelayLiveCount = [int]$relayLiveCount
            RelayStaleCount = [int]$relayStaleCount
            RelayInvalidCount = [int]$relayInvalidCount
            RelayHostState = [string]$runtime.RelayHostState
            DisplayMode = $displayMode
            Theme = $theme
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

    $stopRelayClient = {
        if ($null -ne $runtime.RelayClient) {
            $stopFunction = $runtime.Functions.StopRelayClient
            try {
                & $stopFunction -Client $runtime.RelayClient -TimeoutMilliseconds 2000
            }
            catch {}
            $runtime.RelayClient = $null
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

    $startRelayHost = {
        param([DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)

        $enabledProviders = @($runtime.RelayProviders | Where-Object Enabled)
        if ($enabledProviders.Count -eq 0) {
            $runtime.RelayHostState = 'Disabled'
            return $false
        }
        if ($null -ne $runtime.RelayClient) {
            $clientExited = $false
            try {
                if ($null -ne $runtime.RelayClient.Process) {
                    $clientExited = [bool]$runtime.RelayClient.Process.HasExited
                }
            }
            catch { $clientExited = $true }
            if (-not $clientExited -and -not [bool]$runtime.RelayClient.Disposed) {
                $runtime.RelayHostState = 'Live'
                return $true
            }
            & $stopRelayClient
        }
        if ($Now -lt $runtime.NextRelayHostStartAt) {
            return $false
        }

        try {
            $startFunction = $runtime.Functions.StartRelayClient
            $runtime.RelayClient = & $startFunction `
                -ExecutablePath $runtime.Paths.RelayHost `
                -ArgumentList @() `
                -WorkingDirectory (Split-Path -Parent $runtime.Paths.RelayHost)
            $runtime.RelayHostStartFailures = 0
            $runtime.NextRelayHostStartAt = [DateTimeOffset]::MinValue
            $runtime.RelayHostState = 'Live'
            return $true
        }
        catch {
            $runtime.RelayClient = $null
            $runtime.RelayHostStartFailures = [int]$runtime.RelayHostStartFailures + 1
            if ($runtime.RelayHostStartFailures -ge 3) {
                $runtime.RelayHostState = 'Unavailable'
                $runtime.NextRelayHostStartAt = $Now.AddSeconds(30)
            }
            else {
                $runtime.RelayHostState = 'Starting'
                $runtime.NextRelayHostStartAt = $Now.AddSeconds(1)
            }
            return $false
        }
    }.GetNewClosure()

    $writeRelayLastGoodCache = {
        $cacheProviders = [Collections.Generic.List[object]]::new()
        foreach ($provider in @($runtime.RelayProviders)) {
            $providerId = [string]$provider.Id
            $state = $runtime.RelayStates[$providerId]
            if ($null -eq $state -or $null -eq $state.LastSuccessAt -or
                @($state.Results).Count -eq 0) {
                continue
            }
            $cacheProviders.Add([pscustomobject][ordered]@{
                ProviderId = $providerId
                UpdatedAt = ([DateTimeOffset]$state.LastSuccessAt).ToUniversalTime().ToString('o')
                Results = [object[]]@($state.Results)
            })
        }
        $cache = [pscustomobject][ordered]@{
            SchemaVersion = 1
            Providers = [object[]]$cacheProviders.ToArray()
        }
        $writeFunction = $runtime.Functions.WriteRelayCache
        & $writeFunction -Path $runtime.Paths.RelayCache -Cache $cache
        $runtime.RelayCache = $cache
    }.GetNewClosure()

    $refreshCombinedPresentation = {
        param([DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)

        $relayRows = [Collections.Generic.List[object]]::new()
        $relayPresentationFunction = $runtime.Functions.RelayPresentationRows
        foreach ($provider in @($runtime.RelayProviders)) {
            $state = $runtime.RelayStates[[string]$provider.Id]
            if ($null -eq $state) {
                continue
            }
            foreach ($row in @(& $relayPresentationFunction -Provider $provider -State $state)) {
                if ($null -ne $row) { $relayRows.Add($row) }
            }
        }
        $runtime.RelayRows = [object[]]$relayRows.ToArray()

        $displayWindows = @(
            if ($runtime.Session.Status -eq 'Live') {
                $runtime.Session.QuotaWindows
            }
            else {
                $runtime.LastQuotaWindows
            }
        )
        $officialFunction = $runtime.Functions.PresentationRows
        $officialRows = @(& $officialFunction -QuotaWindows $displayWindows -Now $Now)
        $mergeFunction = $runtime.Functions.MergePresentationRows
        $runtime.CombinedRows = @(& $mergeFunction `
            -OfficialRows $officialRows -RelayRows $runtime.RelayRows)
    }.GetNewClosure()

    $runRelayTick = {
        param(
            [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
            [bool]$ManualRefresh = $false
        )
        if ($runtime.RelayProviders.Count -eq 0 -or $null -eq $runtime.RelayScheduler) {
            & $refreshCombinedPresentation $Now
            return
        }
        if ($ManualRefresh) {
            foreach ($provider in @($runtime.RelayProviders | Where-Object Enabled)) {
                $providerId = [string]$provider.Id
                $schedulerEntry = @(
                    $runtime.RelayScheduler.Providers |
                        Where-Object ProviderId -eq $providerId |
                        Select-Object -First 1
                )
                if ($schedulerEntry.Count -gt 0 -and
                    $schedulerEntry[0].PauseReason -ne 'DestinationTrustRequired') {
                    $null = $runtime.RelayManualRefreshPending.Add($providerId)
                }
            }
        }
        if (-not (& $startRelayHost $Now)) {
            & $refreshCombinedPresentation $Now
            return
        }

        $actionsFunction = $runtime.Functions.RelaySchedulerActions
        $hasManualActions = $runtime.RelayManualRefreshPending.Count -gt 0
        $schedulerInput = $runtime.RelayScheduler
        if ($hasManualActions) {
            $schedulerInput = [pscustomobject][ordered]@{
                MaximumConcurrency = [int]$runtime.RelayScheduler.MaximumConcurrency
                Providers = [object[]]@(
                    $runtime.RelayScheduler.Providers | Where-Object {
                        $runtime.RelayManualRefreshPending.Contains([string]$_.ProviderId)
                    }
                )
            }
        }
        $scheduled = & $actionsFunction -State $schedulerInput -Now $Now `
            -ManualRefresh:$hasManualActions
        if (-not $hasManualActions) {
            $runtime.RelayScheduler = $scheduled.State
        }
        $scheduledActions = [object[]]@($scheduled.Actions)
        for ($actionIndex = 0; $actionIndex -lt $scheduledActions.Count; $actionIndex++) {
            $action = $scheduledActions[$actionIndex]
            if ($hasManualActions) {
                $null = $runtime.RelayManualRefreshPending.Remove([string]$action.ProviderId)
            }
            $provider = @(
                $runtime.RelayProviders | Where-Object Id -eq $action.ProviderId
            ) | Select-Object -First 1
            if ($null -eq $provider) {
                continue
            }
            $providerId = [string]$provider.Id
            $state = $runtime.RelayStates[$providerId]
            $attemptFunction = $runtime.Functions.StartRelayAttempt
            $runtime.RelayStates[$providerId] = & $attemptFunction -State $state -Now $Now

            $apiKey = $null
            $accessToken = $null
            $userId = $null
            $credentialsAvailable = $false
            try {
                $unprotectFunction = $runtime.Functions.UnprotectRelaySecret
                $apiKey = & $unprotectFunction -CipherText ([string]$provider.Secrets.ApiKey)
                $accessToken = & $unprotectFunction -CipherText ([string]$provider.Secrets.AccessToken)
                $userId = & $unprotectFunction -CipherText ([string]$provider.Secrets.UserId)
                $credentialsAvailable = $true
            }
            catch {
                $response = [pscustomobject]@{
                    Ok = $false
                    Error = [pscustomobject]@{
                        Category = 'Authentication'
                        Message = '请重新输入中转站凭据。'
                        HttpStatus = $null
                        RetryAfterSeconds = $null
                    }
                }
            }
            try {
                if ($credentialsAvailable) {
                    $queryFunction = $runtime.Functions.QueryRelay
                    $response = & $queryFunction -Client $runtime.RelayClient -Provider $provider `
                        -Secrets ([ordered]@{
                            ApiKey = $apiKey
                            AccessToken = $accessToken
                            UserId = $userId
                        })
                }
            }
            catch {
                $response = [pscustomobject]@{
                    Ok = $false
                    Error = [pscustomobject]@{
                        Category = 'SidecarLifecycle'
                        Message = '中转站脚本主机不可用。'
                        HttpStatus = $null
                        RetryAfterSeconds = $null
                    }
                }
            }
            finally {
                $apiKey = $null
                $accessToken = $null
                $userId = $null
            }

            $schedulerCompleteFunction = $runtime.Functions.CompleteRelayScheduler
            if ($null -ne $response -and [bool]$response.Ok) {
                $successFunction = $runtime.Functions.CompleteRelaySuccess
                $nextState = & $successFunction -State $runtime.RelayStates[$providerId] `
                    -Results ([object[]]@($response.Results)) -Now $Now
                $runtime.RelayStates[$providerId] = $nextState
                if ($nextState.Status -eq 'Live') {
                    $runtime.RelayScheduler = & $schedulerCompleteFunction `
                        -State $runtime.RelayScheduler -ProviderId $providerId `
                        -Outcome Success -Now $Now
                    try { & $writeRelayLastGoodCache } catch {}
                }
                else {
                    $runtime.RelayScheduler = & $schedulerCompleteFunction `
                        -State $runtime.RelayScheduler -ProviderId $providerId `
                        -Outcome Failure -Category 'Authentication' -Now $Now
                }
                continue
            }

            $category = [string]$response.Error.Category
            if ([string]::IsNullOrWhiteSpace($category)) {
                $category = 'SidecarLifecycle'
            }
            $httpStatus = $response.Error.HttpStatus
            $retryAfter = $response.Error.RetryAfterSeconds
            $policyFunction = $runtime.Functions.RelayFailurePolicy
            $policy = & $policyFunction -Category $category -HttpStatus $httpStatus
            $stateCategory = if ($category -eq 'HttpStatus' -and [int]$httpStatus -eq 404) {
                'EndpointNotFound'
            }
            elseif ($category -eq 'HttpStatus' -and [int]$httpStatus -eq 429) {
                'RateLimit'
            }
            elseif ($policy -eq 'Authentication') {
                'Authentication'
            }
            elseif ($policy -eq 'TrustRequired') {
                'DestinationTrustRequired'
            }
            else {
                $category
            }
            $failureFunction = $runtime.Functions.CompleteRelayFailure
            $runtime.RelayStates[$providerId] = & $failureFunction `
                -State $runtime.RelayStates[$providerId] -Category $stateCategory `
                -Now $Now -RetryAfterSeconds $retryAfter
            $runtime.RelayScheduler = & $schedulerCompleteFunction `
                -State $runtime.RelayScheduler -ProviderId $providerId `
                -Outcome Failure -Category $category -HttpStatus $httpStatus `
                -RetryAfterSeconds $retryAfter -Now $Now

            $clientUnavailable = $category -eq 'SidecarLifecycle'
            try {
                $clientUnavailable = $clientUnavailable -or [bool]$runtime.RelayClient.Disposed -or
                    [bool]$runtime.RelayClient.Process.HasExited
            }
            catch { $clientUnavailable = $true }
            if ($clientUnavailable) {
                if (-not $hasManualActions -and $actionIndex + 1 -lt $scheduledActions.Count) {
                    $unexecuted = [Collections.Generic.HashSet[string]]::new(
                        [StringComparer]::OrdinalIgnoreCase
                    )
                    foreach ($pendingAction in @(
                        $scheduledActions[($actionIndex + 1)..($scheduledActions.Count - 1)]
                    )) {
                        $null = $unexecuted.Add([string]$pendingAction.ProviderId)
                    }
                    $runtime.RelayScheduler = [pscustomobject][ordered]@{
                        MaximumConcurrency = [int]$runtime.RelayScheduler.MaximumConcurrency
                        Providers = [object[]]@(
                            foreach ($entry in @($runtime.RelayScheduler.Providers)) {
                                if ($unexecuted.Contains([string]$entry.ProviderId)) {
                                    [pscustomobject][ordered]@{
                                        ProviderId = [string]$entry.ProviderId
                                        Enabled = [bool]$entry.Enabled
                                        IntervalMinutes = [int]$entry.IntervalMinutes
                                        InFlight = $false
                                        NextDueAt = [DateTimeOffset]$entry.NextDueAt
                                        ConsecutiveFailures = [int]$entry.ConsecutiveFailures
                                        PauseReason = $entry.PauseReason
                                    }
                                }
                                else {
                                    $entry
                                }
                            }
                        )
                    }
                }
                & $stopRelayClient
                $runtime.RelayHostState = 'Starting'
                $runtime.NextRelayHostStartAt = $Now.AddSeconds(1)
                break
            }
        }
        & $refreshCombinedPresentation $Now
    }.GetNewClosure()

    $refreshUi = {
        param([DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)

        if ($Headless -or $null -eq $runtime.DisplayController -or $null -eq $runtime.TrayView) {
            return
        }

        $session = $runtime.Session
        $displayWindows = @(
            if ($session.Status -eq 'Live') {
                $session.QuotaWindows
            }
            else {
                $runtime.LastQuotaWindows
            }
        )
        & $runtime.DisplayController.SetSnapshot ([object[]]@($runtime.CombinedRows))

        $severityFunction = $runtime.Functions.CombinedSeverity
        $severityState = & $severityFunction -Rows ([object[]]@($runtime.CombinedRows))
        & $runtime.TrayView.SetSeverity ([string]$severityState.Severity)

        $tooltipFunction = $runtime.Functions.CombinedTooltip
        $tooltip = & $tooltipFunction -Rows ([object[]]@($runtime.CombinedRows))
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
        if ($runtime.RefreshWhenReady -and $runtime.Session.Initialized) {
            $runtime.RefreshWhenReady = $false
            $manualRefresh = $true
        }
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

        try {
            & $runRelayTick $now ([bool]($manualRefresh -or $resumeRefresh))
        }
        catch {
            & $stopRelayClient
            $runtime.RelayHostState = 'Unavailable'
            $runtime.NextRelayHostStartAt = $now.AddSeconds(30)
            try { & $refreshCombinedPresentation $now } catch {}
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

        $readRelayProvidersFunction = $functions.ReadRelayProviders
        $relayProviderDocument = & $readRelayProvidersFunction -Path $paths.RelayProviders
        $runtime.RelayProviders = [object[]]@($relayProviderDocument.Providers)
        $readRelayCacheFunction = $functions.ReadRelayCache
        $runtime.RelayCache = & $readRelayCacheFunction -Path $paths.RelayCache
        $runtime.RelayStates = [ordered]@{}
        $newRelayStateFunction = $functions.NewRelayState
        foreach ($provider in @($runtime.RelayProviders)) {
            $providerId = [string]$provider.Id
            $cached = @(
                $runtime.RelayCache.Providers |
                    Where-Object ProviderId -eq $providerId |
                    Select-Object -First 1
            )
            if ($cached.Count -eq 0) {
                $runtime.RelayStates[$providerId] = & $newRelayStateFunction `
                    -ProviderId $providerId -Enabled ([bool]$provider.Enabled)
            }
            else {
                $runtime.RelayStates[$providerId] = & $newRelayStateFunction `
                    -ProviderId $providerId -Enabled ([bool]$provider.Enabled) `
                    -CachedResults ([object[]]@($cached[0].Results)) `
                    -CachedAt $cached[0].UpdatedAt
            }
        }
        $newRelaySchedulerFunction = $functions.NewRelayScheduler
        $runtime.RelayScheduler = & $newRelaySchedulerFunction `
            -Providers $runtime.RelayProviders -Now ([DateTimeOffset]::UtcNow) `
            -MaximumConcurrency 2
        $null = & $startRelayHost ([DateTimeOffset]::UtcNow)
        & $refreshCombinedPresentation ([DateTimeOffset]::UtcNow)

        if (-not $Headless) {
            $newWindowFunction = $functions.NewWindow
            $runtime.WindowView = & $newWindowFunction
            $newCompactBarFunction = $functions.NewCompactBar
            $runtime.CompactBarView = & $newCompactBarFunction
            $newOrbFunction = $functions.NewOrb
            $runtime.OrbView = & $newOrbFunction
            $newTrayFunction = $functions.NewTray
            $runtime.TrayView = & $newTrayFunction -Visible:$false

            $newRelayManagerFunction = $functions.NewRelayManager
            $runtime.RelayManagerView = & $newRelayManagerFunction

            $newCcSwitchImportViewFunction = $functions.NewCcSwitchImportView
            $runtime.CcSwitchImportView = & $newCcSwitchImportViewFunction
            $discoverCcSwitchFunction = $functions.DiscoverCcSwitch
            $readRelayImportLinksFunction = $functions.ReadRelayImportLinks
            $defaultCcSwitchDatabasePathFunction = ${function:Get-DefaultCcSwitchDatabasePath}
            $ccSwitchDiscoveryAction = {
                & $discoverCcSwitchFunction -ExecutablePath $paths.RelayHost `
                    -DatabasePath (& $defaultCcSwitchDatabasePathFunction)
            }.GetNewClosure()
            $readRelayImportLinksAction = {
                & $readRelayImportLinksFunction -Path $paths.RelayImportLinks
            }.GetNewClosure()
            $newCcSwitchImportControllerFunction = $functions.NewCcSwitchImportController
            $runtime.CcSwitchImportController = & $newCcSwitchImportControllerFunction `
                -View $runtime.CcSwitchImportView `
                -Discover $ccSwitchDiscoveryAction `
                -ReadLinks $readRelayImportLinksAction `
                -ConvertCandidate ${function:ConvertTo-CcSwitchRelayImportCandidate}

            $writeRelayImportTransactionFunction = $functions.WriteRelayImportTransaction
            $writeRelayStateAction = {
                param($Document, $Mutation)
                & $writeRelayImportTransactionFunction `
                    -ProviderPath $paths.RelayProviders `
                    -LinkPath $paths.RelayImportLinks `
                    -ProviderDocument $Document `
                    -Mutation $Mutation
            }.GetNewClosure()
            $importProviderAction = {
                param($Providers)
                & $runtime.CcSwitchImportController.Show -Providers $Providers
            }.GetNewClosure()
            $protectRelaySecretFunction = $functions.ProtectRelaySecret
            $protectRelaySecretAction = {
                param([AllowEmptyString()][string]$PlainText)
                & $protectRelaySecretFunction -PlainText $PlainText
            }.GetNewClosure()
            $unprotectRelaySecretFunction = $functions.UnprotectRelaySecret
            $unprotectRelaySecretAction = {
                param([AllowEmptyString()][string]$CipherText)
                & $unprotectRelaySecretFunction -CipherText $CipherText
            }.GetNewClosure()
            $queryRelayDraftAction = {
                param($Provider, $Secrets)
                $now = [DateTimeOffset]::UtcNow
                $clientReady = $false
                if ($null -ne $runtime.RelayClient) {
                    try {
                        $clientReady = -not [bool]$runtime.RelayClient.Disposed -and
                            ($null -eq $runtime.RelayClient.Process -or
                                -not [bool]$runtime.RelayClient.Process.HasExited)
                    }
                    catch { $clientReady = $false }
                }
                if (-not $clientReady) {
                    try {
                        & $stopRelayClient
                        $startFunction = $runtime.Functions.StartRelayClient
                        $runtime.RelayClient = & $startFunction `
                            -ExecutablePath $runtime.Paths.RelayHost `
                            -ArgumentList @() `
                            -WorkingDirectory (Split-Path -Parent $runtime.Paths.RelayHost)
                        $runtime.RelayHostState = 'Live'
                    }
                    catch {
                        $runtime.RelayClient = $null
                        $runtime.RelayHostState = 'Unavailable'
                        return [pscustomobject][ordered]@{
                            Ok = $false
                            Error = [pscustomobject][ordered]@{
                                Category = 'SidecarLifecycle'
                                Message = '中转站脚本主机不可用。'
                                HttpStatus = $null
                            }
                        }
                    }
                }
                try {
                    $queryFunction = $runtime.Functions.QueryRelay
                    return & $queryFunction -Client $runtime.RelayClient `
                        -Provider $Provider -Secrets $Secrets
                }
                catch {
                    & $stopRelayClient
                    $runtime.RelayHostState = 'Unavailable'
                    $runtime.NextRelayHostStartAt = $now.AddSeconds(30)
                    return [pscustomobject][ordered]@{
                        Ok = $false
                        Error = [pscustomobject][ordered]@{
                            Category = 'SidecarLifecycle'
                            Message = '中转站脚本主机不可用。'
                            HttpStatus = $null
                        }
                    }
                }
            }.GetNewClosure()
            $removeRelayProviderArtifactsAction = {
                param([string]$ProviderId)
                $runtime.RelayStates.Remove($ProviderId)
                $null = $runtime.RelayManualRefreshPending.Remove($ProviderId)
                $remainingCache = [object[]]@(
                    $runtime.RelayCache.Providers | Where-Object ProviderId -ne $ProviderId
                )
                if ($remainingCache.Count -ne @($runtime.RelayCache.Providers).Count) {
                    $runtime.RelayCache = [pscustomobject][ordered]@{
                        SchemaVersion = 1
                        Providers = $remainingCache
                    }
                    $writeCacheFunction = $runtime.Functions.WriteRelayCache
                    & $writeCacheFunction -Path $runtime.Paths.RelayCache -Cache $runtime.RelayCache
                }
            }.GetNewClosure()
            $applyRelayProvidersAction = {
                param(
                    [AllowEmptyCollection()][object[]]$Providers,
                    [AllowEmptyCollection()][string[]]$ChangedProviderIds = @(),
                    [AllowEmptyCollection()][string[]]$RemovedProviderIds = @(),
                    [bool]$TestPassed = $false
                )
                $changed = [Collections.Generic.HashSet[string]]::new(
                    [StringComparer]::OrdinalIgnoreCase
                )
                foreach ($providerId in @($ChangedProviderIds) + @($RemovedProviderIds)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$providerId)) {
                        $null = $changed.Add([string]$providerId)
                    }
                }
                $cachedProviders = [object[]]@($runtime.RelayCache.Providers)
                $remainingCache = [object[]]@(
                    $cachedProviders | Where-Object {
                        -not $changed.Contains([string]$_.ProviderId)
                    }
                )
                if ($remainingCache.Count -ne $cachedProviders.Count) {
                    $runtime.RelayCache = [pscustomobject][ordered]@{
                        SchemaVersion = 1
                        Providers = $remainingCache
                    }
                    $writeCacheFunction = $runtime.Functions.WriteRelayCache
                    & $writeCacheFunction -Path $runtime.Paths.RelayCache -Cache $runtime.RelayCache
                }
                $oldStates = $runtime.RelayStates
                $runtime.RelayProviders = [object[]]@($Providers)
                $newStates = [ordered]@{}
                $newStateFunction = $runtime.Functions.NewRelayState
                foreach ($provider in @($runtime.RelayProviders)) {
                    $providerId = [string]$provider.Id
                    if (-not $changed.Contains($providerId) -and $null -ne $oldStates[$providerId]) {
                        $newStates[$providerId] = $oldStates[$providerId]
                    }
                    else {
                        $newStates[$providerId] = & $newStateFunction `
                            -ProviderId $providerId -Enabled ([bool]$provider.Enabled)
                    }
                }
                $runtime.RelayStates = $newStates
                $runtime.RelayManualRefreshPending.Clear()
                $newSchedulerFunction = $runtime.Functions.NewRelayScheduler
                $runtime.RelayScheduler = & $newSchedulerFunction `
                    -Providers $runtime.RelayProviders -Now ([DateTimeOffset]::UtcNow) `
                    -MaximumConcurrency 2
                if (@($runtime.RelayProviders | Where-Object Enabled).Count -eq 0) {
                    & $stopRelayClient
                    $runtime.RelayHostState = 'Disabled'
                }
                else {
                    $null = & $startRelayHost ([DateTimeOffset]::UtcNow)
                }
                & $refreshCombinedPresentation ([DateTimeOffset]::UtcNow)
            }.GetNewClosure()
            $confirmRelayDeleteAction = {
                param($Provider)
                $name = [string]$Provider.Name
                return [Windows.MessageBox]::Show(
                    "确定删除中转站「$name」吗？",
                    'Codex 额度监视器',
                    [Windows.MessageBoxButton]::YesNo,
                    [Windows.MessageBoxImage]::Warning
                ) -eq [Windows.MessageBoxResult]::Yes
            }
            $newRelayManagerControllerFunction = $functions.NewRelayManagerController
            $runtime.RelayManagerController = & $newRelayManagerControllerFunction `
                -View $runtime.RelayManagerView `
                -Providers $runtime.RelayProviders `
                -WriteRelayState $writeRelayStateAction `
                -ImportProvider $importProviderAction `
                -ProtectSecret $protectRelaySecretAction `
                -UnprotectSecret $unprotectRelaySecretAction `
                -QueryProvider $queryRelayDraftAction `
                -ApplyProviders $applyRelayProvidersAction `
                -RemoveProviderArtifacts $removeRelayProviderArtifactsAction `
                -ConfirmDelete $confirmRelayDeleteAction

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
                    -RuntimeScriptPath (Join-Path $PSScriptRoot 'Start-CodexQuotaMonitor.ps1') `
                    -PwshPath (Join-Path $PSHOME 'pwsh.exe') `
                    -LauncherScript (Join-Path $paths.App 'Start-CodexQuotaMonitor.vbs')
            }.GetNewClosure()
            $requestRefreshAction = {
                $runtime.RefreshEvent.Set() | Out-Null
            }.GetNewClosure()
            $openTargetAction = {
                param([string]$Target)
                Start-Process -FilePath $Target | Out-Null
            }
            $manageRelaysAction = {
                if ($null -ne $runtime.RelayManagerController) {
                    & $runtime.RelayManagerController.Show
                }
            }.GetNewClosure()

            $newDisplayFunction = $functions.NewDisplay
            $runtime.DisplayController = & $newDisplayFunction `
                -Settings $runtime.Settings `
                -FullView $runtime.WindowView `
                -CompactBarView $runtime.CompactBarView `
                -OrbView $runtime.OrbView `
                -SaveSettings $saveSettingsAction `
                -DeferShow

            $newInteractionFunction = $functions.NewInteraction
            $runtime.Interaction = & $newInteractionFunction `
                -Settings $runtime.Settings `
                -WindowView $runtime.WindowView `
                -DisplayController $runtime.DisplayController `
                -TrayView $runtime.TrayView `
                -SaveSettings $saveSettingsAction `
                -ApplyStartupPreference $startupAction `
                -RequestRefresh $requestRefreshAction `
                -ExitEvent $runtime.Instance.ExitEvent `
                -OpenTarget $openTargetAction `
                -LogDirectory $paths.Logs `
                -OnManageRelays $manageRelaysAction

            $initializeDesktopFunction = $functions.InitializeDesktop
            & $initializeDesktopFunction `
                -WindowView $runtime.WindowView `
                -CompactBarView $runtime.CompactBarView `
                -OrbView $runtime.OrbView `
                -DisplayController $runtime.DisplayController `
                -TrayView $runtime.TrayView `
                -Settings $runtime.Settings `
                -GetWorkAreas $functions.WorkAreas `
                -SetPlacement $functions.SetPlacement

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
            Add-Type -AssemblyName WindowsBase -ErrorAction Stop
            $dispatcher = [Windows.Threading.Dispatcher]::CurrentDispatcher
            $dispatcherFrame = if ($RunForSeconds -gt 0) {
                [Windows.Threading.DispatcherFrame]::new()
            }
            else {
                $null
            }
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
                    if ($null -ne $dispatcherFrame) {
                        $dispatcherFrame.Continue = $false
                    }
                    else {
                        $dispatcher.BeginInvokeShutdown([Windows.Threading.DispatcherPriority]::Normal)
                    }
                }
            }.GetNewClosure()
            $runtime.DispatcherTickHandler = [EventHandler]$dispatcherHandlerScript
            $runtime.DispatcherTimer.add_Tick($runtime.DispatcherTickHandler)
            $runtime.DispatcherTimer.Start()
            if ($null -ne $dispatcherFrame) {
                [Windows.Threading.Dispatcher]::PushFrame($dispatcherFrame)
            }
            else {
                [Windows.Threading.Dispatcher]::Run()
            }
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
        try { & $stopRelayClient } catch {}
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
        if ($null -ne $runtime.RelayManagerController) {
            try { & $runtime.RelayManagerController.Dispose } catch { }
            $runtime.RelayManagerView = $null
        }
        elseif ($null -ne $runtime.RelayManagerView) {
            try { & $runtime.RelayManagerView.Dispose } catch { }
        }
        if ($null -ne $runtime.CcSwitchImportController) {
            try { & $runtime.CcSwitchImportController.Dispose } catch { }
        }
        if ($null -ne $runtime.CcSwitchImportView) {
            try { & $runtime.CcSwitchImportView.Dispose } catch { }
        }
        if ($null -ne $runtime.DisplayController) {
            try { & $runtime.DisplayController.Dispose } catch { }
            $runtime.WindowView = $null
            $runtime.CompactBarView = $null
            $runtime.OrbView = $null
        }
        elseif ($null -ne $runtime.WindowView) {
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
            RelayStates = [object[]]@(
                foreach ($provider in @($runtime.RelayProviders)) {
                    $runtime.RelayStates[[string]$provider.Id]
                }
            )
            RelayRows = [object[]]@($runtime.RelayRows)
            CombinedRows = [object[]]@($runtime.CombinedRows)
            RelayHostState = [string]$runtime.RelayHostState
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
