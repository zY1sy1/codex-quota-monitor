function Copy-RelayManagerDraft {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [switch]$NewIdentity,
        [switch]$ClearTrust
    )
    $get = ${function:Get-MonitorInteractionField}
    $id = if ($NewIdentity) { [guid]::NewGuid().ToString('D') } else {
        [string](& $get $Provider 'Id')
    }
    $providerKind = [string](& $get $Provider 'ProviderKind')
    $requestDefinition = & $get $Provider 'RequestDefinition'
    $copiedRequest = $null
    if ($providerKind -ceq 'Generic' -and $null -ne $requestDefinition) {
        $query = [ordered]@{}
        foreach ($name in @($requestDefinition.Query.PSObject.Properties.Name)) {
            if ([string]::IsNullOrEmpty([string]$name)) { continue }
            $query[$name] = [string]$requestDefinition.Query.$name
        }
        $headers = [ordered]@{}
        foreach ($name in @($requestDefinition.Headers.PSObject.Properties.Name)) {
            if ([string]::IsNullOrEmpty([string]$name)) { continue }
            $headers[$name] = [string]$requestDefinition.Headers.$name
        }
        $copiedRequest = [pscustomobject][ordered]@{
            Method = [string](& $get $requestDefinition 'Method')
            Path = [string](& $get $requestDefinition 'Path')
            Query = [pscustomobject]$query
            Headers = [pscustomobject]$headers
            Body = & $get $requestDefinition 'Body'
        }
    }
    [pscustomobject][ordered]@{
        Id = $id
        Name = [string](& $get $Provider 'Name')
        Enabled = [bool](& $get $Provider 'Enabled')
        ProviderKind = $providerKind
        BaseUrl = [string](& $get $Provider 'BaseUrl')
        RequestDefinition = $copiedRequest
        ExtractorScript = [string](& $get $Provider 'ExtractorScript')
        TimeoutSeconds = [int](& $get $Provider 'TimeoutSeconds')
        IntervalMinutes = [int](& $get $Provider 'IntervalMinutes')
        TrustedDestination = if ($ClearTrust) { $null } else {
            & $get $Provider 'TrustedDestination'
        }
        Secrets = [pscustomobject][ordered]@{ ApiKey = ''; AccessToken = ''; UserId = '' }
    }
}

function New-EmptyRelayManagerDraft {
    [pscustomobject][ordered]@{
        Id = [guid]::NewGuid().ToString('D')
        Name = 'New relay'
        Enabled = $true
        BaseUrl = 'https://'
        ProviderKind = 'Generic'
        RequestDefinition = [pscustomobject][ordered]@{
            Method = 'GET'
            Path = '/user/balance'
            Query = [pscustomobject][ordered]@{}
            Headers = [pscustomobject][ordered]@{ Authorization = 'Bearer {{apiKey}}' }
            Body = $null
        }
        ExtractorScript = 'function(response){return {isValid:response.success??true,invalidMessage:response.message??null,remaining:(response.data??response).balance,unit:(response.data??response).currency??null};}'
        TimeoutSeconds = 10
        IntervalMinutes = 10
        TrustedDestination = $null
        Secrets = [pscustomobject][ordered]@{ ApiKey = ''; AccessToken = ''; UserId = '' }
    }
}

function ConvertTo-RelayManagerPreview {
    param([AllowNull()][object]$Response)
    if ($null -eq $Response) {
        return @([pscustomobject][ordered]@{
            Category = 'SidecarLifecycle'; Message = '中转站脚本主机不可用。'; HttpStatus = $null
        })
    }
    if ([bool](Get-MonitorInteractionField $Response 'Ok')) {
        $safe = [Collections.Generic.List[object]]::new()
        foreach ($row in @(Get-MonitorInteractionField $Response 'Results')) {
            $safe.Add([pscustomobject][ordered]@{
                IsValid = [bool](Get-MonitorInteractionField $row 'IsValid')
                InvalidMessage = Get-MonitorInteractionField $row 'InvalidMessage'
                Remaining = Get-MonitorInteractionField $row 'Remaining'
                Unit = Get-MonitorInteractionField $row 'Unit'
                PlanName = Get-MonitorInteractionField $row 'PlanName'
                Total = Get-MonitorInteractionField $row 'Total'
                Used = Get-MonitorInteractionField $row 'Used'
                Extra = Get-MonitorInteractionField $row 'Extra'
            })
        }
        return [object[]]$safe.ToArray()
    }
    $errorObject = Get-MonitorInteractionField $Response 'Error'
    return @([pscustomobject][ordered]@{
        Category = [string](Get-MonitorInteractionField $errorObject 'Category')
        Message = [string](Get-MonitorInteractionField $errorObject 'Message')
        HttpStatus = Get-MonitorInteractionField $errorObject 'HttpStatus'
    })
}

function Test-RelayManagerDestinationFingerprint {
    param([AllowNull()][string]$Fingerprint)
    $uri = $null
    if ([string]::IsNullOrWhiteSpace($Fingerprint) -or
        -not [Uri]::TryCreate($Fingerprint, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or [string]::IsNullOrEmpty($uri.Host) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or $uri.AbsolutePath -cne '/' -or
        -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
        return $false
    }
    $canonicalHost = if ($uri.HostNameType -eq [UriHostNameType]::IPv6) { "[$($uri.Host)]" } else { $uri.IdnHost }
    $port = if ($uri.IsDefaultPort) {
        if ($uri.Scheme -eq 'https') { 443 } else { 80 }
    }
    else { $uri.Port }
    $canonical = "$($uri.Scheme.ToLowerInvariant())://$($canonicalHost.ToLowerInvariant()):$port"
    return $Fingerprint -ceq $canonical
}

function New-RelayManagerController {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$View,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Providers,
        [Parameter(Mandatory)][scriptblock]$WriteProviders,
        [Parameter(Mandatory)][scriptblock]$ProtectSecret,
        [Parameter(Mandatory)][scriptblock]$UnprotectSecret,
        [Parameter(Mandatory)][scriptblock]$QueryProvider,
        [Parameter(Mandatory)][scriptblock]$ApplyProviders,
        [Parameter(Mandatory)][scriptblock]$RemoveProviderArtifacts,
        [Parameter(Mandatory)][scriptblock]$ConfirmDelete
    )

    $state = [pscustomobject][ordered]@{
        Providers = [object[]]@($Providers)
        PendingSecrets = $null
        TestedDraftId = $null
        Disposed = $false
    }
    $get = ${function:Get-MonitorInteractionField}
    $copyDraft = ${function:Copy-RelayManagerDraft}
    $newDraft = ${function:New-EmptyRelayManagerDraft}
    $toPreview = ${function:ConvertTo-RelayManagerPreview}
    $validFingerprint = ${function:Test-RelayManagerDestinationFingerprint}
    $canonicalizeProvider = ${function:ConvertTo-CanonicalRelayProvider}
    $canonicalizeDocument = ${function:ConvertTo-CanonicalRelayProviderDocument}

    $findProvider = {
        param([AllowNull()][string]$ProviderId)
        return @($state.Providers | Where-Object {
            [string](& $get $_ 'Id') -ceq [string]$ProviderId
        } | Select-Object -First 1)
    }.GetNewClosure()

    $publishProviders = {
        & $View.SetProviders ([object[]]@($state.Providers))
    }.GetNewClosure()

    $add = {
        if ($state.Disposed) { return }
        $state.PendingSecrets = $null
        $state.TestedDraftId = $null
        & $View.SetDraft (& $newDraft)
        & $View.SetPreview @()
        & $View.SetTestState $true $false $null
    }.GetNewClosure()

    $edit = {
        param([string]$ProviderId)
        if ($state.Disposed) { return }
        $provider = @(& $findProvider $ProviderId)
        if ($provider.Count -eq 0) { return }
        $state.PendingSecrets = $null
        $state.TestedDraftId = $null
        & $View.SetDraft (& $copyDraft $provider[0])
        & $View.SetPreview @()
        & $View.SetTestState $true $false $null
    }.GetNewClosure()

    $duplicate = {
        param([string]$ProviderId)
        if ($state.Disposed) { return }
        $provider = @(& $findProvider $ProviderId)
        if ($provider.Count -eq 0) { return }
        $state.PendingSecrets = $null
        $state.TestedDraftId = $null
        $draft = & $copyDraft $provider[0] -NewIdentity -ClearTrust
        $draft.Name = "$($draft.Name) copy"
        & $View.SetDraft $draft
        & $View.SetPreview @()
        & $View.SetTestState $true $false $null
    }.GetNewClosure()

    $delete = {
        param([string]$ProviderId)
        if ($state.Disposed) { return }
        $provider = @(& $findProvider $ProviderId)
        if ($provider.Count -eq 0 -or -not [bool](& $ConfirmDelete $provider[0])) { return }
        $remaining = [object[]]@($state.Providers | Where-Object {
            [string](& $get $_ 'Id') -cne [string]$ProviderId
        })
        $document = & $canonicalizeDocument ([ordered]@{
            SchemaVersion = 2; Providers = $remaining
        })
        if ($null -eq $document) { throw 'Relay provider deletion produced an invalid store.' }
        try {
            & $WriteProviders $document
            & $RemoveProviderArtifacts $ProviderId
            $state.Providers = [object[]]@($document.Providers)
            & $ApplyProviders $state.Providers @() @($ProviderId) $false
            & $publishProviders
        }
        catch {
            & $View.SetTestState $false $false 'Unable to delete the relay provider.'
        }
    }.GetNewClosure()

    $save = {
        if ($state.Disposed) { return $false }
        $draft = & $View.ReadDraft
        if ($null -eq $draft) { return $false }
        $id = [string](& $get $draft 'Id')
        $currentItems = @(& $findProvider $id)
        $current = if ($currentItems.Count -eq 0) { $null } else { $currentItems[0] }
        $enteredSecrets = & $get $draft 'Secrets'
        $cipherSecrets = [ordered]@{}
        foreach ($name in @('ApiKey', 'AccessToken', 'UserId')) {
            $plain = [string](& $get $enteredSecrets $name)
            if ([string]::IsNullOrEmpty($plain) -and $null -ne $state.PendingSecrets) {
                $plain = [string](& $get $state.PendingSecrets $name)
            }
            if (-not [string]::IsNullOrEmpty($plain)) {
                $cipherSecrets[$name] = [string](& $ProtectSecret $plain)
            }
            elseif ($null -ne $current) {
                $existingSecrets = & $get $current 'Secrets'
                $cipherSecrets[$name] = [string](& $get $existingSecrets $name)
            }
            else {
                $cipherSecrets[$name] = ''
            }
        }
        $providerKind = [string](& $get $draft 'ProviderKind')
        $candidate = [ordered]@{
            Id = $id
            Name = [string](& $get $draft 'Name')
            Enabled = [bool](& $get $draft 'Enabled')
            BaseUrl = [string](& $get $draft 'BaseUrl')
            ProviderKind = $providerKind
            RequestDefinition = & $get $draft 'RequestDefinition'
            ExtractorScript = [string](& $get $draft 'ExtractorScript')
            TimeoutSeconds = [int](& $get $draft 'TimeoutSeconds')
            IntervalMinutes = [int](& $get $draft 'IntervalMinutes')
            TrustedDestination = & $get $draft 'TrustedDestination'
            Secrets = $cipherSecrets
        }
        $canonical = & $canonicalizeProvider $candidate
        if ($null -eq $canonical) {
            & $View.SetTestState $false $false '中转站设置无效。'
            return $false
        }
        $updated = [Collections.Generic.List[object]]::new()
        $replaced = $false
        foreach ($provider in @($state.Providers)) {
            if ([string](& $get $provider 'Id') -ceq $id) {
                $updated.Add($canonical); $replaced = $true
            }
            else { $updated.Add($provider) }
        }
        if (-not $replaced) { $updated.Add($canonical) }
        $document = & $canonicalizeDocument ([ordered]@{
            SchemaVersion = 2; Providers = [object[]]$updated.ToArray()
        })
        if ($null -eq $document) {
            & $View.SetTestState $false $false '中转站设置无效。'
            return $false
        }
        try {
            & $WriteProviders $document
            $state.Providers = [object[]]@($document.Providers)
            $testPassed = $state.TestedDraftId -ceq $id
            & $ApplyProviders $state.Providers @($id) @() $testPassed
            $state.PendingSecrets = $null
            $state.TestedDraftId = $null
            & $publishProviders
            return $true
        }
        catch {
            & $View.SetTestState $false $false '无法保存中转站。'
            return $false
        }
    }.GetNewClosure()

    $test = {
        if ($state.Disposed) { return }
        $draft = & $View.ReadDraft
        if ($null -eq $draft) { return }
        $id = [string](& $get $draft 'Id')
        $currentItems = @(& $findProvider $id)
        $current = if ($currentItems.Count -eq 0) { $null } else { $currentItems[0] }
        $entered = & $get $draft 'Secrets'
        $secrets = [ordered]@{}
        try {
            foreach ($name in @('ApiKey', 'AccessToken', 'UserId')) {
                $plain = [string](& $get $entered $name)
                if ([string]::IsNullOrEmpty($plain) -and $null -ne $current) {
                    $cipher = [string](& $get (& $get $current 'Secrets') $name)
                    if (-not [string]::IsNullOrEmpty($cipher)) {
                        $plain = [string](& $UnprotectSecret $cipher)
                    }
                }
                $secrets[$name] = $plain
            }
        }
        catch {
            & $View.SetPreview @([pscustomobject][ordered]@{
                Category = 'Authentication'; Message = '请重新输入中转站凭据。'; HttpStatus = $null
            })
            & $View.SetTestState $true $false '测试失败。'
            return
        }
        & $View.SetTestState $false $true '正在测试…'
        try {
            $response = & $QueryProvider $draft $secrets
            $errorObject = & $get $response 'Error'
            if (-not [bool](& $get $response 'Ok') -and
                [string](& $get $errorObject 'Category') -ceq 'DestinationTrustRequired') {
                $fingerprint = [string](& $get $errorObject 'DestinationFingerprint')
                $fingerprintIsValid = & $validFingerprint $fingerprint
                $trustAccepted = if ($fingerprintIsValid) {
                    [bool](& $View.ConfirmDestinationTrust $fingerprint)
                }
                else { $false }
                if ($trustAccepted) {
                    $state.PendingSecrets = [pscustomobject][ordered]@{
                        ApiKey = [string]$secrets.ApiKey
                        AccessToken = [string]$secrets.AccessToken
                        UserId = [string]$secrets.UserId
                    }
                    $trustedDraft = & $copyDraft $draft
                    $trustedDraft.TrustedDestination = $fingerprint
                    $response = & $QueryProvider $trustedDraft $secrets
                    & $View.SetDraft $trustedDraft
                    $draft = $trustedDraft
                }
            }
            $preview = & $toPreview $response
            & $View.SetPreview $preview
            if ([bool](& $get $response 'Ok')) {
                $state.TestedDraftId = [string](& $get $draft 'Id')
                & $View.SetTestState $true $false '测试成功。'
            }
            else {
                $state.TestedDraftId = $null
                & $View.SetTestState $true $false '测试失败。'
            }
        }
        catch {
            $state.TestedDraftId = $null
            & $View.SetPreview @([pscustomobject][ordered]@{
                Category = 'SidecarLifecycle'; Message = '中转站脚本主机不可用。'; HttpStatus = $null
            })
            & $View.SetTestState $true $false '测试失败。'
        }
        finally {
            foreach ($name in @('ApiKey', 'AccessToken', 'UserId')) { $secrets[$name] = $null }
            $secrets = $null
        }
    }.GetNewClosure()

    $cancel = {
        $state.PendingSecrets = $null
        $state.TestedDraftId = $null
        return $true
    }.GetNewClosure()
    $show = {
        if ($state.Disposed) { return }
        & $publishProviders
        if ($state.Providers.Count -gt 0) { & $edit ([string](& $get $state.Providers[0] 'Id')) }
        else { & $add }
        $null = & $View.ShowDialog
    }.GetNewClosure()
    $dispose = {
        if ($state.Disposed) { return }
        $state.Disposed = $true
        $state.PendingSecrets = $null
        $state.TestedDraftId = $null
        & $View.SetCallbacks -OnAdd $null -OnEdit $null -OnDuplicate $null -OnDelete $null `
            -OnTest $null -OnSave $null -OnCancel $null
        & $View.Dispose
    }.GetNewClosure()

    & $View.SetCallbacks -OnAdd $add -OnEdit $edit -OnDuplicate $duplicate -OnDelete $delete `
        -OnTest $test -OnSave $save -OnCancel $cancel
    & $publishProviders
    return [pscustomobject][ordered]@{
        State = $state
        Show = $show
        Dispose = $dispose
    }
}

function Get-MonitorInteractionField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name
    )

    if ($InputObject -is [Collections.IDictionary]) {
        return ([Collections.IDictionary]$InputObject)[$Name]
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Set-MonitorInteractionField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name,

        [Parameter(Position = 2)]
        [AllowNull()]
        [object]$Value
    )

    if ($InputObject -is [Collections.IDictionary]) {
        ([Collections.IDictionary]$InputObject)[$Name] = $Value
        return
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
        return
    }

    $property.Value = $Value
}

function ConvertTo-MonitorFiniteCoordinate {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or $Value -is [bool] -or $Value.GetType().IsEnum) {
        return $null
    }

    $typeCode = [Type]::GetTypeCode($Value.GetType())
    if ($typeCode -notin @(
        [TypeCode]::SByte, [TypeCode]::Byte, [TypeCode]::Int16, [TypeCode]::UInt16,
        [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64,
        [TypeCode]::Single, [TypeCode]::Double, [TypeCode]::Decimal
    )) {
        return $null
    }

    try {
        [double]$coordinate = [Convert]::ToDouble(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    catch {
        return $null
    }

    if ([double]::IsNaN($coordinate) -or [double]::IsInfinity($coordinate)) {
        return $null
    }

    return $coordinate
}

function New-MonitorInteractionController {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Settings,

        [Parameter(Mandatory)]
        [object]$WindowView,

        [Parameter()]
        [AllowNull()]
        [object]$DisplayController,

        [Parameter(Mandatory)]
        [object]$TrayView,

        [Parameter(Mandatory)]
        [scriptblock]$SaveSettings,

        [Parameter(Mandatory)]
        [scriptblock]$ApplyStartupPreference,

        [Parameter(Mandatory)]
        [scriptblock]$RequestRefresh,

        [Parameter(Mandatory)]
        [Threading.EventWaitHandle]$ExitEvent,

        [Parameter(Mandatory)]
        [scriptblock]$OpenTarget,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogDirectory,

        [Parameter()]
        [AllowNull()]
        [scriptblock]$OnManageRelays,

        [ValidateNotNullOrEmpty()]
        [string]$UsageUri = 'https://chatgpt.com/codex/settings/usage'
    )

    $windowSettings = Get-MonitorInteractionField -InputObject $Settings -Name 'Window'
    if ($null -eq $windowSettings) {
        throw 'Monitor settings must contain a Window object.'
    }

    $state = [pscustomobject][ordered]@{
        Disposed = $false
    }
    $usesDisplayController = $null -ne $DisplayController
    $getField = ${function:Get-MonitorInteractionField}
    $setField = ${function:Set-MonitorInteractionField}
    $convertCoordinate = ${function:ConvertTo-MonitorFiniteCoordinate}

    $persistPlacement = {
        param(
            [Parameter(Position = 0)]
            [AllowNull()]
            [object]$Placement
        )

        if ($state.Disposed -or $null -eq $Placement) {
            return
        }

        if ($usesDisplayController) {
            & $DisplayController.PersistPlacement `
                -Mode ([string]$DisplayController.State.Mode) `
                -Placement $Placement
            return
        }

        $changed = $false
        foreach ($name in @('Left', 'Top')) {
            $coordinate = & $convertCoordinate -Value (
                & $getField -InputObject $Placement -Name $name
            )
            if ($null -eq $coordinate) {
                continue
            }

            & $setField -InputObject $windowSettings -Name $name -Value $coordinate
            $changed = $true
        }

        if ($changed) {
            & $SaveSettings $Settings
        }
    }.GetNewClosure()

    $hide = {
        if ($state.Disposed) {
            return
        }

        if ($usesDisplayController) {
            & $DisplayController.HideAll
            return
        }
        & $WindowView.Hide
        & $setField -InputObject $windowSettings -Name 'Visible' -Value $false
        & $SaveSettings $Settings
    }.GetNewClosure()

    $showAndActivate = {
        if ($state.Disposed) {
            return
        }

        if ($usesDisplayController) {
            & $DisplayController.ShowCurrent
            return
        }
        if ($null -ne $WindowView.PSObject.Properties['Show']) {
            & $WindowView.Show
        }
        & $WindowView.Activate
        & $setField -InputObject $windowSettings -Name 'Visible' -Value $true
        & $SaveSettings $Settings
    }.GetNewClosure()

    $toggleVisibility = {
        if ($state.Disposed) {
            return
        }

        $isVisible = if ($usesDisplayController) {
            [bool]$DisplayController.State.Visible
        }
        else {
            $placement = & $WindowView.GetPlacement
            [bool](& $getField -InputObject $placement -Name 'Visible')
        }
        if ($isVisible) {
            & $hide
        }
        else {
            & $showAndActivate
        }
    }.GetNewClosure()

    $toggleTopmost = {
        if ($state.Disposed) {
            return
        }

        if ($usesDisplayController) {
            $current = [bool]$DisplayController.State.Topmost
            $desired = -not $current
            try {
                & $DisplayController.SetTopmost $desired
                & $TrayView.SetTopmostChecked $desired
            }
            catch {
                try { & $DisplayController.SetTopmost $current } catch { }
                try { & $TrayView.SetTopmostChecked $current } catch { }
                throw
            }
            return
        }

        $current = [bool](& $getField -InputObject $windowSettings -Name 'Topmost')
        $desired = -not $current
        $windowApplied = $false
        $trayAttempted = $false
        try {
            & $WindowView.SetTopmost $desired
            $windowApplied = $true
            $trayAttempted = $true
            & $TrayView.SetTopmostChecked $desired
            & $setField -InputObject $windowSettings -Name 'Topmost' -Value $desired
            & $SaveSettings $Settings
        }
        catch {
            $primaryError = $_
            & $setField -InputObject $windowSettings -Name 'Topmost' -Value $current
            $rollbackErrors = [Collections.Generic.List[Exception]]::new()
            $rollbackErrors.Add($primaryError.Exception)

            if ($trayAttempted) {
                try { & $TrayView.SetTopmostChecked $current } catch {
                    $rollbackErrors.Add($_.Exception)
                }
            }
            if ($windowApplied) {
                try { & $WindowView.SetTopmost $current } catch {
                    $rollbackErrors.Add($_.Exception)
                }
            }

            if ($rollbackErrors.Count -gt 1) {
                throw [AggregateException]::new(
                    'Changing the always-on-top preference failed and rollback was incomplete.',
                    [Exception[]]$rollbackErrors.ToArray()
                )
            }
            throw $primaryError
        }
    }.GetNewClosure()

    $toggleStartup = {
        if ($state.Disposed) {
            return
        }

        $current = [bool](& $getField -InputObject $Settings -Name 'Startup')
        $desired = -not $current
        $systemApplied = $false
        $trayAttempted = $false

        # The system operation is authoritative. Do not persist a check mark that failed to apply.
        try {
            & $ApplyStartupPreference $desired
            $systemApplied = $true
            $trayAttempted = $true
            & $TrayView.SetStartupChecked $desired
            & $setField -InputObject $Settings -Name 'Startup' -Value $desired
            & $SaveSettings $Settings
        }
        catch {
            $primaryError = $_
            & $setField -InputObject $Settings -Name 'Startup' -Value $current
            $rollbackErrors = [Collections.Generic.List[Exception]]::new()
            $rollbackErrors.Add($primaryError.Exception)

            if ($trayAttempted) {
                try { & $TrayView.SetStartupChecked $current } catch {
                    $rollbackErrors.Add($_.Exception)
                }
            }
            if ($systemApplied) {
                try { & $ApplyStartupPreference $current } catch {
                    $rollbackErrors.Add($_.Exception)
                }
            }

            if ($rollbackErrors.Count -gt 1) {
                throw [AggregateException]::new(
                    'Changing the startup preference failed and rollback was incomplete.',
                    [Exception[]]$rollbackErrors.ToArray()
                )
            }
            throw $primaryError
        }
    }.GetNewClosure()

    $refresh = {
        if (-not $state.Disposed) {
            & $RequestRefresh
        }
    }.GetNewClosure()

    $setDisplayMode = {
        param([ValidateSet('Full', 'CompactBar', 'Orb')][string]$Mode)
        if ($state.Disposed -or -not $usesDisplayController) { return }
        $old = [string]$DisplayController.State.Mode
        try { & $DisplayController.SetMode $Mode; & $TrayView.SetDisplayModeChecked $Mode }
        catch {
            try { & $DisplayController.SetMode $old } catch { }
            try { & $TrayView.SetDisplayModeChecked $old } catch { }
            throw
        }
    }.GetNewClosure()
    $setTheme = {
        param([ValidateSet('Light', 'Dark')][string]$Theme)
        if ($state.Disposed -or -not $usesDisplayController) { return }
        $old = [string]$DisplayController.State.Theme
        try { & $DisplayController.SetTheme $Theme; & $TrayView.SetThemeChecked $Theme }
        catch {
            try { & $DisplayController.SetTheme $old } catch { }
            try { & $TrayView.SetThemeChecked $old } catch { }
            throw
        }
    }.GetNewClosure()
    $setFullLayout = {
        param([ValidateSet('Overview', 'Tabs')][string]$Layout)
        if ($state.Disposed -or -not $usesDisplayController) { return }
        $old = [string]$DisplayController.State.FullLayout
        try { & $DisplayController.SetFullLayout $Layout; & $TrayView.SetFullLayoutChecked $Layout }
        catch {
            try { & $DisplayController.SetFullLayout $old } catch { }
            try { & $TrayView.SetFullLayoutChecked $old } catch { }
            throw
        }
    }.GetNewClosure()
    $manageRelays = {
        if (-not $state.Disposed -and $null -ne $OnManageRelays) { & $OnManageRelays }
    }.GetNewClosure()
    $displayStateChanged = {
        param($displayState)
        if ($state.Disposed) { return }
        & $TrayView.SetDisplayModeChecked ([string]$displayState.Mode)
        & $TrayView.SetThemeChecked ([string]$displayState.Theme)
        & $TrayView.SetFullLayoutChecked ([string]$displayState.FullLayout)
        & $TrayView.SetTopmostChecked ([bool]$displayState.Topmost)
    }.GetNewClosure()

    $openUsage = {
        if (-not $state.Disposed) {
            & $OpenTarget $UsageUri
        }
    }.GetNewClosure()

    $openLogs = {
        if (-not $state.Disposed) {
            & $OpenTarget $LogDirectory
        }
    }.GetNewClosure()

    $exit = {
        if (-not $state.Disposed) {
            $ExitEvent.Set() | Out-Null
        }
    }.GetNewClosure()

    $dispose = {
        if ($state.Disposed) {
            return
        }

        $state.Disposed = $true
        $firstError = $null
        if ($usesDisplayController -and
            $null -ne $DisplayController.PSObject.Properties['SetStateChangedCallback']) {
            try { & $DisplayController.SetStateChangedCallback $null }
            catch { $firstError = $_ }
        }
        if (-not $usesDisplayController) {
            try {
                & $WindowView.SetCallbacks `
                    -OnDrag $null `
                    -OnToggleTopmost $null `
                    -OnHide $null `
                    -OnCloseRequested $null
            }
            catch {
                $firstError = $_
            }
        }

        try {
            if ($usesDisplayController) {
                & $TrayView.SetCallbacks `
                    -OnToggleVisibility $null -OnSetDisplayMode $null -OnSetTheme $null `
                    -OnSetFullLayout $null -OnManageRelays $null -OnToggleTopmost $null `
                    -OnRefresh $null -OnToggleStartup $null -OnOpenUsage $null `
                    -OnOpenLogs $null -OnExit $null
            }
            else {
                & $TrayView.SetCallbacks `
                    -OnToggleVisibility $null `
                    -OnToggleTopmost $null `
                    -OnRefresh $null `
                    -OnToggleStartup $null `
                    -OnOpenUsage $null `
                    -OnOpenLogs $null `
                    -OnExit $null
            }
        }
        catch {
            if ($null -eq $firstError) {
                $firstError = $_
            }
        }

        if ($null -ne $firstError) {
            throw $firstError
        }
    }.GetNewClosure()

    try {
        if ($usesDisplayController) {
            & $TrayView.SetCallbacks `
                -OnToggleVisibility $toggleVisibility -OnSetDisplayMode $setDisplayMode `
                -OnSetTheme $setTheme -OnSetFullLayout $setFullLayout `
                -OnManageRelays $manageRelays -OnToggleTopmost $toggleTopmost `
                -OnRefresh $refresh -OnToggleStartup $toggleStartup `
                -OnOpenUsage $openUsage -OnOpenLogs $openLogs -OnExit $exit
            & $TrayView.SetDisplayModeChecked ([string]$DisplayController.State.Mode)
            & $TrayView.SetThemeChecked ([string]$DisplayController.State.Theme)
            & $TrayView.SetFullLayoutChecked ([string]$DisplayController.State.FullLayout)
            & $TrayView.SetTopmostChecked ([bool]$DisplayController.State.Topmost)
            if ($null -ne $DisplayController.PSObject.Properties['SetStateChangedCallback']) {
                & $DisplayController.SetStateChangedCallback $displayStateChanged
            }
        }
        else {
            & $WindowView.SetCallbacks `
                -OnDrag $persistPlacement `
                -OnToggleTopmost $toggleTopmost `
                -OnHide $hide `
                -OnCloseRequested $hide

            & $TrayView.SetCallbacks `
                -OnToggleVisibility $toggleVisibility `
                -OnToggleTopmost $toggleTopmost `
                -OnRefresh $refresh `
                -OnToggleStartup $toggleStartup `
                -OnOpenUsage $openUsage `
                -OnOpenLogs $openLogs `
                -OnExit $exit

            & $TrayView.SetTopmostChecked ([bool](
                Get-MonitorInteractionField -InputObject $windowSettings -Name 'Topmost'
            ))
        }
        & $TrayView.SetStartupChecked ([bool](
            Get-MonitorInteractionField -InputObject $Settings -Name 'Startup'
        ))
    }
    catch {
        try { & $dispose } catch { }
        throw
    }

    return [pscustomobject][ordered]@{
        State = $state
        ShowAndActivate = $showAndActivate
        Hide = $hide
        ToggleVisibility = $toggleVisibility
        ToggleTopmost = $toggleTopmost
        PersistPlacement = $persistPlacement
        ToggleStartup = $toggleStartup
        Refresh = $refresh
        OpenUsage = $openUsage
        OpenLogs = $openLogs
        Exit = $exit
        Dispose = $dispose
    }
}
