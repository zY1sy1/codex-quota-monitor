BeforeAll {
    . "$PSScriptRoot\..\..\companion\Private\ObjectAccess.ps1"
    . "$PSScriptRoot\..\..\companion\Private\QuotaNormalization.ps1"
    . "$PSScriptRoot\..\..\companion\Private\JsonRpc.ps1"
    . "$PSScriptRoot\..\..\companion\Private\SessionController.ps1"

    function Complete-TestInitialization {
        param(
            [Parameter(Mandatory)]
            [object]$State,

            [datetimeoffset]$Now = [datetimeoffset]'2026-07-13T12:00:00Z'
        )

        $initializeRequest = @(Start-SessionHandshake -State $State -Now $Now)[0]
        $actions = @(
            Update-SessionFromMessage -State $State -Message ([pscustomobject]@{
                id = $initializeRequest.id
                result = [ordered]@{}
            }) -Now $Now.AddSeconds(1)
        )

        [pscustomobject]@{
            InitializeRequest = $initializeRequest
            Actions = $actions
            AccountRequest = @($actions | Where-Object method -EQ 'account/read')[0]
            QuotaRequest = @($actions | Where-Object method -EQ 'account/rateLimits/read')[0]
        }
    }

    function New-TestRateLimitResult {
        param(
            [AllowNull()]
            [string]$PlanType = $null,

            [double]$UsedPercent = 25
        )

        $result = [ordered]@{
            rateLimitsByLimitId = [ordered]@{
                codex = [ordered]@{
                    limitId = 'codex'
                    limitName = 'Codex'
                    primary = [ordered]@{
                        usedPercent = $UsedPercent
                        windowDurationMins = 300
                        resetsAt = 1783933200
                        rateLimitReachedType = 'none'
                    }
                }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($PlanType)) {
            $result['planType'] = $PlanType
        }

        [pscustomobject]$result
    }

    function New-MalformedTestResponse {
        param(
            [Parameter(Mandatory)]
            [int]$Id,

            [Parameter(Mandatory)]
            [ValidateSet('Missing', 'Null', 'Scalar', 'NullError', 'EmptyObject')]
            [string]$Shape
        )

        switch ($Shape) {
            'Missing' { [pscustomobject][ordered]@{ id = $Id } }
            'Null' { [pscustomobject][ordered]@{ id = $Id; result = $null } }
            'Scalar' { [pscustomobject][ordered]@{ id = $Id; result = 'not-a-result-object' } }
            'NullError' { [pscustomobject][ordered]@{ id = $Id; error = $null } }
            'EmptyObject' { [pscustomobject][ordered]@{ id = $Id; result = [ordered]@{} } }
        }
    }
}

Describe 'New-SessionState' {
    It 'creates the mutable initial session record' {
        $state = New-SessionState

        foreach ($name in @(
            'NextId',
            'Pending',
            'Initialized',
            'QuotaReadPending',
            'Status',
            'PlanType',
            'QuotaWindows',
            'LastSuccessAt',
            'LastError',
            'ReconnectAttempt',
            'QuotaEligible',
            'QuotaRefreshQueued',
            'AccountRefreshQueued'
        )) {
            $state.PSObject.Properties.Name | Should -Contain $name
        }
        $state.NextId | Should -Be 1
        $state.Pending | Should -BeOfType ([System.Collections.IDictionary])
        $state.Pending.Count | Should -Be 0
        $state.Initialized | Should -BeFalse
        $state.QuotaReadPending | Should -BeFalse
        $state.Status | Should -BeExactly 'Starting'
        $state.PlanType | Should -BeNullOrEmpty
        @($state.QuotaWindows).Count | Should -Be 0
        $state.LastSuccessAt | Should -BeNullOrEmpty
        $state.LastError | Should -BeNullOrEmpty
        $state.ReconnectAttempt | Should -Be 0
        $state.QuotaEligible | Should -BeNullOrEmpty
        $state.QuotaRefreshQueued | Should -BeFalse
        $state.AccountRefreshQueued | Should -BeFalse

        $state.NextId = 41
        $state.NextId | Should -Be 41
    }
}

Describe 'session handshake' {
    It 'starts with exactly one initialize request and records it pending' {
        $state = New-SessionState
        $sentAt = [datetimeoffset]'2026-07-13T01:02:03Z'

        $actions = @(Start-SessionHandshake -State $state -Now $sentAt)

        $actions.Count | Should -Be 1
        $actions[0].method | Should -BeExactly 'initialize'
        $actions[0].id | Should -Be 1
        $actions[0].params.clientInfo.name | Should -BeExactly 'codex_quota_monitor'
        $actions[0].params.clientInfo.title | Should -BeExactly 'Codex Quota Monitor'
        $actions[0].params.clientInfo.version | Should -BeExactly '0.1.2'
        ($actions[0].params.clientInfo.Keys -join ',') | Should -BeExactly 'name,title,version'
        $actions[0].PSObject.Properties.Name | Should -Not -Contain 'jsonrpc'
        $state.NextId | Should -Be 2
        $state.Pending.Contains($actions[0].id) | Should -BeTrue
        $state.Pending[$actions[0].id].Method | Should -BeExactly 'initialize'
        $state.Pending[$actions[0].id].SentAt | Should -Be $sentAt
    }

    It 'does not start a second initialize while one is pending' {
        $state = New-SessionState
        $first = @(Start-SessionHandshake -State $state)

        $second = @(Start-SessionHandshake -State $state)

        $first.Count | Should -Be 1
        $second.Count | Should -Be 0
        $state.Pending.Count | Should -Be 1
    }

    It 'emits the exact ordered follow-up actions after initialize succeeds' {
        $state = New-SessionState
        $init = @(Start-SessionHandshake -State $state)[0]

        $actions = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                id = $init.id
                result = [ordered]@{}
            })
        )

        $actions.Count | Should -Be 3
        @($actions.method) | Should -Be @('initialized', 'account/read', 'account/rateLimits/read')
        $actions[0].PSObject.Properties.Name | Should -Not -Contain 'id'
        $actions[0].PSObject.Properties.Name | Should -Not -Contain 'params'
        $actions[1].PSObject.Properties.Name | Should -Contain 'id'
        $actions[1].PSObject.Properties.Name | Should -Contain 'params'
        $actions[1].params | Should -BeOfType ([System.Collections.IDictionary])
        $actions[1].params.Count | Should -Be 0
        $actions[2].PSObject.Properties.Name | Should -Contain 'id'
        $actions[2].PSObject.Properties.Name | Should -Not -Contain 'params'
        $state.Initialized | Should -BeTrue
        $state.QuotaReadPending | Should -BeTrue
        $state.Pending.Contains($init.id) | Should -BeFalse
        $state.Pending.Contains($actions[1].id) | Should -BeTrue
        $state.Pending.Contains($actions[2].id) | Should -BeTrue
        $state.Pending[$actions[1].id].Method | Should -BeExactly 'account/read'
        $state.Pending[$actions[2].id].Method | Should -BeExactly 'account/rateLimits/read'
    }

    It 'ignores an unknown response id' {
        $state = New-SessionState
        $init = @(Start-SessionHandshake -State $state)[0]

        $actions = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{ id = 999; result = [ordered]@{} }))

        $actions.Count | Should -Be 0
        $state.Initialized | Should -BeFalse
        $state.Pending.Contains($init.id) | Should -BeTrue
    }

    It 'never treats a message with a method as a response' {
        $state = New-SessionState
        $init = @(Start-SessionHandshake -State $state)[0]

        $actions = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                method = 'server/notice'
                id = $init.id
                params = [ordered]@{}
            })
        )

        $actions.Count | Should -Be 0
        $state.Initialized | Should -BeFalse
        $state.Pending.Contains($init.id) | Should -BeTrue
    }

    It 'handles an initialize error without exposing the raw server message' {
        $state = New-SessionState
        $init = @(Start-SessionHandshake -State $state)[0]

        $actions = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                id = $init.id
                error = [ordered]@{ code = -32000; message = 'secret-token initialize failure' }
            })
        )

        $actions.Count | Should -Be 0
        $state.Initialized | Should -BeFalse
        $state.Pending.Contains($init.id) | Should -BeFalse
        $state.Status | Should -BeExactly 'Error'
        $state.LastError | Should -Not -Match 'secret-token'
    }

    It 'rejects a malformed matched initialize response' -ForEach @(
        @{ Shape = 'Missing' },
        @{ Shape = 'Null' },
        @{ Shape = 'Scalar' },
        @{ Shape = 'NullError' }
    ) {
        $state = New-SessionState
        $init = @(Start-SessionHandshake -State $state)[0]
        $message = New-MalformedTestResponse -Id $init.id -Shape $Shape

        $actions = @(Update-SessionFromMessage -State $state -Message $message)

        $actions.Count | Should -Be 0
        $state.Initialized | Should -BeFalse
        $state.Pending.Contains($init.id) | Should -BeFalse
        $state.Status | Should -BeExactly 'Error'
        $state.LastError | Should -BeExactly 'Codex App Server initialization failed.'
    }
}

Describe 'account state' {
    It 'keeps quota polling active for a ChatGPT account and stores its plan' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state

        $actions = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                id = $context.AccountRequest.id
                result = [ordered]@{
                    account = [ordered]@{ type = 'chatgpt'; planType = 'plus' }
                    requiresOpenaiAuth = $true
                }
            })
        )

        $actions.Count | Should -Be 0
        $state.PlanType | Should -BeExactly 'plus'
        $state.Status | Should -Not -BeIn @('AuthRequired', 'Unavailable')
        $state.QuotaReadPending | Should -BeTrue
        $state.QuotaEligible | Should -BeTrue
        $state.Pending.Contains($context.QuotaRequest.id) | Should -BeTrue
    }

    It 'marks API-key auth as separate from ChatGPT quota and invalidates a pending quota read' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $state.PlanType = 'stale-plan'
        $state.QuotaWindows = @([pscustomobject]@{ Key = 'stale' })

        $null = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                id = $context.AccountRequest.id
                result = [ordered]@{
                    account = [ordered]@{ type = 'apiKey'; apiKey = 'sk-secret-value' }
                    requiresOpenaiAuth = $true
                }
            })
        )

        $state.Status | Should -BeExactly 'AuthRequired'
        $state.PlanType | Should -BeNullOrEmpty
        @($state.QuotaWindows).Count | Should -Be 0
        $state.QuotaReadPending | Should -BeFalse
        $state.QuotaEligible | Should -BeFalse
        $state.QuotaRefreshQueued | Should -BeFalse
        $state.Pending.Contains($context.QuotaRequest.id) | Should -BeFalse
        $state.LastError | Should -Match 'API billing'
        $state.LastError | Should -Match 'ChatGPT quota'
        $state.LastError | Should -Not -Match 'sk-secret-value'

        $null = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                id = $context.QuotaRequest.id
                result = New-TestRateLimitResult -PlanType 'pro' -UsedPercent 80
            })
        )
        $state.Status | Should -BeExactly 'AuthRequired'
        @($state.QuotaWindows).Count | Should -Be 0

        $notificationActions = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{}
        }))
        $notificationActions.Count | Should -Be 0
        $state.QuotaReadPending | Should -BeFalse
    }

    It 'classifies unsupported or unauthenticated account states and clears stale quota' -ForEach @(
        @{ Account = $null; RequiresOpenaiAuth = $true; ExpectedStatus = 'AuthRequired' },
        @{ Account = $null; RequiresOpenaiAuth = $false; ExpectedStatus = 'Unavailable' },
        @{ Account = [ordered]@{ type = 'amazonBedrock' }; RequiresOpenaiAuth = $false; ExpectedStatus = 'Unavailable' }
    ) {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $state.PlanType = 'stale-plan'
        $state.QuotaWindows = @([pscustomobject]@{ Key = 'stale' })

        $null = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                id = $context.AccountRequest.id
                result = [ordered]@{
                    account = $Account
                    requiresOpenaiAuth = $RequiresOpenaiAuth
                }
            })
        )

        $state.Status | Should -BeExactly $ExpectedStatus
        $state.PlanType | Should -BeNullOrEmpty
        @($state.QuotaWindows).Count | Should -Be 0
        $state.QuotaReadPending | Should -BeFalse
        $state.QuotaEligible | Should -BeFalse
        $state.QuotaRefreshQueued | Should -BeFalse
        $state.Pending.Contains($context.QuotaRequest.id) | Should -BeFalse

        $notificationActions = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{}
        }))
        $notificationActions.Count | Should -Be 0
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.QuotaRequest.id
            result = New-TestRateLimitResult -PlanType 'stale-plan' -UsedPercent 99
        }))
        $state.Status | Should -BeExactly $ExpectedStatus
        @($state.QuotaWindows).Count | Should -Be 0
    }

    It 'coalesces account updates, invalidates the account snapshot, and clears quota after auth changes' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.AccountRequest.id
            result = [ordered]@{ account = [ordered]@{ type = 'chatgpt'; planType = 'plus' }; requiresOpenaiAuth = $true }
        }))
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.QuotaRequest.id
            result = New-TestRateLimitResult -PlanType 'plus'
        }))

        $first = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                method = 'account/updated'
                params = [ordered]@{ authMode = 'apikey'; planType = 'payload-must-not-be-used' }
            })
        )
        $second = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                method = 'account/updated'
                params = [ordered]@{ authMode = 'apikey'; planType = 'payload-must-not-be-used' }
            })
        )

        $first.Count | Should -Be 1
        $first[0].method | Should -BeExactly 'account/read'
        $first[0].params.Count | Should -Be 0
        $second.Count | Should -Be 0
        $state.PlanType | Should -BeNullOrEmpty
        $state.QuotaEligible | Should -BeNullOrEmpty
        @($state.QuotaWindows).Count | Should -Be 1

        $followUp = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                id = $first[0].id
                result = [ordered]@{ account = $null; requiresOpenaiAuth = $false }
            })
        )
        $followUp.Count | Should -Be 1
        $followUp[0].method | Should -BeExactly 'account/read'
        $null = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                id = $followUp[0].id
                result = [ordered]@{ account = $null; requiresOpenaiAuth = $false }
            })
        )
        $state.Status | Should -BeExactly 'Unavailable'
        @($state.QuotaWindows).Count | Should -Be 0
    }

    It 'restarts quota polling when a fresh account read becomes ChatGPT-backed' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.AccountRequest.id
            result = [ordered]@{ account = [ordered]@{ type = 'apiKey' }; requiresOpenaiAuth = $true }
        }))
        $accountRead = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                method = 'account/updated'
                params = [ordered]@{ authMode = 'chatgpt' }
            })
        )[0]

        $actions = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                id = $accountRead.id
                result = [ordered]@{
                    account = [ordered]@{ type = 'chatgpt'; planType = 'pro' }
                    requiresOpenaiAuth = $true
                }
            })
        )

        $actions.Count | Should -Be 1
        $actions[0].method | Should -BeExactly 'account/rateLimits/read'
        $actions[0].PSObject.Properties.Name | Should -Not -Contain 'params'
        $state.QuotaReadPending | Should -BeTrue
        $state.PlanType | Should -BeExactly 'pro'
        $state.QuotaEligible | Should -BeTrue
    }

    It 'discards a dirty account response and emits one coalesced refresh' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.AccountRequest.id
            result = [ordered]@{ account = [ordered]@{ type = 'chatgpt'; planType = 'plus' }; requiresOpenaiAuth = $true }
        }))
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.QuotaRequest.id
            result = New-TestRateLimitResult -PlanType 'plus' -UsedPercent 10
        }))
        $accountRead = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/updated'; params = [ordered]@{ authMode = 'chatgpt' }
        }))[0]

        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/updated'; params = [ordered]@{ authMode = 'apikey' }
        }))
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/updated'; params = [ordered]@{ authMode = 'apikey' }
        }))
        $state.AccountRefreshQueued | Should -BeTrue

        $actions = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $accountRead.id
            result = [ordered]@{ account = [ordered]@{ type = 'apiKey' }; requiresOpenaiAuth = $true }
        }))

        $actions.Count | Should -Be 1
        $actions[0].method | Should -BeExactly 'account/read'
        $actions[0].params.Count | Should -Be 0
        $actions[0].id | Should -Not -Be $accountRead.id
        $state.AccountRefreshQueued | Should -BeFalse
        $state.PlanType | Should -BeNullOrEmpty
        $state.QuotaEligible | Should -BeNullOrEmpty
        $state.Status | Should -BeExactly 'Live'
        @($state.QuotaWindows).Count | Should -Be 1
        $state.QuotaWindows[0].UsedPercent | Should -Be 10
    }

    It 'invalidates a pre-account-change quota read when <Ordering>' -ForEach @(
        @{ Ordering = 'the stale quota response arrives first'; FreshAccountFirst = $false },
        @{ Ordering = 'the fresh account response arrives first'; FreshAccountFirst = $true }
    ) {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.AccountRequest.id
            result = [ordered]@{
                account = [ordered]@{ type = 'chatgpt'; planType = 'plus' }
                requiresOpenaiAuth = $true
            }
        }))
        $oldSuccessAt = [datetimeoffset]'2026-07-13T15:00:00Z'
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.QuotaRequest.id
            result = New-TestRateLimitResult -PlanType 'plus' -UsedPercent 10
        }) -Now $oldSuccessAt)
        $oldQuotaRead = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{}
        }))[0]
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{}
        }))
        $state.QuotaRefreshQueued | Should -BeTrue

        $accountRead = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/updated'; params = [ordered]@{}
        }))

        $accountRead.Count | Should -Be 1
        $accountRead[0].method | Should -BeExactly 'account/read'
        $state.Pending.Contains($oldQuotaRead.id) | Should -BeFalse
        @( $state.Pending.Values | Where-Object Method -EQ 'account/rateLimits/read' ).Count | Should -Be 0
        $state.QuotaReadPending | Should -BeFalse
        $state.QuotaRefreshQueued | Should -BeFalse
        $state.QuotaEligible | Should -BeNullOrEmpty
        $state.PlanType | Should -BeNullOrEmpty
        $state.QuotaWindows[0].UsedPercent | Should -Be 10
        $state.LastSuccessAt | Should -Be $oldSuccessAt

        $staleQuotaResponse = [pscustomobject]@{
            id = $oldQuotaRead.id
            result = New-TestRateLimitResult -PlanType 'stale-plan' -UsedPercent 99
        }
        $freshAccountResponse = [pscustomobject]@{
            id = $accountRead[0].id
            result = [ordered]@{
                account = [ordered]@{ type = 'chatgpt'; planType = 'pro' }
                requiresOpenaiAuth = $true
            }
        }

        if ($FreshAccountFirst) {
            $freshAccountActions = @(Update-SessionFromMessage -State $state -Message $freshAccountResponse)
            $staleQuotaActions = @(Update-SessionFromMessage -State $state -Message $staleQuotaResponse)
        }
        else {
            $staleQuotaActions = @(Update-SessionFromMessage -State $state -Message $staleQuotaResponse)
            $state.PlanType | Should -BeNullOrEmpty
            $state.QuotaWindows[0].UsedPercent | Should -Be 10
            $state.LastSuccessAt | Should -Be $oldSuccessAt
            $freshAccountActions = @(Update-SessionFromMessage -State $state -Message $freshAccountResponse)
        }

        $staleQuotaActions.Count | Should -Be 0
        $freshAccountActions.Count | Should -Be 1
        $freshAccountActions[0].method | Should -BeExactly 'account/rateLimits/read'
        $freshAccountActions[0].id | Should -Not -Be $oldQuotaRead.id
        @( $state.Pending.Values | Where-Object Method -EQ 'account/rateLimits/read' ).Count | Should -Be 1
        $state.Pending.Contains($freshAccountActions[0].id) | Should -BeTrue
        $state.PlanType | Should -BeExactly 'pro'
        $state.QuotaWindows[0].UsedPercent | Should -Be 10
        $state.LastSuccessAt | Should -Be $oldSuccessAt

        $newSuccessAt = $oldSuccessAt.AddMinutes(5)
        $newQuotaActions = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $freshAccountActions[0].id
            result = New-TestRateLimitResult -PlanType 'pro' -UsedPercent 25
        }) -Now $newSuccessAt)

        $newQuotaActions.Count | Should -Be 0
        $state.Status | Should -BeExactly 'Live'
        $state.PlanType | Should -BeExactly 'pro'
        $state.QuotaWindows[0].UsedPercent | Should -Be 25
        $state.LastSuccessAt | Should -Be $newSuccessAt
    }

    It 'keeps a fresh unsupported account unsupported after invalidating an old quota read' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.AccountRequest.id
            result = [ordered]@{
                account = [ordered]@{ type = 'chatgpt'; planType = 'plus' }
                requiresOpenaiAuth = $true
            }
        }))
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.QuotaRequest.id
            result = New-TestRateLimitResult -PlanType 'plus' -UsedPercent 10
        }))
        $oldQuotaRead = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{}
        }))[0]
        $accountRead = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/updated'; params = [ordered]@{}
        }))[0]

        $freshAccountActions = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $accountRead.id
            result = [ordered]@{
                account = [ordered]@{ type = 'apiKey' }
                requiresOpenaiAuth = $true
            }
        }))
        $staleQuotaActions = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $oldQuotaRead.id
            result = New-TestRateLimitResult -PlanType 'stale-plan' -UsedPercent 99
        }))

        $freshAccountActions.Count | Should -Be 0
        $staleQuotaActions.Count | Should -Be 0
        $state.Status | Should -BeExactly 'AuthRequired'
        $state.QuotaEligible | Should -BeFalse
        $state.QuotaReadPending | Should -BeFalse
        $state.QuotaRefreshQueued | Should -BeFalse
        @( $state.Pending.Values | Where-Object Method -EQ 'account/rateLimits/read' ).Count | Should -Be 0
        $state.PlanType | Should -BeNullOrEmpty
        @($state.QuotaWindows).Count | Should -Be 0
    }

    It 'rejects a malformed matched account response' -ForEach @(
        @{ Shape = 'Missing' },
        @{ Shape = 'Null' },
        @{ Shape = 'Scalar' },
        @{ Shape = 'NullError' },
        @{ Shape = 'EmptyObject' }
    ) {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $message = New-MalformedTestResponse -Id $context.AccountRequest.id -Shape $Shape

        $actions = @(Update-SessionFromMessage -State $state -Message $message)

        $actions.Count | Should -Be 0
        $state.QuotaEligible | Should -BeNullOrEmpty
        $state.Pending.Contains($context.AccountRequest.id) | Should -BeFalse
        $state.Status | Should -BeExactly 'Error'
        $state.LastError | Should -BeExactly 'Unable to read the Codex account state.'
    }
}

Describe 'quota state' {
    It 'normalizes a matched quota response and records a deterministic success time' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.AccountRequest.id
            result = [ordered]@{ account = [ordered]@{ type = 'chatgpt'; planType = 'plus' }; requiresOpenaiAuth = $true }
        }))
        $state.LastError = 'old error'
        $state.ReconnectAttempt = 4
        $now = [datetimeoffset]'2026-07-13T15:30:00Z'

        $actions = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                id = $context.QuotaRequest.id
                result = New-TestRateLimitResult -PlanType 'business' -UsedPercent 25
            }) -Now $now
        )

        $actions.Count | Should -Be 0
        @($state.QuotaWindows).Count | Should -Be 1
        $state.QuotaWindows[0].Key | Should -BeExactly 'codex|primary|300|1783933200'
        $state.QuotaWindows[0].RemainingPercent | Should -Be 75
        $state.PlanType | Should -BeExactly 'business'
        $state.Status | Should -BeExactly 'Live'
        $state.QuotaReadPending | Should -BeFalse
        $state.Pending.Contains($context.QuotaRequest.id) | Should -BeFalse
        $state.ReconnectAttempt | Should -Be 0
        $state.LastError | Should -BeNullOrEmpty
        $state.LastSuccessAt | Should -Be $now
        $state.LastSuccessAt.Offset | Should -Be ([timespan]::Zero)
    }

    It 'does not erase an account plan when a quota result omits planType' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.AccountRequest.id
            result = [ordered]@{ account = [ordered]@{ type = 'chatgpt'; planType = 'plus' }; requiresOpenaiAuth = $true }
        }))

        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.QuotaRequest.id
            result = New-TestRateLimitResult
        }))

        $state.PlanType | Should -BeExactly 'plus'
        $state.Status | Should -BeExactly 'Live'
    }

    It 'uses rate-limit updates only as sparse invalidations and coalesces full reads' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.AccountRequest.id
            result = [ordered]@{ account = [ordered]@{ type = 'chatgpt'; planType = 'plus' }; requiresOpenaiAuth = $true }
        }))
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.QuotaRequest.id
            result = New-TestRateLimitResult -UsedPercent 10
        }))
        $before = $state.QuotaWindows | ConvertTo-Json -Depth 20 -Compress
        $notification = [pscustomobject]@{
            method = 'account/rateLimits/updated'
            params = [ordered]@{
                rateLimits = [ordered]@{
                    limitId = 'codex'
                    primary = [ordered]@{ usedPercent = 99 }
                }
            }
        }

        $first = @(Update-SessionFromMessage -State $state -Message $notification)
        $afterFirst = $state.QuotaWindows | ConvertTo-Json -Depth 20 -Compress
        $second = @(Update-SessionFromMessage -State $state -Message $notification)

        $first.Count | Should -Be 1
        $first[0].method | Should -BeExactly 'account/rateLimits/read'
        $first[0].PSObject.Properties.Name | Should -Not -Contain 'params'
        $second.Count | Should -Be 0
        $state.QuotaReadPending | Should -BeTrue
        $afterFirst | Should -BeExactly $before
        $state.QuotaWindows[0].UsedPercent | Should -Be 10
    }

    It 'discards a dirty quota response and emits one coalesced full refresh' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.AccountRequest.id
            result = [ordered]@{ account = [ordered]@{ type = 'chatgpt'; planType = 'plus' }; requiresOpenaiAuth = $true }
        }))
        $successAt = [datetimeoffset]'2026-07-13T13:00:00Z'
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.QuotaRequest.id
            result = New-TestRateLimitResult -PlanType 'plus' -UsedPercent 10
        }) -Now $successAt)
        $quotaRead = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{}
        }))[0]

        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{ rateLimits = [ordered]@{ limitId = 'codex' } }
        }))
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{ rateLimits = [ordered]@{ limitId = 'codex' } }
        }))
        $state.QuotaRefreshQueued | Should -BeTrue

        $actions = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $quotaRead.id
            result = New-TestRateLimitResult -PlanType 'stale' -UsedPercent 99
        }) -Now $successAt.AddMinutes(1))

        $actions.Count | Should -Be 1
        $actions[0].method | Should -BeExactly 'account/rateLimits/read'
        $actions[0].PSObject.Properties.Name | Should -Not -Contain 'params'
        $actions[0].id | Should -Not -Be $quotaRead.id
        $state.QuotaRefreshQueued | Should -BeFalse
        $state.QuotaReadPending | Should -BeTrue
        $state.Status | Should -BeExactly 'Live'
        $state.PlanType | Should -BeExactly 'plus'
        $state.QuotaWindows[0].UsedPercent | Should -Be 10
        $state.LastSuccessAt | Should -Be $successAt
    }

    It 'queues one follow-up for an initial quota read while eligibility is unknown' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state

        $notificationActions = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{}
        }))
        $notificationActions.Count | Should -Be 0
        $state.QuotaEligible | Should -BeNullOrEmpty
        $state.QuotaRefreshQueued | Should -BeTrue

        $responseActions = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.QuotaRequest.id
            result = New-TestRateLimitResult -UsedPercent 88
        }))

        $responseActions.Count | Should -Be 1
        $responseActions[0].method | Should -BeExactly 'account/rateLimits/read'
        @($state.QuotaWindows).Count | Should -Be 0
        $state.Status | Should -BeExactly 'Starting'
        $state.QuotaReadPending | Should -BeTrue
        $state.QuotaRefreshQueued | Should -BeFalse
    }

    It 'invalidates a noninitial quota refresh after account eligibility becomes unknown' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.AccountRequest.id
            result = [ordered]@{ account = [ordered]@{ type = 'chatgpt'; planType = 'plus' }; requiresOpenaiAuth = $true }
        }))
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.QuotaRequest.id
            result = New-TestRateLimitResult -PlanType 'plus' -UsedPercent 10
        }))
        $quotaRead = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{}
        }))[0]
        $quotaRead.method | Should -BeExactly 'account/rateLimits/read'

        $accountRead = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/updated'; params = [ordered]@{ authMode = 'chatgpt' }
        }))
        $accountRead.Count | Should -Be 1
        $state.QuotaEligible | Should -BeNullOrEmpty

        $actions = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{}
        }))

        $actions.Count | Should -Be 0
        $state.Pending.Contains($quotaRead.id) | Should -BeFalse
        @( $state.Pending.Values | Where-Object Method -EQ 'account/rateLimits/read' ).Count | Should -Be 0
        $state.QuotaReadPending | Should -BeFalse
        $state.QuotaRefreshQueued | Should -BeFalse
    }

    It 'does not poll quota updates before initialization' {
        $startingState = New-SessionState
        $beforeInit = @(Update-SessionFromMessage -State $startingState -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{}
        }))
        $beforeInit.Count | Should -Be 0
    }

    It 'does not restart quota polling after unsupported auth' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.AccountRequest.id
            result = [ordered]@{ account = [ordered]@{ type = 'amazonBedrock' }; requiresOpenaiAuth = $false }
        }))
        $actions = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{}
        }))

        $actions.Count | Should -Be 0
        $state.QuotaEligible | Should -BeFalse
        $state.QuotaReadPending | Should -BeFalse
    }

    It 'sanitizes a matched quota error and clears its pending flag' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state

        $actions = @(
            Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
                id = $context.QuotaRequest.id
                error = [ordered]@{
                    code = 401
                    message = 'sk-secret-value raw upstream failure'
                    data = [ordered]@{ token = 'another-secret' }
                }
            })
        )

        $actions.Count | Should -Be 0
        $state.Status | Should -BeExactly 'Error'
        $state.QuotaReadPending | Should -BeFalse
        $state.Pending.Contains($context.QuotaRequest.id) | Should -BeFalse
        $state.LastError | Should -Not -Match 'secret|upstream'
        $state.ReconnectAttempt | Should -Be 1
    }

    It 'keeps refresh flags consistent when a dirty quota response is an error' {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.AccountRequest.id
            result = [ordered]@{ account = [ordered]@{ type = 'chatgpt'; planType = 'plus' }; requiresOpenaiAuth = $true }
        }))
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{}
        }))

        $actions = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.QuotaRequest.id
            error = [ordered]@{ code = 500; message = 'secret stale error' }
        }))

        $actions.Count | Should -Be 1
        $actions[0].method | Should -BeExactly 'account/rateLimits/read'
        $state.QuotaRefreshQueued | Should -BeFalse
        $state.QuotaReadPending | Should -BeTrue
        $state.LastError | Should -Not -Match 'secret'
    }

    It 'rejects a malformed matched quota response without replacing the last good snapshot' -ForEach @(
        @{ Shape = 'Missing' },
        @{ Shape = 'Null' },
        @{ Shape = 'Scalar' },
        @{ Shape = 'NullError' },
        @{ Shape = 'EmptyObject' }
    ) {
        $state = New-SessionState
        $context = Complete-TestInitialization -State $state
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.AccountRequest.id
            result = [ordered]@{ account = [ordered]@{ type = 'chatgpt'; planType = 'plus' }; requiresOpenaiAuth = $true }
        }))
        $successAt = [datetimeoffset]'2026-07-13T14:00:00Z'
        $null = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            id = $context.QuotaRequest.id
            result = New-TestRateLimitResult -PlanType 'plus' -UsedPercent 15
        }) -Now $successAt)
        $quotaRead = @(Update-SessionFromMessage -State $state -Message ([pscustomobject]@{
            method = 'account/rateLimits/updated'; params = [ordered]@{}
        }))[0]
        $before = $state.QuotaWindows | ConvertTo-Json -Depth 20 -Compress
        $message = New-MalformedTestResponse -Id $quotaRead.id -Shape $Shape

        $actions = @(Update-SessionFromMessage -State $state -Message $message -Now $successAt.AddMinutes(1))

        $actions.Count | Should -Be 0
        ($state.QuotaWindows | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly $before
        $state.LastSuccessAt | Should -Be $successAt
        $state.Status | Should -BeExactly 'Error'
        $state.QuotaReadPending | Should -BeFalse
        $state.LastError | Should -BeExactly 'Unable to read ChatGPT quota from Codex App Server.'
    }
}

Describe 'deterministic retry helpers' {
    It 'uses the locked reconnect delay schedule' {
        $actual = 0..7 | ForEach-Object { Get-ReconnectDelaySeconds -Attempt $_ }

        @($actual) | Should -Be @(2, 5, 15, 30, 60, 60, 60, 60)
    }

    It 'expires a request at the timeout boundary but not before it' {
        $sentAt = [datetimeoffset]'2026-07-13T10:00:00Z'

        Test-RequestExpired -SentAt $sentAt -Now $sentAt.AddSeconds(9.999) -TimeoutSeconds 10 | Should -BeFalse
        Test-RequestExpired -SentAt $sentAt -Now $sentAt.AddSeconds(10) -TimeoutSeconds 10 | Should -BeTrue
        Test-RequestExpired -SentAt $sentAt -Now $sentAt.AddSeconds(11) | Should -BeTrue
    }
}
