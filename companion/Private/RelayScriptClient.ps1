function Get-RelayClientProperty {
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

function Get-RelayClientPropertyNames {
    param([AllowNull()][object]$InputObject)
    if ($null -eq $InputObject) {
        return @()
    }
    if ($InputObject -is [Collections.IDictionary]) {
        return @($InputObject.Keys | ForEach-Object { [string]$_ })
    }
    return @($InputObject.PSObject.Properties.Name)
}

function ConvertTo-RelayClientMap {
    param([AllowNull()][object]$InputObject)
    $result = [ordered]@{}
    foreach ($name in @(Get-RelayClientPropertyNames $InputObject)) {
        if ([string]::IsNullOrEmpty([string]$name)) { continue }
        $result[$name] = [string](Get-RelayClientProperty $InputObject $name)
    }
    return $result
}

function New-RelayClientFailure {
    param(
        [AllowEmptyString()][string]$Id,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message,
        [AllowNull()][object]$HttpStatus = $null,
        [AllowNull()][object]$RetryAfterSeconds = $null,
        [AllowNull()][object]$DestinationHost = $null,
        [AllowNull()][object]$DestinationFingerprint = $null
    )
    [pscustomobject][ordered]@{
        Id = $Id
        Ok = $false
        Error = [pscustomobject][ordered]@{
            Category = $Category
            Message = $Message
            HttpStatus = $HttpStatus
            RetryAfterSeconds = $RetryAfterSeconds
            DestinationHost = $DestinationHost
            DestinationFingerprint = $DestinationFingerprint
        }
    }
}

function Test-RelayClientInteger {
    param(
        [AllowNull()][object]$Value,
        [long]$Minimum = [long]::MinValue,
        [long]$Maximum = [long]::MaxValue
    )
    if ($null -eq $Value -or $Value -is [bool] -or $Value.GetType().IsEnum -or
        [Type]::GetTypeCode($Value.GetType()) -notin @(
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

function ConvertTo-RelayClientNumber {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return [pscustomobject]@{ Valid = $true; Value = $null }
    }
    if ($Value -is [bool] -or $Value.GetType().IsEnum -or
        [Type]::GetTypeCode($Value.GetType()) -notin @(
            [TypeCode]::SByte,
            [TypeCode]::Byte,
            [TypeCode]::Int16,
            [TypeCode]::UInt16,
            [TypeCode]::Int32,
            [TypeCode]::UInt32,
            [TypeCode]::Int64,
            [TypeCode]::UInt64,
            [TypeCode]::Single,
            [TypeCode]::Double,
            [TypeCode]::Decimal
        )) {
        return $null
    }
    $number = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        return $null
    }
    [pscustomobject]@{ Valid = $true; Value = [double]$number }
}

function ConvertTo-RelayClientString {
    param(
        [AllowNull()][object]$Value,
        [int]$MaximumLength = 4096
    )
    if ($null -eq $Value) {
        return [pscustomobject]@{ Valid = $true; Value = $null }
    }
    if ($Value -isnot [string] -or $Value.Length -gt $MaximumLength) {
        return $null
    }
    [pscustomobject]@{ Valid = $true; Value = [string]$Value }
}

function ConvertTo-RelayClientResponse {
    param(
        [AllowNull()][object]$Response,
        [Parameter(Mandatory)][string]$ExpectedId
    )
    $id = Get-RelayClientProperty $Response 'id'
    $ok = Get-RelayClientProperty $Response 'ok'
    if ($id -isnot [string] -or $id -cne $ExpectedId -or $ok -isnot [bool]) {
        return $null
    }

    if (-not $ok) {
        $error = Get-RelayClientProperty $Response 'error'
        $category = ConvertTo-RelayClientString (Get-RelayClientProperty $error 'category') 128
        $message = ConvertTo-RelayClientString (Get-RelayClientProperty $error 'message') 4096
        if ($null -eq $category -or [string]::IsNullOrWhiteSpace($category.Value) -or
            $null -eq $message -or [string]::IsNullOrWhiteSpace($message.Value)) {
            return $null
        }
        $httpStatusValue = Get-RelayClientProperty $error 'httpStatus'
        $retryValue = Get-RelayClientProperty $error 'retryAfterSeconds'
        if ($null -ne $httpStatusValue -and
            -not (Test-RelayClientInteger $httpStatusValue 100 599)) {
            return $null
        }
        if ($null -ne $retryValue -and
            -not (Test-RelayClientInteger $retryValue 0 ([int]::MaxValue))) {
            return $null
        }
        $destinationHost = ConvertTo-RelayClientString (Get-RelayClientProperty $error 'destinationHost') 4096
        $destinationFingerprint = ConvertTo-RelayClientString (
            (Get-RelayClientProperty $error 'destinationFingerprint')
        ) 4096
        if ($null -eq $destinationHost -or $null -eq $destinationFingerprint) {
            return $null
        }
        return New-RelayClientFailure -Id $id -Category $category.Value -Message $message.Value `
            -HttpStatus $(if ($null -eq $httpStatusValue) { $null } else { [int]$httpStatusValue }) `
            -RetryAfterSeconds $(if ($null -eq $retryValue) { $null } else { [int]$retryValue }) `
            -DestinationHost $destinationHost.Value `
            -DestinationFingerprint $destinationFingerprint.Value
    }

    $rawResults = @(Get-RelayClientProperty $Response 'results')
    if ($rawResults.Count -eq 0 -or $rawResults.Count -gt 32) {
        return $null
    }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($rawResult in $rawResults) {
        $isValid = Get-RelayClientProperty $rawResult 'isValid'
        if ($isValid -isnot [bool]) {
            return $null
        }
        $strings = [ordered]@{}
        foreach ($name in @('invalidMessage', 'unit', 'planName', 'extra')) {
            $converted = ConvertTo-RelayClientString (Get-RelayClientProperty $rawResult $name)
            if ($null -eq $converted) {
                return $null
            }
            $strings[$name] = $converted.Value
        }
        $numbers = [ordered]@{}
        foreach ($name in @('remaining', 'total', 'used')) {
            $converted = ConvertTo-RelayClientNumber (Get-RelayClientProperty $rawResult $name)
            if ($null -eq $converted) {
                return $null
            }
            $numbers[$name] = $converted.Value
        }
        $results.Add([pscustomobject][ordered]@{
            IsValid = [bool]$isValid
            InvalidMessage = $strings.invalidMessage
            Remaining = $numbers.remaining
            Unit = $strings.unit
            PlanName = $strings.planName
            Total = $numbers.total
            Used = $numbers.used
            Extra = $strings.extra
        })
    }

    $meta = Get-RelayClientProperty $Response 'meta'
    $httpStatus = Get-RelayClientProperty $meta 'httpStatus'
    $duration = Get-RelayClientProperty $meta 'durationMs'
    $destination = ConvertTo-RelayClientString (Get-RelayClientProperty $meta 'destinationHost') 4096
    if (-not (Test-RelayClientInteger $httpStatus 100 599) -or
        -not (Test-RelayClientInteger $duration 0 ([long]::MaxValue)) -or
        $null -eq $destination -or [string]::IsNullOrWhiteSpace($destination.Value)) {
        return $null
    }
    [pscustomobject][ordered]@{
        Id = $id
        Ok = $true
        Results = [object[]]$results.ToArray()
        Meta = [pscustomobject][ordered]@{
            HttpStatus = [int]$httpStatus
            DestinationHost = $destination.Value
            DurationMs = [long]$duration
        }
    }
}

function Start-RelayScriptClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExecutablePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [AllowEmptyString()][string]$WorkingDirectory,
        [ValidateRange(1, 10000)][int]$StderrRecordLimit = 32,
        [ValidateRange(32, 65536)][int]$DiagnosticLineLimit = 2048
    )
    if ([IO.Path]::IsPathFullyQualified($ExecutablePath) -and
        -not [IO.File]::Exists($ExecutablePath)) {
        throw [IO.FileNotFoundException]::new('Relay script host executable was not found.')
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $utf8 = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    foreach ($argument in @($ArgumentList)) {
        $startInfo.ArgumentList.Add([string]$argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw [InvalidOperationException]::new('Process.Start returned false.')
        }
        $inputWriter = $process.StandardInput
        $inputWriter.AutoFlush = $false
        $outputReader = $process.StandardOutput
        $errorReader = $process.StandardError
        [pscustomobject][ordered]@{
            Process = $process
            Input = $inputWriter
            Output = $outputReader
            Error = $errorReader
            Gate = [Threading.SemaphoreSlim]::new(1, 1)
            Responses = [Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
            Stderr = [Collections.Concurrent.ConcurrentQueue[string]]::new()
            LastCommand = $null
            StderrRecordLimit = $StderrRecordLimit
            DiagnosticLineLimit = $DiagnosticLineLimit
            OutputReadTask = $outputReader.ReadLineAsync()
            ErrorReadTask = $errorReader.ReadLineAsync()
            StopLock = [object]::new()
            Disposed = $false
        }
    }
    catch {
        try { $process.Dispose() } catch {}
        throw [InvalidOperationException]::new('Relay script host could not be started.')
    }
}

function Add-RelayClientStderrLine {
    param(
        [Parameter(Mandatory)][object]$Client,
        [AllowNull()][string]$Line,
        [AllowEmptyCollection()][string[]]$SecretValues = @()
    )
    if ($null -eq $Line) {
        return
    }
    $sanitized = $Line
    foreach ($secret in @($SecretValues)) {
        if (-not [string]::IsNullOrEmpty($secret)) {
            $sanitized = $sanitized.Replace($secret, '<redacted>')
        }
    }
    if ($sanitized.Length -gt $Client.DiagnosticLineLimit) {
        $sanitized = $sanitized.Substring(0, $Client.DiagnosticLineLimit)
    }
    $Client.Stderr.Enqueue($sanitized)
    while ($Client.Stderr.Count -gt $Client.StderrRecordLimit) {
        $discarded = $null
        $null = $Client.Stderr.TryDequeue([ref]$discarded)
    }
}

function Update-RelayClientStderr {
    param(
        [Parameter(Mandatory)][object]$Client,
        [AllowEmptyCollection()][string[]]$SecretValues = @()
    )
    while ($null -ne $Client.ErrorReadTask -and $Client.ErrorReadTask.IsCompleted) {
        try {
            $line = $Client.ErrorReadTask.GetAwaiter().GetResult()
        }
        catch {
            $line = $null
        }
        if ($null -eq $line) {
            $Client.ErrorReadTask = $null
            break
        }
        Add-RelayClientStderrLine -Client $Client -Line $line -SecretValues $SecretValues
        try {
            $Client.ErrorReadTask = $Client.Error.ReadLineAsync()
        }
        catch {
            $Client.ErrorReadTask = $null
        }
    }
}

function Receive-RelayClientResponse {
    param(
        [Parameter(Mandatory)][object]$Client,
        [Parameter(Mandatory)][string]$ExpectedId
    )
    $stored = $null
    if ($Client.Responses.TryRemove($ExpectedId, [ref]$stored)) {
        return $stored
    }
    if ($null -eq $Client.OutputReadTask -or -not $Client.OutputReadTask.IsCompleted) {
        return $null
    }
    try {
        $line = $Client.OutputReadTask.GetAwaiter().GetResult()
    }
    catch {
        return [pscustomobject]@{ Invalid = $true }
    }
    if ($null -eq $line) {
        $Client.OutputReadTask = $null
        return $null
    }
    try {
        $Client.OutputReadTask = $Client.Output.ReadLineAsync()
    }
    catch {
        $Client.OutputReadTask = $null
    }
    try {
        $raw = $line | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Invalid = $true }
    }
    $responseId = Get-RelayClientProperty $raw 'id'
    if ($responseId -isnot [string]) {
        return [pscustomobject]@{ Invalid = $true }
    }
    $canonical = ConvertTo-RelayClientResponse -Response $raw -ExpectedId $responseId
    if ($null -eq $canonical) {
        return [pscustomobject]@{ Invalid = $true }
    }
    if ($responseId -cne $ExpectedId) {
        $Client.Responses[$responseId] = $canonical
        return $null
    }
    return $canonical
}

function Invoke-RelayScriptQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Client,
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][AllowNull()][object]$Secrets
    )
    $id = [Guid]::NewGuid().ToString('N')
    $timeoutSeconds = [int](Get-RelayClientProperty $Provider 'TimeoutSeconds')
    if ($timeoutSeconds -lt 2) { $timeoutSeconds = 2 }
    if ($timeoutSeconds -gt 30) { $timeoutSeconds = 30 }
    $deadlineMilliseconds = ($timeoutSeconds * 1000) + 2000
    $gateTaken = $false
    $apiKey = [string](Get-RelayClientProperty $Secrets 'ApiKey')
    $accessToken = [string](Get-RelayClientProperty $Secrets 'AccessToken')
    $userId = [string](Get-RelayClientProperty $Secrets 'UserId')
    $json = $null
    $line = $null
    try {
        $gateTaken = $Client.Gate.Wait($deadlineMilliseconds)
        if (-not $gateTaken) {
            return New-RelayClientFailure -Id $id -Category 'Timeout' `
                -Message 'Relay script host request timed out.'
        }
        if ($Client.Disposed) {
            return New-RelayClientFailure -Id $id -Category 'SidecarLifecycle' `
                -Message 'Relay script host is unavailable.'
        }
        $hasExited = $true
        try { $hasExited = $Client.Process.HasExited } catch { $hasExited = $true }
        if ($hasExited) {
            return New-RelayClientFailure -Id $id -Category 'SidecarLifecycle' `
                -Message 'Relay script host exited unexpectedly.'
        }

        $providerKind = [string](Get-RelayClientProperty $Provider 'ProviderKind')
        if ($providerKind -notin @('Generic', 'Custom')) {
            return New-RelayClientFailure -Id $id -Category 'RequestValidation' `
                -Message 'Relay provider kind is invalid.'
        }
        $requestDefinition = $null
        if ($providerKind -ceq 'Generic') {
            $rawRequestDefinition = Get-RelayClientProperty $Provider 'RequestDefinition'
            if ($null -eq $rawRequestDefinition) {
                return New-RelayClientFailure -Id $id -Category 'RequestValidation' `
                    -Message 'Relay request definition is invalid.'
            }
            $requestDefinition = [ordered]@{
                method = [string](Get-RelayClientProperty $rawRequestDefinition 'Method')
                path = [string](Get-RelayClientProperty $rawRequestDefinition 'Path')
                query = ConvertTo-RelayClientMap (Get-RelayClientProperty $rawRequestDefinition 'Query')
                headers = ConvertTo-RelayClientMap (Get-RelayClientProperty $rawRequestDefinition 'Headers')
                body = Get-RelayClientProperty $rawRequestDefinition 'Body'
            }
        }
        $command = [ordered]@{
            id = $id
            operation = 'query'
            providerKind = $providerKind
            baseUrl = [string](Get-RelayClientProperty $Provider 'BaseUrl')
            requestDefinition = $requestDefinition
            extractorScript = [string](Get-RelayClientProperty $Provider 'ExtractorScript')
            secrets = [ordered]@{
                apiKey = $apiKey
                accessToken = $accessToken
                userId = $userId
            }
            timeoutMs = [long]($timeoutSeconds * 1000)
            trustedDestination = Get-RelayClientProperty $Provider 'TrustedDestination'
        }
        $recordedCommand = [ordered]@{}
        foreach ($entry in $command.GetEnumerator()) {
            if ($entry.Key -ceq 'secrets') {
                $recordedCommand[$entry.Key] = [ordered]@{
                    apiKey = '<redacted>'
                    accessToken = '<redacted>'
                    userId = '<redacted>'
                }
            }
            else {
                $recordedCommand[$entry.Key] = $entry.Value
            }
        }
        $Client.LastCommand = [pscustomobject]$recordedCommand
        $json = $command | ConvertTo-Json -Depth 12 -Compress -ErrorAction Stop
        $line = $json.TrimEnd([char]13, [char]10) + [string][char]10
        try {
            $Client.Input.Write($line)
            $Client.Input.Flush()
        }
        catch {
            return New-RelayClientFailure -Id $id -Category 'SidecarLifecycle' `
                -Message 'Relay script host is unavailable.'
        }

        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($watch.ElapsedMilliseconds -lt $deadlineMilliseconds) {
            Update-RelayClientStderr -Client $Client -SecretValues @($apiKey, $accessToken, $userId)
            $response = Receive-RelayClientResponse -Client $Client -ExpectedId $id
            if ($null -ne $response) {
                Update-RelayClientStderr -Client $Client -SecretValues @($apiKey, $accessToken, $userId)
                if ($response.PSObject.Properties['Invalid']) {
                    return New-RelayClientFailure -Id $id -Category 'SidecarLifecycle' `
                        -Message 'Relay script host returned an invalid response.'
                }
                return $response
            }

            $hasExited = $true
            try { $hasExited = $Client.Process.HasExited } catch { $hasExited = $true }
            if ($hasExited -and ($null -eq $Client.OutputReadTask -or $Client.OutputReadTask.IsCompleted)) {
                $response = Receive-RelayClientResponse -Client $Client -ExpectedId $id
                if ($null -ne $response -and -not $response.PSObject.Properties['Invalid']) {
                    return $response
                }
                return New-RelayClientFailure -Id $id -Category 'SidecarLifecycle' `
                    -Message 'Relay script host exited unexpectedly.'
            }
            [Threading.Thread]::Sleep(10)
        }

        Stop-RelayScriptClient -Client $Client -TimeoutMilliseconds 250
        return New-RelayClientFailure -Id $id -Category 'Timeout' `
            -Message 'Relay script host request timed out.'
    }
    finally {
        $apiKey = $null
        $accessToken = $null
        $userId = $null
        $command = $null
        $json = $null
        $line = $null
        if ($gateTaken) {
            $null = $Client.Gate.Release()
        }
    }
}

function Stop-RelayScriptClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Client,
        [ValidateRange(1, 60000)][int]$TimeoutMilliseconds = 2000
    )
    if ($null -eq $Client) {
        return
    }
    $lockTaken = $false
    try {
        [Threading.Monitor]::Enter($Client.StopLock, [ref]$lockTaken)
        if ($Client.Disposed) {
            return
        }
        $Client.Disposed = $true
        $watch = [Diagnostics.Stopwatch]::StartNew()
        try { $Client.Input.Close() } catch {}
        $hasExited = $true
        try { $hasExited = $Client.Process.HasExited } catch { $hasExited = $true }
        if (-not $hasExited) {
            $remaining = [Math]::Max(0, $TimeoutMilliseconds - [int]$watch.ElapsedMilliseconds)
            if ($remaining -gt 0) {
                try { $hasExited = $Client.Process.WaitForExit($remaining) } catch { $hasExited = $false }
            }
        }
        if (-not $hasExited) {
            try { $Client.Process.Kill($true) } catch {}
            $remaining = [Math]::Max(0, $TimeoutMilliseconds - [int]$watch.ElapsedMilliseconds)
            if ($remaining -gt 0) {
                try { $null = $Client.Process.WaitForExit($remaining) } catch {}
            }
        }
        try { $Client.Input.Dispose() } catch {}
        try { $Client.Output.Dispose() } catch {}
        try { $Client.Error.Dispose() } catch {}
        try { $Client.Process.Dispose() } catch {}
    }
    finally {
        if ($lockTaken) {
            [Threading.Monitor]::Exit($Client.StopLock)
        }
    }
}
