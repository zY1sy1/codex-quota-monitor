param(
    [ValidateSet('Happy', 'Malformed', 'ExitAfterInitialize')]
    [string]$Scenario = 'Happy'
)

$ErrorActionPreference = 'Stop'

while (($line = [Console]::In.ReadLine()) -ne $null) {
    if ($Scenario -eq 'Malformed') {
        [Console]::Out.WriteLine('{broken')
        [Console]::Out.Flush()
        continue
    }

    $message = $line | ConvertFrom-Json
    switch ($message.method) {
        initialize {
            [Console]::Out.WriteLine((@{
                        id = $message.id
                        result = @{
                            userAgent = 'fake'
                            platformFamily = 'windows'
                            platformOs = 'windows'
                        }
                    } | ConvertTo-Json -Depth 20 -Compress))
            [Console]::Out.Flush()

            if ($Scenario -eq 'ExitAfterInitialize') {
                exit 17
            }
        }

        'account/read' {
            [Console]::Out.WriteLine((@{
                        id = $message.id
                        result = @{
                            account = @{
                                type = 'chatgpt'
                                planType = 'plus'
                            }
                            requiresOpenaiAuth = $true
                        }
                    } | ConvertTo-Json -Depth 20 -Compress))
            [Console]::Out.Flush()
        }

        'account/rateLimits/read' {
            [Console]::Out.WriteLine((@{
                        id = $message.id
                        result = @{
                            rateLimits = @{
                                limitId = 'codex'
                                primary = @{
                                    usedPercent = 25
                                    windowDurationMins = 300
                                    resetsAt = 1893456000
                                }
                                secondary = @{
                                    usedPercent = 40
                                    windowDurationMins = 10080
                                    resetsAt = 1893888000
                                }
                            }
                        }
                    } | ConvertTo-Json -Depth 20 -Compress))
            [Console]::Out.Flush()
        }

        'test/diagnostics' {
            # Fixed fake values exercise diagnostic sanitization without using real credentials.
            [Console]::Error.WriteLine('ordinary overflow diagnostic')
            [Console]::Error.WriteLine('{"access_token":"FAKE_ACCESS_VALUE","email":"person@example.invalid"}')
            [Console]::Error.WriteLine('Cookie: session=FAKE_COOKIE_VALUE; secondary=FAKE_COOKIE_SECOND')
            [Console]::Error.WriteLine('{"authorization":"Basic FAKE_JSON_AUTH_VALUE","secret":"FAKE_JSON_RAW_VALUE"}')
            [Console]::Error.WriteLine((('Z' * 4096) + ' secret=FAKE_TRAILING_VALUE'))
            [Console]::Error.WriteLine('Authorization: Bearer FAKE_BEARER_VALUE')
            [Console]::Error.Flush()
            [Console]::Out.WriteLine((@{ id = $message.id; result = @{ emitted = 6 } } | ConvertTo-Json -Depth 20 -Compress))
            [Console]::Out.Flush()
        }

        'test/stdoutBurst' {
            $count = [Math]::Max(0, [Math]::Min(100, [int]$message.params.count))
            for ($index = 0; $index -lt $count; $index++) {
                [Console]::Out.WriteLine((@{ method = 'test/line'; params = @{ index = $index } } | ConvertTo-Json -Depth 20 -Compress))
            }

            [Console]::Out.WriteLine((@{ id = $message.id; result = @{ emitted = $count } } | ConvertTo-Json -Depth 20 -Compress))
            [Console]::Out.Flush()
        }
    }
}
