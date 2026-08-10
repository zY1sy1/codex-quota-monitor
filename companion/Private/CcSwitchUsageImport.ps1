function Get-CcSwitchImportPropertyNames {
    param([AllowNull()][object]$InputObject)
    if ($null -eq $InputObject) {
        return @()
    }
    if ($InputObject -is [Collections.IDictionary]) {
        return @(([Collections.IDictionary]$InputObject).Keys | ForEach-Object { [string]$_ })
    }
    return @($InputObject.PSObject.Properties.Name)
}

function Get-CcSwitchImportProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) {
        return [pscustomobject]@{ Found = $false; Value = $null }
    }
    if ($InputObject -is [Collections.IDictionary]) {
        $dictionary = [Collections.IDictionary]$InputObject
        $matchedKey = @($dictionary.Keys | Where-Object { [string]$_ -ceq $Name })
        if ($matchedKey.Count -ne 1) {
            return [pscustomobject]@{ Found = $false; Value = $null }
        }
        return [pscustomobject]@{ Found = $true; Value = $dictionary[$matchedKey[0]] }
    }
    $property = @($InputObject.PSObject.Properties | Where-Object Name -CEQ $Name)
    if ($property.Count -ne 1) {
        return [pscustomobject]@{ Found = $false; Value = $null }
    }
    return [pscustomobject]@{ Found = $true; Value = $property[0].Value }
}

function Test-CcSwitchImportExactFields {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string[]]$Expected
    )
    if ($null -eq $InputObject -or $InputObject -is [string]) {
        return $false
    }
    $names = @(Get-CcSwitchImportPropertyNames $InputObject)
    if ($names.Count -ne $Expected.Count) {
        return $false
    }
    foreach ($name in $Expected) {
        if ($names -cnotcontains $name) {
            return $false
        }
    }
    return $true
}

function Test-CcSwitchImportCollection {
    param([AllowNull()][object]$Value)
    return $null -ne $Value -and
        $Value -is [Collections.IEnumerable] -and
        $Value -isnot [string] -and
        $Value -isnot [Collections.IDictionary]
}

function Test-CcSwitchImportInteger {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][long]$Minimum,
        [Parameter(Mandatory)][long]$Maximum
    )
    if ($null -eq $Value -or $Value -is [bool] -or $Value.GetType().IsEnum) {
        return $false
    }
    if ([Type]::GetTypeCode($Value.GetType()) -notin @(
        [TypeCode]::SByte,
        [TypeCode]::Byte,
        [TypeCode]::Int16,
        [TypeCode]::UInt16,
        [TypeCode]::Int32,
        [TypeCode]::UInt32,
        [TypeCode]::Int64
    )) {
        return $false
    }
    $integer = [long]$Value
    return $integer -ge $Minimum -and $integer -le $Maximum
}

function Test-CcSwitchImportText {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][int]$MaximumBytes,
        [switch]$AllowScriptWhitespace
    )
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or
        [Text.Encoding]::UTF8.GetByteCount([string]$Value) -gt $MaximumBytes) {
        return $false
    }
    foreach ($character in ([string]$Value).ToCharArray()) {
        if (-not [char]::IsControl($character)) {
            continue
        }
        if ($AllowScriptWhitespace -and $character -in @("`r", "`n", "`t")) {
            continue
        }
        return $false
    }
    return $true
}

function Test-CcSwitchImportEndpoint {
    param([AllowNull()][object]$Value)
    if (-not (Test-CcSwitchImportText -Value $Value -MaximumBytes 4096)) {
        return $false
    }
    $uri = $null
    if (-not [Uri]::TryCreate([string]$Value, [UriKind]::Absolute, [ref]$uri)) {
        return $false
    }
    return $uri.Scheme -cin @('http', 'https') -and
        -not [string]::IsNullOrWhiteSpace($uri.Host) -and
        [string]::IsNullOrEmpty($uri.UserInfo) -and
        [string]::IsNullOrEmpty($uri.Query) -and
        [string]::IsNullOrEmpty($uri.Fragment)
}

function New-CcSwitchDiscoveryFailure {
    [pscustomobject][ordered]@{
        Ok = $false
        Providers = [object[]]@()
        Error = [pscustomobject][ordered]@{
            Category = 'CcSwitchSchemaUnsupported'
            Message = 'CC Switch usage discovery failed.'
        }
    }
}

function ConvertTo-CcSwitchDiscoveryResponse {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$InputObject)

    $invalidMessage = 'CC Switch discovery response is invalid.'
    if (-not (Test-CcSwitchImportExactFields -InputObject $InputObject -Expected @(
        'ok', 'providers', 'error'
    ))) {
        throw $invalidMessage
    }
    $ok = (Get-CcSwitchImportProperty $InputObject 'ok').Value
    $rawProviders = (Get-CcSwitchImportProperty $InputObject 'providers').Value
    $rawError = (Get-CcSwitchImportProperty $InputObject 'error').Value
    if ($ok -isnot [bool] -or -not (Test-CcSwitchImportCollection $rawProviders)) {
        throw $invalidMessage
    }
    $providerValues = @($rawProviders)
    if ($providerValues.Count -gt 128) {
        throw $invalidMessage
    }

    if (-not $ok) {
        if ($providerValues.Count -ne 0 -or -not (Test-CcSwitchImportExactFields `
            -InputObject $rawError -Expected @('category', 'message'))) {
            throw $invalidMessage
        }
        $category = (Get-CcSwitchImportProperty $rawError 'category').Value
        $message = (Get-CcSwitchImportProperty $rawError 'message').Value
        if ($category -isnot [string] -or $category -cnotin @(
            'CcSwitchNotFound', 'CcSwitchDatabaseBusy', 'CcSwitchSchemaUnsupported'
        ) -or -not (Test-CcSwitchImportText -Value $message -MaximumBytes 4096)) {
            throw $invalidMessage
        }
        return [pscustomobject][ordered]@{
            Ok = $false
            Providers = [object[]]@()
            Error = [pscustomobject][ordered]@{
                Category = [string]$category
                Message = [string]$message
            }
        }
    }

    if ($null -ne $rawError) {
        throw $invalidMessage
    }
    $providers = [Collections.Generic.List[object]]::new()
    foreach ($rawProvider in $providerValues) {
        $expectedFields = @(
            'sourceProviderId', 'sourceAppType', 'name', 'endpointCandidates',
            'language', 'code', 'timeoutSeconds', 'templateType',
            'autoQueryIntervalMinutes', 'importStatus'
        )
        if (-not (Test-CcSwitchImportExactFields -InputObject $rawProvider -Expected $expectedFields)) {
            throw $invalidMessage
        }
        $sourceProviderId = (Get-CcSwitchImportProperty $rawProvider 'sourceProviderId').Value
        $sourceAppType = (Get-CcSwitchImportProperty $rawProvider 'sourceAppType').Value
        $name = (Get-CcSwitchImportProperty $rawProvider 'name').Value
        $rawEndpoints = (Get-CcSwitchImportProperty $rawProvider 'endpointCandidates').Value
        $language = (Get-CcSwitchImportProperty $rawProvider 'language').Value
        $code = (Get-CcSwitchImportProperty $rawProvider 'code').Value
        $timeout = (Get-CcSwitchImportProperty $rawProvider 'timeoutSeconds').Value
        $templateType = (Get-CcSwitchImportProperty $rawProvider 'templateType').Value
        $interval = (Get-CcSwitchImportProperty $rawProvider 'autoQueryIntervalMinutes').Value
        $status = (Get-CcSwitchImportProperty $rawProvider 'importStatus').Value

        if (-not (Test-CcSwitchImportText -Value $sourceProviderId -MaximumBytes 4096) -or
            -not (Test-CcSwitchImportText -Value $sourceAppType -MaximumBytes 4096) -or
            -not (Test-CcSwitchImportText -Value $name -MaximumBytes 4096) -or
            -not (Test-CcSwitchImportText -Value $language -MaximumBytes 4096) -or
            -not (Test-CcSwitchImportText -Value $templateType -MaximumBytes 4096) -or
            -not (Test-CcSwitchImportInteger -Value $timeout -Minimum 2 -Maximum 30) -or
            -not (Test-CcSwitchImportInteger -Value $interval -Minimum 0 -Maximum 1440) -or
            $status -isnot [string] -or $status -cnotin @(
                'ready', 'credentialDetected', 'unsupportedLanguage'
            ) -or -not (Test-CcSwitchImportCollection $rawEndpoints)) {
            throw $invalidMessage
        }
        $endpointValues = @($rawEndpoints)
        if ($endpointValues.Count -gt 16) {
            throw $invalidMessage
        }
        $endpoints = [Collections.Generic.List[string]]::new()
        $seenEndpoints = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($endpoint in $endpointValues) {
            if (-not (Test-CcSwitchImportEndpoint $endpoint) -or
                -not $seenEndpoints.Add([string]$endpoint)) {
                throw $invalidMessage
            }
            $endpoints.Add([string]$endpoint)
        }

        $isJavaScript = [string]$language -ieq 'javascript'
        if ($status -ceq 'ready') {
            if (-not $isJavaScript -or
                -not (Test-CcSwitchImportText -Value $code -MaximumBytes 262144 `
                    -AllowScriptWhitespace)) {
                throw $invalidMessage
            }
        }
        elseif ($null -ne $code -or
            ($status -ceq 'credentialDetected' -and -not $isJavaScript) -or
            ($status -ceq 'unsupportedLanguage' -and $isJavaScript)) {
            throw $invalidMessage
        }

        $providers.Add([pscustomobject][ordered]@{
            SourceProviderId = [string]$sourceProviderId
            SourceAppType = [string]$sourceAppType
            Name = [string]$name
            EndpointCandidates = [string[]]$endpoints.ToArray()
            Language = [string]$language
            Code = if ($null -eq $code) { $null } else { [string]$code }
            TimeoutSeconds = [int]$timeout
            TemplateType = [string]$templateType
            AutoQueryIntervalMinutes = [int]$interval
            ImportStatus = [string]$status
        })
    }

    return [pscustomobject][ordered]@{
        Ok = $true
        Providers = [object[]]$providers.ToArray()
        Error = $null
    }
}

function Get-DefaultCcSwitchDatabasePath {
    [CmdletBinding()]
    param([string]$UserProfile = $env:USERPROFILE)
    if ([string]::IsNullOrWhiteSpace($UserProfile)) {
        return $null
    }
    try {
        return [IO.Path]::GetFullPath((Join-Path $UserProfile '.cc-switch\cc-switch.db'))
    }
    catch {
        return $null
    }
}

function Invoke-CcSwitchUsageDiscovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$DatabasePath,
        [ValidateRange(100, 30000)][int]$TimeoutMilliseconds = 5000
    )

    $process = $null
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = [IO.Path]::GetFullPath($ExecutablePath)
        $startInfo.ArgumentList.Add('--inspect-cc-switch')
        $startInfo.ArgumentList.Add([IO.Path]::GetFullPath($DatabasePath))
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'Inspector did not start.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $remaining = $TimeoutMilliseconds - [int]$deadline.ElapsedMilliseconds
        if ($remaining -le 0 -or -not $process.WaitForExit($remaining)) {
            try { $process.Kill($true) } catch {}
            throw 'Inspector timed out.'
        }

        $remaining = $TimeoutMilliseconds - [int]$deadline.ElapsedMilliseconds
        $drainTask = [Threading.Tasks.Task]::WhenAll(
            [Threading.Tasks.Task[]]@($stdoutTask, $stderrTask)
        )
        if ($remaining -le 0 -or -not $drainTask.Wait($remaining)) {
            try { $process.Kill($true) } catch {}
            throw 'Inspector output did not close.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()
        if ([Text.Encoding]::UTF8.GetByteCount($stdout) -gt 1048576 -or
            -not $stdout.EndsWith("`n", [StringComparison]::Ordinal) -or
            ([regex]::Matches($stdout, "`n")).Count -ne 1) {
            throw 'Inspector output is invalid.'
        }
        $raw = $stdout.Substring(0, $stdout.Length - 1) |
            ConvertFrom-Json -Depth 12 -ErrorAction Stop
        $response = ConvertTo-CcSwitchDiscoveryResponse $raw
        if (($response.Ok -and $process.ExitCode -ne 0) -or
            (-not $response.Ok -and $process.ExitCode -ne 1)) {
            throw 'Inspector exit code is invalid.'
        }
        return $response
    }
    catch {
        return New-CcSwitchDiscoveryFailure
    }
    finally {
        $deadline.Stop()
        if ($null -ne $process) {
            try { $process.StandardOutput.Dispose() } catch {}
            try { $process.StandardError.Dispose() } catch {}
            $process.Dispose()
        }
    }
}
