function Get-CcSwitchImportControllerField {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [Collections.IDictionary]) {
        return ([Collections.IDictionary]$InputObject)[$Name]
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }
    return $null
}

function Clear-CcSwitchImportControllerDescriptors {
    param([AllowNull()][object[]]$Descriptors)
    foreach ($descriptor in @($Descriptors)) {
        if ($null -eq $descriptor) {
            continue
        }
        if ($descriptor -is [Collections.IDictionary]) {
            if (([Collections.IDictionary]$descriptor).Contains('Code')) {
                ([Collections.IDictionary]$descriptor)['Code'] = $null
            }
            continue
        }
        $property = $descriptor.PSObject.Properties['Code']
        if ($null -ne $property -and $property.IsSettable) {
            $property.Value = $null
        }
    }
}

function New-CcSwitchImportController {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$View,
        [Parameter(Mandatory)][scriptblock]$Discover,
        [Parameter(Mandatory)][scriptblock]$ReadLinks,
        [Parameter(Mandatory)][scriptblock]$ConvertCandidate
    )

    $requiredViewMembers = @(
        'ShowDialog', 'SetSources', 'GetSelection', 'SetSelectionDetails',
        'SetBusy', 'SetStatus', 'ConfirmCustomImport', 'SetCallbacks'
    )
    foreach ($name in $requiredViewMembers) {
        $member = $View.PSObject.Properties[$name]
        if ($null -eq $member -or $member.Value -isnot [scriptblock]) {
            throw "CC Switch import view is missing callable member '$name'."
        }
    }

    $state = [pscustomobject][ordered]@{
        View = $View
        Discover = $Discover
        ReadLinks = $ReadLinks
        ConvertCandidate = $ConvertCandidate
        Providers = [object[]]@()
        Links = [object[]]@()
        Descriptors = [object[]]@()
        Result = $null
        Disposed = $false
    }
    $getField = ${function:Get-CcSwitchImportControllerField}
    $clearDescriptors = ${function:Clear-CcSwitchImportControllerDescriptors}

    $findDescriptor = {
        param([AllowNull()][object]$Selection)
        if ($null -eq $Selection) {
            return $null
        }
        $sourceProviderId = [string](& $getField $Selection 'SourceProviderId')
        $sourceAppType = [string](& $getField $Selection 'SourceAppType')
        if ([string]::IsNullOrWhiteSpace($sourceProviderId) -or
            [string]::IsNullOrWhiteSpace($sourceAppType)) {
            return $null
        }
        return @($state.Descriptors | Where-Object {
            [string](& $getField $_ 'SourceProviderId') -ceq $sourceProviderId -and
            [string](& $getField $_ 'SourceAppType') -ceq $sourceAppType
        } | Select-Object -First 1)[0]
    }.GetNewClosure()

    $findLinkedProvider = {
        param([Parameter(Mandatory)][object]$Descriptor)
        $sourceProviderId = [string](& $getField $Descriptor 'SourceProviderId')
        $sourceAppType = [string](& $getField $Descriptor 'SourceAppType')
        $link = @($state.Links | Where-Object {
            [string](& $getField $_ 'SourceKind') -ceq 'CcSwitchUsageScript' -and
            [string](& $getField $_ 'SourceProviderId') -ceq $sourceProviderId -and
            [string](& $getField $_ 'SourceAppType') -ceq $sourceAppType
        } | Select-Object -First 1)[0]
        if ($null -eq $link) {
            return $null
        }
        $relayProviderId = [string](& $getField $link 'RelayProviderId')
        if ([string]::IsNullOrWhiteSpace($relayProviderId)) {
            return $null
        }
        return @($state.Providers | Where-Object {
            [string](& $getField $_ 'Id') -ieq $relayProviderId
        } | Select-Object -First 1)[0]
    }.GetNewClosure()

    $setSelectionDetails = {
        if ($state.Disposed) {
            return
        }
        $selection = & $state.View.GetSelection
        $descriptor = & $findDescriptor $selection
        if ($null -eq $descriptor) {
            & $state.View.SetSelectionDetails $null
            return
        }

        $status = [string](& $getField $descriptor 'ImportStatus')
        $endpoints = [string[]]@(
            @(& $getField $descriptor 'EndpointCandidates') |
                ForEach-Object { [string]$_ }
        )
        $currentEndpoint = [string](& $getField $selection 'Endpoint')
        $selectedEndpoint = if ($endpoints.Count -eq 1) {
            $endpoints[0]
        }
        elseif ($endpoints.Count -gt 1 -and $endpoints -ccontains $currentEndpoint) {
            $currentEndpoint
        }
        elseif ($endpoints.Count -eq 0) {
            $currentEndpoint
        }
        else {
            $null
        }
        $linkedProvider = & $findLinkedProvider $descriptor
        $conversionText = switch ($status) {
            'Ready' { '可导入。自动模式会优先转换为 Generic。' }
            'CredentialDetected' { '规则中检测到凭据，已阻止导入。' }
            'UnsupportedLanguage' { '规则语言不受支持，已阻止导入。' }
            default { '规则状态不受支持，已阻止导入。' }
        }
        & $state.View.SetSelectionDetails ([pscustomobject][ordered]@{
            EndpointCandidates = $endpoints
            SelectedEndpoint = $selectedEndpoint
            ConversionText = $conversionText
            CanImport = $status -ceq 'Ready'
            CanUpdate = $null -ne $linkedProvider
            DefaultAction = if ($null -ne $linkedProvider) { 'Update' } else { 'Copy' }
            AllowEndpointEntry = $endpoints.Count -eq 0
            RequiresEndpointSelection = $endpoints.Count -gt 1
        })
    }.GetNewClosure()

    $refresh = {
        if ($state.Disposed) {
            return $false
        }
        & $state.View.SetBusy $true
        try {
            & $clearDescriptors $state.Descriptors
            $state.Descriptors = [object[]]@()
            $state.Links = [object[]]@()
            $discovery = & $state.Discover
            if ($null -eq $discovery -or -not [bool](& $getField $discovery 'Ok')) {
                & $state.View.SetSources @()
                & $state.View.SetSelectionDetails $null
                & $state.View.SetStatus '未能读取 CC Switch 查询规则。'
                return $false
            }
            $linkDocument = & $state.ReadLinks
            $state.Descriptors = [object[]]@(& $getField $discovery 'Providers')
            if ($null -ne $linkDocument) {
                $state.Links = [object[]]@(& $getField $linkDocument 'Links')
            }
            $rows = [Collections.Generic.List[object]]::new()
            foreach ($descriptor in $state.Descriptors) {
                $rows.Add([pscustomobject][ordered]@{
                    SourceProviderId = [string](& $getField $descriptor 'SourceProviderId')
                    SourceAppType = [string](& $getField $descriptor 'SourceAppType')
                    DisplayName = [string](& $getField $descriptor 'Name')
                    ImportStatus = [string](& $getField $descriptor 'ImportStatus')
                    EndpointCandidates = [string[]]@(& $getField $descriptor 'EndpointCandidates')
                })
            }
            & $state.View.SetSources ([object[]]$rows.ToArray())
            $statusMessage = if ($rows.Count -eq 0) {
                '未找到可导入的 CC Switch 查询规则。'
            }
            else {
                "已读取 $($rows.Count) 条 CC Switch 查询规则。"
            }
            & $state.View.SetStatus $statusMessage
            return $true
        }
        catch {
            & $clearDescriptors $state.Descriptors
            $state.Descriptors = [object[]]@()
            $state.Links = [object[]]@()
            & $state.View.SetSources @()
            & $state.View.SetSelectionDetails $null
            & $state.View.SetStatus '未能读取 CC Switch 查询规则。'
            return $false
        }
        finally {
            & $state.View.SetBusy $false
        }
    }.GetNewClosure()

    $import = {
        if ($state.Disposed) {
            return $false
        }
        $selection = & $state.View.GetSelection
        $descriptor = & $findDescriptor $selection
        if ($null -eq $descriptor -or
            [string](& $getField $descriptor 'ImportStatus') -cne 'Ready') {
            & $state.View.SetStatus '所选规则不能导入。'
            return $false
        }
        $endpoint = [string](& $getField $selection 'Endpoint')
        $importMode = [string](& $getField $selection 'ImportMode')
        $action = [string](& $getField $selection 'Action')
        if ([string]::IsNullOrWhiteSpace($endpoint) -or
            $importMode -cnotin @('Auto', 'Custom') -or
            $action -cnotin @('Update', 'Copy')) {
            & $state.View.SetStatus '请选择有效的导入选项。'
            return $false
        }
        $endpoints = [string[]]@(& $getField $descriptor 'EndpointCandidates')
        if ($endpoints.Count -gt 0 -and $endpoints -cnotcontains $endpoint) {
            & $state.View.SetStatus '请选择规则提供的目标地址。'
            return $false
        }
        $existingProvider = $null
        if ($action -ceq 'Update') {
            $existingProvider = & $findLinkedProvider $descriptor
            if ($null -eq $existingProvider) {
                & $state.View.SetStatus '未找到可更新的现有查询规则。'
                return $false
            }
        }
        try {
            $candidate = & $state.ConvertCandidate -Descriptor $descriptor -Endpoint $endpoint `
                -ImportMode $importMode -ExistingProvider $existingProvider
            if ([string](& $getField $candidate 'Status') -ceq 'RequiresCustom') {
                $displayName = [string](& $getField $descriptor 'Name')
                if (-not [bool](& $state.View.ConfirmCustomImport $displayName)) {
                    return $false
                }
                $candidate = & $state.ConvertCandidate -Descriptor $descriptor -Endpoint $endpoint `
                    -ImportMode Custom -ExistingProvider $existingProvider
            }
            $draft = & $getField $candidate 'Draft'
            $link = & $getField $candidate 'Link'
            if ([string](& $getField $candidate 'Status') -cne 'Ready' -or
                $null -eq $draft -or $null -eq $link) {
                & $state.View.SetStatus '所选规则不能安全导入。'
                return $false
            }
            $state.Result = [pscustomobject][ordered]@{
                Draft = $draft
                Link = $link
            }
            return $true
        }
        catch {
            & $state.View.SetStatus '所选规则不能安全导入。'
            return $false
        }
    }.GetNewClosure()

    $cancel = {
        $state.Result = $null
        return $true
    }.GetNewClosure()

    & $View.SetCallbacks $refresh $setSelectionDetails $import $cancel

    $show = {
        param([AllowEmptyCollection()][object[]]$Providers = @())
        if ($state.Disposed) {
            return $null
        }
        $state.Providers = [object[]]@($Providers)
        $state.Result = $null
        $null = & $refresh
        $null = & $state.View.ShowDialog
        return $state.Result
    }.GetNewClosure()

    $dispose = {
        if ($state.Disposed) {
            return
        }
        & $state.View.SetCallbacks $null $null $null $null
        & $clearDescriptors $state.Descriptors
        $state.Descriptors = [object[]]@()
        $state.Links = [object[]]@()
        $state.Providers = [object[]]@()
        $state.Result = $null
        $state.Disposed = $true
    }.GetNewClosure()

    return [pscustomobject][ordered]@{
        Show = $show
        Dispose = $dispose
    }
}
