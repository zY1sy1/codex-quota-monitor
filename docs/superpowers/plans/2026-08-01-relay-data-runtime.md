# Relay Data Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add encrypted multi-provider persistence, sidecar transport, per-provider scheduling/state, mixed-source presentation, and headless runtime composition while preserving official Codex quota behavior.

**Architecture:** PowerShell treats the Rust host as a request/response adapter and keeps all policy/state in deterministic pure functions. Provider definitions, last-good cache, scheduler state, and official App Server session state remain separate; the composition root merges only normalized presentation records and sanitized health fields.

**Tech Stack:** PowerShell 7.4+, Windows DPAPI, JSONL redirected process transport, Pester 5.7.1, existing atomic-file/mutex patterns, injected clocks and adapters.

---

## Task 1: Add monitor paths, encrypted provider definitions, and presets

**Files:**
- Modify: `companion/Private/Settings.ps1`
- Create: `companion/Private/RelayCredentials.ps1`
- Create: `companion/Private/RelayProviderStore.ps1`
- Create: `companion/Presets/relay-usage.json`
- Create: `tests/Unit/RelayCredentials.Tests.ps1`
- Create: `tests/Unit/RelayProviderStore.Tests.ps1`

- [ ] **Step 1: Write failing path and DPAPI boundary tests**

Add to the new tests:

```powershell
It 'adds canonical relay paths below data and app' {
    $paths = Get-MonitorPaths -LocalAppData (Join-Path $TestDrive 'Local') -Startup (Join-Path $TestDrive 'Startup')
    $paths.RelayProviders | Should -BeExactly (Join-Path $paths.Data 'relay-providers.json')
    $paths.RelayCache | Should -BeExactly (Join-Path $paths.Data 'relay-cache.json')
    $paths.RelayHost | Should -BeExactly (Join-Path $paths.App 'Bin\relay-quota-host.exe')
    $paths.RelayPresets | Should -BeExactly (Join-Path $paths.App 'Presets\relay-usage.json')
}

It 'round-trips Unicode with the injected current-user protector' {
    $protected = Protect-RelaySecret -PlainText '密钥-α' -ProtectBytes { param($b) ,([byte[]]($b | ForEach-Object { $_ -bxor 0x5A })) }
    Unprotect-RelaySecret -CipherText $protected -UnprotectBytes { param($b) ,([byte[]]($b | ForEach-Object { $_ -bxor 0x5A })) } | Should -BeExactly '密钥-α'
}
```

- [ ] **Step 2: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\RelayCredentials.Tests.ps1, .\tests\Unit\RelayProviderStore.Tests.ps1"
```

Expected: FAIL because relay paths and functions are missing.

- [ ] **Step 3: Extend `Get-MonitorPaths` and implement DPAPI**

Return four new absolute fields from `Get-MonitorPaths`. Implement:

```powershell
function Protect-RelaySecret {
    param([AllowEmptyString()][string]$PlainText, [scriptblock]$ProtectBytes = {
        param([byte[]]$Bytes)
        [Security.Cryptography.ProtectedData]::Protect($Bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    })
    if ([string]::IsNullOrEmpty($PlainText)) { return '' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    try { [Convert]::ToBase64String([byte[]](& $ProtectBytes $bytes)) }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Unprotect-RelaySecret {
    param([AllowEmptyString()][string]$CipherText, [scriptblock]$UnprotectBytes = {
        param([byte[]]$Bytes)
        [Security.Cryptography.ProtectedData]::Unprotect($Bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    })
    if ([string]::IsNullOrEmpty($CipherText)) { return '' }
    $cipher = [Convert]::FromBase64String($CipherText)
    $plain = [byte[]](& $UnprotectBytes $cipher)
    try { [Text.Encoding]::UTF8.GetString($plain) }
    finally { [Array]::Clear($plain, 0, $plain.Length) }
}
```

No secret function accepts or emits secure data through an exception message.

- [ ] **Step 4: Write failing provider canonicalization tests**

Test a schema-1 document with one provider and assert exact field order, GUID provider ID, `Enabled`, trimmed `BaseUrl`, template enum, script, timeout 2-30, interval 0-1440, destination fingerprint, and encrypted `Secrets` keys. Assert plaintext sentinels never appear in the saved JSON. Assert duplicate IDs, unknown fields, invalid URLs, and malformed cipher text quarantine the complete file as `.corrupt-<UTC>`.

- [ ] **Step 5: Implement the provider store and committed presets**

Use this canonical document:

```powershell
[ordered]@{
    SchemaVersion = 1
    Providers = [object[]]@(
        [ordered]@{
            Id = '3d07f147-5d2d-44e3-9184-cf70acc2b30c'
            Name = 'Wakaka'
            Enabled = $true
            BaseUrl = 'https://api.wkkapi.com'
            TemplateType = 'Wakaka'
            Script = '({request:{url:"{{baseUrl}}/v1/usage",method:"GET",headers:{Authorization:"Bearer {{apiKey}}"}},extractor:function(response){return response;}})'
            TimeoutSeconds = 10
            IntervalMinutes = 10
            TrustedDestination = $null
            Secrets = [ordered]@{ ApiKey = '<DPAPI base64>'; AccessToken = ''; UserId = '' }
        }
    )
}
```

Implement `Read-RelayProviderStore`, `Write-RelayProviderStore`, and `ConvertTo-CanonicalRelayProviderDocument` using the existing path-scoped mutex, same-directory unique temp file, UTF-8 without BOM, and quarantine conventions from `Settings.ps1`. The committed preset registry contains IDs `wakaka`, `general`, and `new-api`, exact endpoint paths, script strings, default timeout 10, and default interval 10; it contains no secret values.

- [ ] **Step 6: Run and commit provider persistence**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\RelayCredentials.Tests.ps1, .\tests\Unit\RelayProviderStore.Tests.ps1"
git add companion/Private/Settings.ps1 companion/Private/RelayCredentials.ps1 companion/Private/RelayProviderStore.ps1 companion/Presets/relay-usage.json tests/Unit/RelayCredentials.Tests.ps1 tests/Unit/RelayProviderStore.Tests.ps1
git commit -m "feat: persist encrypted relay providers"
```

Expected: tests pass and no plaintext sentinel is present under `$TestDrive`.

## Task 2: Persist only last-good cache and model provider states

**Files:**
- Create: `companion/Private/RelayCache.ps1`
- Create: `companion/Private/RelayState.ps1`
- Create: `tests/Unit/RelayCache.Tests.ps1`
- Create: `tests/Unit/RelayState.Tests.ps1`

- [ ] **Step 1: Write failing cache tests**

```powershell
It 'round-trips only normalized last-good fields' {
    $cache = [ordered]@{ SchemaVersion = 1; Providers = [object[]]@(
        [ordered]@{ ProviderId='wkk'; UpdatedAt='2026-08-01T08:00:00.0000000+00:00'; Results=[object[]]@(
            [ordered]@{ IsValid=$true; InvalidMessage=$null; Remaining=[double]18.42; Unit='USD'; PlanName=$null; Total=$null; Used=$null; Extra=$null }
        ) }
    ) }
    Write-RelayCache -Path $path -Cache $cache
    $json = [IO.File]::ReadAllText($path)
    $json | Should -Not -Match 'script|header|response|token|secret'
    (Read-RelayCache -Path $path).Providers[0].Results[0].Remaining | Should -Be 18.42
}
```

- [ ] **Step 2: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\RelayCache.Tests.ps1, .\tests\Unit\RelayState.Tests.ps1"
```

Expected: FAIL because cache/state functions are absent.

- [ ] **Step 3: Implement canonical cache persistence**

Implement `Read-RelayCache` and `Write-RelayCache` with schema 1, provider ID, ISO-8601 update time, and the eight normalized result fields only. Corrupt cache is quarantined and treated as empty. Cap providers at 100, results per provider at 32, and each string field at 4096 characters.

- [ ] **Step 4: Write the exact state-transition table tests**

Exercise:

```powershell
$state = New-RelayProviderState -ProviderId 'wkk' -Enabled $true -CachedResults $cached -CachedAt $cachedAt
$state.Status | Should -BeExactly 'Stale'
$state = Complete-RelayProviderSuccess -State $state -Results $zeroResult -Now $now
$state.Status | Should -BeExactly 'Live'
$state.Results[0].Remaining | Should -Be 0
$state = Complete-RelayProviderFailure -State $state -Category 'Network' -Now $later
$state.Status | Should -BeExactly 'Stale'
$state.Results[0].Remaining | Should -Be 0
```

Add table cases for `Starting`, `Live`, `Stale`, `AuthRequired`, `InvalidScript`, `Unavailable`, and `Disabled`. Authentication clears no last-good data but sets `AuthRequired`; if all normalized results have `isValid=false`, set `AuthRequired`, while a mixed valid/invalid result array remains `Live` and preserves per-row validity. Script/config errors set `InvalidScript`; disabling sets `Disabled` and suppresses scheduling.

- [ ] **Step 5: Implement immutable transition helpers**

Use one ordered state shape:

```powershell
[pscustomobject][ordered]@{
    ProviderId = 'wkk'
    Status = 'Starting'
    Results = [object[]]@()
    LastSuccessAt = $null
    LastAttemptAt = $null
    LastErrorCategory = $null
    NextDueAt = [DateTimeOffset]::MinValue
    ConsecutiveFailures = 0
    RetryAfterSeconds = $null
    InFlight = $false
}
```

Every transition returns a new object and never mutates the input. A failure never synthesizes numeric zero.

- [ ] **Step 6: Run and commit cache/state**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\RelayCache.Tests.ps1, .\tests\Unit\RelayState.Tests.ps1"
git add companion/Private/RelayCache.ps1 companion/Private/RelayState.ps1 tests/Unit/RelayCache.Tests.ps1 tests/Unit/RelayState.Tests.ps1
git commit -m "feat: retain relay last-good state"
```

Expected: all cache and state tests pass.

## Task 3: Add the long-lived sidecar JSONL client

**Files:**
- Create: `companion/Private/RelayScriptClient.ps1`
- Create: `tests/Fixtures/FakeRelayQuotaHost.ps1`
- Create: `tests/Integration/RelayScriptClient.Tests.ps1`

- [ ] **Step 1: Write failing process-transport tests**

Test that `Start-RelayScriptClient` uses `ProcessStartInfo.ArgumentList`, redirected UTF-8 stdin/stdout/stderr, `UseShellExecute = $false`, and no secrets in arguments or environment. Send two commands with distinct IDs; assert `Invoke-RelayScriptQuery` correlates responses, caps stderr records, times out, sanitizes process exit, and `Stop-RelayScriptClient` is bounded and idempotent.

- [ ] **Step 2: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\RelayScriptClient.Tests.ps1"
```

Expected: FAIL because the transport functions are absent.

- [ ] **Step 3: Implement the transport state**

Use:

```powershell
[pscustomobject][ordered]@{
    Process = $process
    Input = $process.StandardInput
    Output = $process.StandardOutput
    Error = $process.StandardError
    Gate = [Threading.SemaphoreSlim]::new(1, 1)
    Responses = [Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    Stderr = [Collections.Concurrent.ConcurrentQueue[string]]::new()
    Disposed = $false
}
```

`Invoke-RelayScriptQuery` accepts a canonical provider plus decrypted secrets, creates an ID, serializes compact JSON with depth 12, writes exactly one LF-terminated line under the gate, waits to the provider timeout plus 2 seconds, returns only the matching normalized response, and clears the plaintext secret variables in a `finally` block. The process is started once and restarted only after an observed exit.

- [ ] **Step 4: Implement the fake host fixture**

The fixture reads JSONL and supports deterministic modes through non-secret command fields: echo success, delayed success, malformed output, exit 17, and sanitized failure. It must never print the incoming `secrets` object.

- [ ] **Step 5: Run and commit the client**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\RelayScriptClient.Tests.ps1"
git add companion/Private/RelayScriptClient.ps1 tests/Fixtures/FakeRelayQuotaHost.ps1 tests/Integration/RelayScriptClient.Tests.ps1
git commit -m "feat: add relay host process transport"
```

Expected: process lifecycle, correlation, timeout, and redaction tests pass.

## Task 4: Schedule all enabled providers with concurrency two

**Files:**
- Create: `companion/Private/RelayScheduler.ps1`
- Create: `tests/Unit/RelayScheduler.Tests.ps1`

- [ ] **Step 1: Write failing deterministic scheduler tests**

```powershell
It 'starts at most two due providers and deduplicates manual refresh' {
    $scheduler = New-RelaySchedulerState -Providers $providers -Now $now -MaximumConcurrency 2
    $first = Get-RelaySchedulerActions -State $scheduler -Now $now -ManualRefresh
    @($first.Actions | Where-Object Kind -eq 'StartQuery').Count | Should -Be 2
    $second = Get-RelaySchedulerActions -State $first.State -Now $now -ManualRefresh
    @($second.Actions | Where-Object Kind -eq 'StartQuery').Count | Should -Be 0
}
```

Add table cases for interval 0, disabled, success interval, network exponential delays `1,2,5,10,30,60` minutes, valid `Retry-After`, authentication pause, script/config pause until edit/manual test, and provider-local failures that do not delay other providers.

Lock category mapping in the same table: HTTP 401/403 and all-invalid extractor results → `AuthRequired`; HTTP 429 → provider-local rate-limit backoff; DNS/connectivity/TLS/timeout/5xx/sidecar lifecycle → last-good `Stale` or no-data `Unavailable`; script/request/extractor/result validation → `InvalidScript`; destination trust required → no automatic request until configuration is trusted.

- [ ] **Step 2: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\RelayScheduler.Tests.ps1"
```

Expected: FAIL because the scheduler is absent.

- [ ] **Step 3: Implement pure scheduler actions**

`New-RelaySchedulerState`, `Get-RelaySchedulerActions`, and `Complete-RelaySchedulerAction` operate on injected `DateTimeOffset` values and return:

```powershell
[pscustomobject][ordered]@{
    State = $newState
    Actions = [object[]]@(
        [pscustomobject][ordered]@{ Kind='StartQuery'; ProviderId='wkk'; Reason='Due' }
    )
}
```

The scheduler contains no timers or process calls. The runtime tick executes actions and returns completions. Global in-flight count never exceeds two; the same provider cannot be in flight twice.

- [ ] **Step 4: Run and commit the scheduler**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\RelayScheduler.Tests.ps1"
git add companion/Private/RelayScheduler.ps1 tests/Unit/RelayScheduler.Tests.ps1
git commit -m "feat: schedule relay quota queries"
```

Expected: all deterministic timing and concurrency cases pass.

## Task 5: Normalize relay presentation and mixed-source focus

**Files:**
- Create: `companion/Private/RelayPresentation.ps1`
- Modify: `companion/Private/Presentation.ps1`
- Create: `tests/Unit/RelayPresentation.Tests.ps1`
- Modify: `tests/Unit/Presentation.Tests.ps1`

- [ ] **Step 1: Write failing relay-row tests**

Assert the exact row shape from the master plan. Cover USD, CNY, request count, `remaining/total`, `used/total`, explicit zero, stale timestamp, `planName`, bounded `extra`, and invalid provider state. Verify a percentage is clamped for display but `ValueText` preserves the underlying amount.

- [ ] **Step 2: Write failing mixed-source focus tests**

```powershell
$focus = Get-CompactFocusRow -Rows @($official80, $relay20, $wallet) -PinnedKey $null
$focus.Key | Should -BeExactly $relay20.Key
Get-CompactFocusRow -Rows @($official80, $wallet) -PinnedKey $wallet.Key | Select-Object -ExpandProperty Key | Should -BeExactly $wallet.Key
Get-CompactFocusRow -Rows @($wallet) -PinnedKey $null | Should -BeNullOrEmpty
```

Assert `Get-CombinedQuotaSeverity` uses the worst valid percentage, stale adds a warning flag without gray, incompatible absolute units are never ranked, and `Get-CombinedTrayTooltip` includes the official focus plus at most two relay values within 63 text elements.

- [ ] **Step 3: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\RelayPresentation.Tests.ps1, .\tests\Unit\Presentation.Tests.ps1"
```

Expected: FAIL because relay presentation functions are missing.

- [ ] **Step 4: Implement relay rows and combined selectors**

Expose `ConvertTo-RelayPresentationRow`, `Merge-MonitorPresentationRows`, `Get-CompactFocusRow`, `Get-CombinedQuotaSeverity`, and `Get-CombinedTrayTooltip`. Official rows are adapted to the shared row shape without changing `ConvertTo-QuotaPresentationRow` callers. Sorting is deterministic: source group, provider order, result order, ordinal key.

- [ ] **Step 5: Run and commit presentation**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\RelayPresentation.Tests.ps1, .\tests\Unit\Presentation.Tests.ps1"
git add companion/Private/RelayPresentation.ps1 companion/Private/Presentation.ps1 tests/Unit/RelayPresentation.Tests.ps1 tests/Unit/Presentation.Tests.ps1
git commit -m "feat: combine official and relay presentation"
```

Expected: mixed-unit, focus, severity, tooltip, and existing official presentation tests pass.

## Task 6: Compose headless relay monitoring into the existing runtime

**Files:**
- Modify: `companion/CodexQuotaMonitor.psm1`
- Modify: `tests/Integration/MonitorRuntime.Tests.ps1`
- Create: `tests/Integration/RelayRuntime.Tests.ps1`

- [ ] **Step 1: Write failing state-isolation integration tests**

With function overrides, run the production tick loop against the fake App Server and fake relay host. Assert official rows remain live when every relay fails; one relay can be `Stale` while another is `Live`; manual refresh requests official plus all enabled relays; cache writes only after a relay success; and three consecutive sidecar startup failures set only relay host state `Unavailable`.

- [ ] **Step 2: Write the failing health schema-2 test**

Assert the health file retains all existing official fields and adds:

```powershell
$health.SchemaVersion | Should -Be 2
$health.RelayProviderCount | Should -Be 2
$health.RelayLiveCount | Should -Be 1
$health.RelayStaleCount | Should -Be 1
$health.RelayInvalidCount | Should -Be 0
$health.RelayHostState | Should -BeExactly 'Live'
$health.DisplayMode | Should -BeExactly 'Full'
$health.Theme | Should -BeExactly 'Dark'
```

Serialized health must not match `token|authorization|cookie|secret|password|api.?key`.

- [ ] **Step 3: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\RelayRuntime.Tests.ps1, .\tests\Integration\MonitorRuntime.Tests.ps1"
```

Expected: FAIL because relay composition and health fields are absent.

- [ ] **Step 4: Load the new private modules in dependency order**

Insert after `Settings.ps1` and before view modules:

```powershell
'RelayCredentials.ps1'
'RelayProviderStore.ps1'
'RelayCache.ps1'
'RelayState.ps1'
'RelayScriptClient.ps1'
'RelayScheduler.ps1'
'RelayPresentation.ps1'
```

Add injectable functions for provider/cache read/write, sidecar start/stop/query, scheduler action generation/completion, and combined presentation.

- [ ] **Step 5: Integrate relay ticks without coupling App Server reconnects**

Initialize providers/cache before desktop composition, initialize relay states, start the sidecar only when at least one provider is enabled, execute at most two relay actions per tick, write cache after successful results, and merge rows for presentation. Official reconnect paths must not start/stop or clear relay state; relay host crash paths must not call `Stop-AppServerProcess`.

- [ ] **Step 6: Extend sanitized health and cleanup**

Write schema 2 health with aggregate counts, sidecar state, display defaults, and unchanged official fields. On exit, stop the relay client independently, dispose provider secrets, then continue existing tray/window/App Server cleanup even if relay cleanup throws.

- [ ] **Step 7: Run runtime tests and the complete PowerShell suite**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\RelayRuntime.Tests.ps1, .\tests\Integration\MonitorRuntime.Tests.ps1"
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All -CI
```

Expected: new relay runtime tests pass and all preexisting tests remain green.

- [ ] **Step 8: Commit headless runtime composition**

```powershell
git add companion/CodexQuotaMonitor.psm1 tests/Integration/RelayRuntime.Tests.ps1 tests/Integration/MonitorRuntime.Tests.ps1
git commit -m "feat: compose relay quota runtime"
git status --short
```

Expected: clean status and a headless runtime ready for UI consumption.
