$monitorRegistryKey = 'CodexQuotaMonitor.SingleInstance.OwnedPrefixes.v2'
$monitorRegistryLock = [string]::Intern("$monitorRegistryKey.Lock")
[Threading.Monitor]::Enter($monitorRegistryLock)
try {
    $monitorRegistry = [AppDomain]::CurrentDomain.GetData($monitorRegistryKey)
    if ($monitorRegistry -isnot [Collections.Concurrent.ConcurrentDictionary[string, object]]) {
        $monitorRegistry =
            [Collections.Concurrent.ConcurrentDictionary[string, object]]::new([StringComparer]::Ordinal)
        [AppDomain]::CurrentDomain.SetData($monitorRegistryKey, $monitorRegistry)
    }
    $script:MonitorOwnedInstancePrefixes = $monitorRegistry

    # Upgrade records produced by the earlier v2 implementation without
    # retaining their mutex handles strongly after this script is reloaded.
    foreach ($entry in $monitorRegistry.GetEnumerator()) {
        $record = $entry.Value
        if (
            $null -ne $record -and
            $null -eq $record.PSObject.Properties['MutexReference'] -and
            $null -ne $record.PSObject.Properties['Mutex']
        ) {
            $strongMutex = $record.PSObject.Properties['Mutex'].Value
            $monitorRegistry[$entry.Key] = [pscustomobject]@{
                OwnerToken = $record.PSObject.Properties['OwnerToken'].Value
                OwnerThreadId = $record.PSObject.Properties['OwnerThreadId'].Value
                OwnerThread = $record.PSObject.Properties['OwnerThread'].Value
                MutexReference = [WeakReference]::new($strongMutex)
            }
        }
    }
    $strongMutex = $null
    $record = $null
    $entry = $null
}
finally {
    [Threading.Monitor]::Exit($monitorRegistryLock)
}

function Test-MonitorOwnerRecordIsCurrentThreadLive {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Record
    )

    if ($null -eq $Record) {
        return $false
    }

    $ownerThread = $Record.PSObject.Properties['OwnerThread'].Value
    $mutexReference = $Record.PSObject.Properties['MutexReference'].Value
    if ($mutexReference -isnot [WeakReference]) {
        return $false
    }
    $mutex = $mutexReference.Target
    if (
        $null -eq $ownerThread -or
        $null -eq $mutex -or
        -not [object]::ReferenceEquals($ownerThread, [Threading.Thread]::CurrentThread) -or
        -not $ownerThread.IsAlive
    ) {
        return $false
    }

    try {
        return -not $mutex.SafeWaitHandle.IsClosed -and -not $mutex.SafeWaitHandle.IsInvalid
    }
    catch [ObjectDisposedException] {
        return $false
    }
}

function Set-MonitorOwnerRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prefix,

        [Parameter(Mandatory)]
        [guid]$OwnerToken,

        [Parameter(Mandatory)]
        [Threading.Mutex]$Mutex
    )

    $record = [pscustomobject]@{
        OwnerToken = $OwnerToken
        OwnerThreadId = [Environment]::CurrentManagedThreadId
        OwnerThread = [Threading.Thread]::CurrentThread
        MutexReference = [WeakReference]::new($Mutex)
    }

    $previous = $null
    [Threading.Monitor]::Enter($monitorRegistryLock)
    try {
        $null = $script:MonitorOwnedInstancePrefixes.TryGetValue($Prefix, [ref]$previous)
        $script:MonitorOwnedInstancePrefixes[$Prefix] = $record
    }
    finally {
        [Threading.Monitor]::Exit($monitorRegistryLock)
    }

    if (
        $null -ne $previous -and
        $previous.PSObject.Properties['OwnerToken'].Value -ne $OwnerToken
    ) {
        $previousReference = $previous.PSObject.Properties['MutexReference'].Value
        $previousMutex = if ($previousReference -is [WeakReference]) {
            $previousReference.Target
        }
        else {
            $previous.PSObject.Properties['Mutex'].Value
        }
        if ($null -ne $previousMutex -and -not [object]::ReferenceEquals($previousMutex, $Mutex)) {
            try {
                $previousMutex.Dispose()
            }
            catch [ObjectDisposedException] {
            }
        }
    }

    return $record
}

function Remove-MonitorOwnerRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prefix,

        [Parameter(Mandatory)]
        [guid]$OwnerToken
    )

    [Threading.Monitor]::Enter($monitorRegistryLock)
    try {
        $current = $null
        if (-not $script:MonitorOwnedInstancePrefixes.TryGetValue($Prefix, [ref]$current)) {
            return $false
        }
        if ($current.PSObject.Properties['OwnerToken'].Value -ne $OwnerToken) {
            return $false
        }

        $removed = $null
        return $script:MonitorOwnedInstancePrefixes.TryRemove($Prefix, [ref]$removed)
    }
    finally {
        [Threading.Monitor]::Exit($monitorRegistryLock)
    }
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
    $ownerToken = [guid]::Empty
    $ownerRecord = $null
    try {
        $mutexResult = New-MonitorInstanceMutex -Name $Prefix -CompatibilityMode:$CompatibilityMode
        $mutex = $mutexResult.Handle
        $createdNew = [bool]$mutexResult.CreatedNew
        $ownsMutex = $createdNew

        # createdNew is authoritative during normal startup. WaitOne is used only
        # to recover an unowned or abandoned object, never for this thread's live owner.
        $existingRecord = $null
        $null = $script:MonitorOwnedInstancePrefixes.TryGetValue($Prefix, [ref]$existingRecord)
        $isCurrentThreadReentry = Test-MonitorOwnerRecordIsCurrentThreadLive -Record $existingRecord
        if (-not $createdNew -and -not $isCurrentThreadReentry) {
            try {
                $ownsMutex = $mutex.WaitOne(0)
            }
            catch [Threading.AbandonedMutexException] {
                $ownsMutex = $true
            }
        }

        if ($ownsMutex) {
            $ownerToken = [guid]::NewGuid()
            $ownerRecord = Set-MonitorOwnerRecord -Prefix $Prefix -OwnerToken $ownerToken -Mutex $mutex
            $registered = $true
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
                OwnerThreadId = $null
                OwnerToken = $null
                OwnerThread = $null
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
            OwnerThreadId = [int]$ownerRecord.OwnerThreadId
            OwnerToken = [guid]$ownerRecord.OwnerToken
            OwnerThread = $ownerRecord.OwnerThread
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
        if ($ownsMutex -and $null -ne $mutex) {
            try {
                $mutex.ReleaseMutex()
            }
            catch [Threading.SynchronizationLockException] {
            }
        }
        if ($registered) {
            $null = Remove-MonitorOwnerRecord -Prefix $Prefix -OwnerToken $ownerToken
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

    $ownsMutex =
        $null -ne $Instance.PSObject.Properties['OwnsMutex'] -and
        [bool]$Instance.OwnsMutex
    if ($ownsMutex) {
        $ownerThreadId = $Instance.PSObject.Properties['OwnerThreadId'].Value
        $ownerThread = $Instance.PSObject.Properties['OwnerThread'].Value
        if (
            $ownerThreadId -ne [Environment]::CurrentManagedThreadId -or
            $null -eq $ownerThread -or
            -not [object]::ReferenceEquals($ownerThread, [Threading.Thread]::CurrentThread)
        ) {
            throw [InvalidOperationException]::new(
                'A monitor instance must be closed by the thread that acquired its mutex.'
            )
        }

        if ($null -eq $Instance.PSObject.Properties['Mutex'] -or $null -eq $Instance.Mutex) {
            throw [InvalidOperationException]::new('The primary monitor instance has no mutex handle.')
        }
        $ownerToken = $Instance.PSObject.Properties['OwnerToken'].Value
        if ($ownerToken -isnot [guid] -or $ownerToken -eq [guid]::Empty) {
            throw [InvalidOperationException]::new('The primary monitor instance has no owner token.')
        }

        # Releasing first permits a replacement to acquire and publish its token.
        # Conditional cleanup below cannot remove that replacement record.
        $Instance.Mutex.ReleaseMutex()
        $Instance.OwnsMutex = $false

        $null = Remove-MonitorOwnerRecord -Prefix ([string]$Instance.Prefix) -OwnerToken $ownerToken
    }

    if ($null -ne $Instance.PSObject.Properties['ExitEvent'] -and $null -ne $Instance.ExitEvent) {
        $Instance.ExitEvent.Dispose()
    }
    if ($null -ne $Instance.PSObject.Properties['ActivateEvent'] -and $null -ne $Instance.ActivateEvent) {
        $Instance.ActivateEvent.Dispose()
    }
    if ($null -ne $Instance.PSObject.Properties['Mutex'] -and $null -ne $Instance.Mutex) {
        $Instance.Mutex.Dispose()
    }
    if ($null -ne $closedProperty) {
        $Instance.Closed = $true
    }
}
