$monitorRegistryKey = 'CodexQuotaMonitor.SingleInstance.OwnedPrefixes.v1'
$monitorRegistryLock = [string]::Intern("$monitorRegistryKey.Lock")
[Threading.Monitor]::Enter($monitorRegistryLock)
try {
    $monitorRegistry = [AppDomain]::CurrentDomain.GetData($monitorRegistryKey)
    if ($monitorRegistry -isnot [Collections.Concurrent.ConcurrentDictionary[string, byte]]) {
        $monitorRegistry =
            [Collections.Concurrent.ConcurrentDictionary[string, byte]]::new([StringComparer]::Ordinal)
        [AppDomain]::CurrentDomain.SetData($monitorRegistryKey, $monitorRegistry)
    }
    $script:MonitorOwnedInstancePrefixes = $monitorRegistry
}
finally {
    [Threading.Monitor]::Exit($monitorRegistryLock)
}

function Assert-MonitorInstancePrefix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prefix
    )

    if ([string]::IsNullOrWhiteSpace($Prefix) -or -not $Prefix.StartsWith('Local\', [StringComparison]::Ordinal)) {
        throw [ArgumentException]::new('The monitor instance prefix must start with Local\.', 'Prefix')
    }

    if ($Prefix.EndsWith('\', [StringComparison]::Ordinal) -or $Prefix.IndexOf([char]0) -ge 0) {
        throw [ArgumentException]::new('The monitor instance prefix is not a valid named wait-handle name.', 'Prefix')
    }
}

function Get-MonitorWaitHandleAclSupport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Mutex', 'Event')]
        [string]$Kind
    )

    if (-not $IsWindows) {
        return $null
    }

    try {
        $assembly = [Reflection.Assembly]::Load('System.Threading.AccessControl')
        $prefix = if ($Kind -eq 'Mutex') { 'Mutex' } else { 'EventWaitHandle' }
        $aclType = $assembly.GetType("System.Threading.${prefix}Acl", $false)
        $securityType = $assembly.GetType("System.Security.AccessControl.${prefix}Security", $false)
        $ruleType = $assembly.GetType("System.Security.AccessControl.${prefix}AccessRule", $false)
        $rightsType = $assembly.GetType("System.Security.AccessControl.${prefix}Rights", $false)
        if ($null -eq $aclType -or $null -eq $securityType -or $null -eq $ruleType -or $null -eq $rightsType) {
            return $null
        }

        return [pscustomobject]@{
            AclType = $aclType
            SecurityType = $securityType
            RuleType = $ruleType
            RightsType = $rightsType
        }
    }
    catch {
        return $null
    }
}

function New-MonitorCurrentUserWaitHandleSecurity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Mutex', 'Event')]
        [string]$Kind
    )

    $support = Get-MonitorWaitHandleAclSupport -Kind $Kind
    if ($null -eq $support) {
        return $null
    }

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $sid = $identity.User
            if ($null -eq $sid) {
                return $null
            }

            $security = [Activator]::CreateInstance($support.SecurityType)
            $security.SetAccessRuleProtection($true, $false)
            $rights = [Enum]::Parse($support.RightsType, 'FullControl', $false)
            $accessRule = [Activator]::CreateInstance(
                $support.RuleType,
                @($sid, $rights, [Security.AccessControl.AccessControlType]::Allow)
            )
            $security.AddAccessRule($accessRule)

            return [pscustomobject]@{
                AclType = $support.AclType
                Security = $security
            }
        }
        finally {
            if ($null -ne $identity) {
                $identity.Dispose()
            }
        }
    }
    catch {
        return $null
    }
}

function New-MonitorInstanceMutex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [switch]$CompatibilityMode
    )

    if (-not $CompatibilityMode) {
        $acl = New-MonitorCurrentUserWaitHandleSecurity -Kind Mutex
        if ($null -ne $acl) {
            try {
                $arguments = [object[]]@($true, $Name, $false, $acl.Security)
                $create = $acl.AclType.GetMethods([Reflection.BindingFlags]'Public, Static') |
                    Where-Object { $_.Name -eq 'Create' -and $_.GetParameters().Count -eq 4 } |
                    Select-Object -First 1
                if ($null -ne $create) {
                    $mutex = [Threading.Mutex]$create.Invoke($null, $arguments)
                    return [pscustomobject]@{
                        Handle = $mutex
                        CreatedNew = [bool]$arguments[2]
                        UsedAcl = $true
                    }
                }
            }
            catch [Reflection.TargetInvocationException] {
                $inner = $_.Exception.InnerException
                if (
                    $inner -isnot [PlatformNotSupportedException] -and
                    $inner -isnot [NotSupportedException] -and
                    $inner -isnot [MissingMethodException] -and
                    $inner -isnot [TypeLoadException]
                ) {
                    if ($null -ne $inner) {
                        throw $inner
                    }
                    throw
                }
            }
        }
    }

    $createdNew = $false
    $mutex = [Threading.Mutex]::new($true, $Name, [ref]$createdNew)
    return [pscustomobject]@{
        Handle = $mutex
        CreatedNew = [bool]$createdNew
        UsedAcl = $false
    }
}

function New-MonitorInstanceEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [switch]$CompatibilityMode
    )

    if (-not $CompatibilityMode) {
        $acl = New-MonitorCurrentUserWaitHandleSecurity -Kind Event
        if ($null -ne $acl) {
            try {
                $arguments = [object[]]@(
                    $false,
                    [Threading.EventResetMode]::AutoReset,
                    $Name,
                    $false,
                    $acl.Security
                )
                $create = $acl.AclType.GetMethods([Reflection.BindingFlags]'Public, Static') |
                    Where-Object { $_.Name -eq 'Create' -and $_.GetParameters().Count -eq 5 } |
                    Select-Object -First 1
                if ($null -ne $create) {
                    $event = [Threading.EventWaitHandle]$create.Invoke($null, $arguments)
                    return [pscustomobject]@{
                        Handle = $event
                        CreatedNew = [bool]$arguments[3]
                        UsedAcl = $true
                    }
                }
            }
            catch [Reflection.TargetInvocationException] {
                $inner = $_.Exception.InnerException
                if (
                    $inner -isnot [PlatformNotSupportedException] -and
                    $inner -isnot [NotSupportedException] -and
                    $inner -isnot [MissingMethodException] -and
                    $inner -isnot [TypeLoadException]
                ) {
                    if ($null -ne $inner) {
                        throw $inner
                    }
                    throw
                }
            }
        }
    }

    $createdNew = $false
    $event = [Threading.EventWaitHandle]::new(
        $false,
        [Threading.EventResetMode]::AutoReset,
        $Name,
        [ref]$createdNew
    )
    return [pscustomobject]@{
        Handle = $event
        CreatedNew = [bool]$createdNew
        UsedAcl = $false
    }
}

function Open-MonitorInstanceEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [ValidateRange(1, 30000)]
        [int]$TimeoutMilliseconds = 2000
    )

    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $retry = [Threading.ManualResetEventSlim]::new($false)
    $lastError = $null
    try {
        do {
            try {
                return [Threading.EventWaitHandle]::OpenExisting($Name)
            }
            catch [Threading.WaitHandleCannotBeOpenedException] {
                $lastError = $_.Exception
            }

            $remaining = [int][Math]::Ceiling(($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds)
            if ($remaining -le 0) {
                break
            }
            $null = $retry.Wait([Math]::Min(20, $remaining))
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
    }
    finally {
        $retry.Dispose()
    }

    throw [TimeoutException]::new("Timed out opening monitor instance event '$Name'.", $lastError)
}

function Enter-MonitorInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prefix,

        [Alias('RequestedSignal')]
        [ValidateSet('Activate', 'Exit', 'None')]
        [string]$Signal = 'Activate',

        [ValidateRange(1, 30000)]
        [int]$EventOpenTimeoutMilliseconds = 2000,

        [Parameter(DontShow)]
        [switch]$CompatibilityMode
    )

    Assert-MonitorInstancePrefix -Prefix $Prefix

    $mutex = $null
    $activateEvent = $null
    $exitEvent = $null
    $ownsMutex = $false
    $registered = $false
    try {
        $mutexResult = New-MonitorInstanceMutex -Name $Prefix -CompatibilityMode:$CompatibilityMode
        $mutex = $mutexResult.Handle
        $createdNew = [bool]$mutexResult.CreatedNew
        $ownsMutex = $createdNew

        # createdNew is authoritative during normal startup. WaitOne is used only
        # to recover an unowned or abandoned object, never for a locally owned name.
        if (-not $createdNew -and -not $script:MonitorOwnedInstancePrefixes.ContainsKey($Prefix)) {
            try {
                $ownsMutex = $mutex.WaitOne(0)
            }
            catch [Threading.AbandonedMutexException] {
                $ownsMutex = $true
            }
        }

        if ($ownsMutex) {
            $registered = $script:MonitorOwnedInstancePrefixes.TryAdd($Prefix, [byte]0)
            if (-not $registered) {
                $mutex.ReleaseMutex()
                $ownsMutex = $false
            }
        }

        if (-not $ownsMutex) {
            if ($Signal -ne 'None') {
                $eventName = "$Prefix.$Signal"
                $signalEvent = $null
                try {
                    $signalEvent = Open-MonitorInstanceEvent `
                        -Name $eventName `
                        -TimeoutMilliseconds $EventOpenTimeoutMilliseconds
                    if (-not $signalEvent.Set()) {
                        throw [InvalidOperationException]::new("Could not signal monitor instance event '$eventName'.")
                    }
                }
                finally {
                    if ($null -ne $signalEvent) {
                        $signalEvent.Dispose()
                    }
                }
            }

            $mutex.Dispose()
            $mutex = $null
            return [pscustomobject]@{
                IsPrimary = $false
                Mutex = $null
                ActivateEvent = $null
                ExitEvent = $null
                Prefix = $Prefix
                OwnsMutex = $false
                Closed = $true
            }
        }

        $activateResult = New-MonitorInstanceEvent `
            -Name "$Prefix.Activate" `
            -CompatibilityMode:$CompatibilityMode
        $activateEvent = $activateResult.Handle
        if (-not $activateResult.CreatedNew) {
            $null = $activateEvent.Reset()
        }

        $exitResult = New-MonitorInstanceEvent `
            -Name "$Prefix.Exit" `
            -CompatibilityMode:$CompatibilityMode
        $exitEvent = $exitResult.Handle
        if (-not $exitResult.CreatedNew) {
            $null = $exitEvent.Reset()
        }

        return [pscustomobject]@{
            IsPrimary = $true
            Mutex = $mutex
            ActivateEvent = $activateEvent
            ExitEvent = $exitEvent
            Prefix = $Prefix
            OwnsMutex = $true
            Closed = $false
        }
    }
    catch {
        if ($null -ne $exitEvent) {
            $exitEvent.Dispose()
        }
        if ($null -ne $activateEvent) {
            $activateEvent.Dispose()
        }
        if ($registered) {
            $removed = [byte]0
            $null = $script:MonitorOwnedInstancePrefixes.TryRemove($Prefix, [ref]$removed)
        }
        if ($ownsMutex -and $null -ne $mutex) {
            try {
                $mutex.ReleaseMutex()
            }
            catch [Threading.SynchronizationLockException] {
            }
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
        throw
    }
}

function Close-MonitorInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Instance
    )

    $closedProperty = $Instance.PSObject.Properties['Closed']
    if ($null -ne $closedProperty -and [bool]$closedProperty.Value) {
        return
    }

    $releaseError = $null
    try {
        if ($null -ne $Instance.PSObject.Properties['ExitEvent'] -and $null -ne $Instance.ExitEvent) {
            $Instance.ExitEvent.Dispose()
        }
        if ($null -ne $Instance.PSObject.Properties['ActivateEvent'] -and $null -ne $Instance.ActivateEvent) {
            $Instance.ActivateEvent.Dispose()
        }
        if (
            $null -ne $Instance.PSObject.Properties['OwnsMutex'] -and
            [bool]$Instance.OwnsMutex -and
            $null -ne $Instance.PSObject.Properties['Mutex'] -and
            $null -ne $Instance.Mutex
        ) {
            try {
                $Instance.Mutex.ReleaseMutex()
            }
            catch {
                $releaseError = $_.Exception
            }
        }
    }
    finally {
        if ($null -ne $Instance.PSObject.Properties['Mutex'] -and $null -ne $Instance.Mutex) {
            $Instance.Mutex.Dispose()
        }
        if (
            $null -ne $Instance.PSObject.Properties['IsPrimary'] -and
            [bool]$Instance.IsPrimary -and
            $null -ne $Instance.PSObject.Properties['Prefix']
        ) {
            $removed = [byte]0
            $null = $script:MonitorOwnedInstancePrefixes.TryRemove([string]$Instance.Prefix, [ref]$removed)
        }
        if ($null -ne $closedProperty) {
            $Instance.Closed = $true
        }
    }

    if ($null -ne $releaseError) {
        throw $releaseError
    }
}
