param(
    [ValidateSet('Happy', 'Malformed', 'ExitAfterInitialize', 'InheritedPipes', 'NonReading', 'FinalBeforeExit')]
    [string]$Scenario = 'Happy'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if ($Scenario -eq 'NonReading') {
    [Threading.Thread]::Sleep(3000)
    exit 0
}

while (($line = [Console]::In.ReadLine()) -ne $null) {
    if ($Scenario -eq 'Malformed') {
        [Console]::Out.WriteLine('{broken')
        [Console]::Out.Flush()
        continue
    }

    if ($line.Length -eq 0) {
        [Console]::Error.WriteLine('empty JSONL frame')
        [Console]::Error.Flush()
        exit 23
    }

    $message = $line | ConvertFrom-Json
    if ($Scenario -eq 'FinalBeforeExit') {
        [Console]::Out.WriteLine('{"method":"test/prelude"}')
        [Console]::Out.WriteLine((@{
                    id = $message.id
                    result = @{ final = $true }
                } | ConvertTo-Json -Depth 20 -Compress))
        [Console]::Out.Flush()
        exit 0
    }

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

            if ($Scenario -eq 'InheritedPipes') {
                $startInfo = [Diagnostics.ProcessStartInfo]::new()
                $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $startInfo.ArgumentList.Add('-NoLogo')
                $startInfo.ArgumentList.Add('-NoProfile')
                $startInfo.ArgumentList.Add('-NonInteractive')
                $startInfo.ArgumentList.Add('-Command')
                $startInfo.ArgumentList.Add('[Threading.Thread]::Sleep(2500)')
                $null = [Diagnostics.Process]::Start($startInfo)
                exit 0
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

        'test/safetyDiagnostics' {
            [Console]::Error.WriteLine('ordinary overflow diagnostic')
            [Console]::Error.WriteLine('client_secret=FAKE_CLIENT_SNAKE')
            [Console]::Error.WriteLine('clientSecret=FAKE_CLIENT_CAMEL')
            [Console]::Error.WriteLine('password=FAKE_PASSWORD')
            [Console]::Error.WriteLine('passwd=FAKE_PASSWD')
            [Console]::Error.WriteLine('credential=FAKE_CREDENTIAL')
            [Console]::Error.WriteLine('private_key=FAKE_PRIVATE_KEY')
            [Console]::Error.WriteLine('session=FAKE_SESSION')
            [Console]::Error.WriteLine('id_token=FAKE_ID_TOKEN_SNAKE')
            [Console]::Error.WriteLine('idToken=FAKE_ID_TOKEN_CAMEL')
            [Console]::Error.WriteLine('token_id=FAKE_TOKEN_ID_SNAKE')
            [Console]::Error.WriteLine('tokenId=FAKE_TOKEN_ID_CAMEL')
            [Console]::Error.WriteLine('session_id=FAKE_SESSION_ID_SNAKE')
            [Console]::Error.WriteLine('sessionId=FAKE_SESSION_ID_CAMEL')
            [Console]::Error.WriteLine('auth_id=FAKE_AUTH_ID_SNAKE')
            [Console]::Error.WriteLine('authId=FAKE_AUTH_ID_CAMEL')
            [Console]::Error.WriteLine('user_email=用户@例子.公司')
            [Console]::Error.WriteLine('{\"client_secret\":\"FAKE_ESCAPED\"} tail=FAKE_TAIL')
            [Console]::Error.WriteLine('contact 用户@例子.公司')
            [Console]::Error.WriteLine((('A' * 19) + [char]::ConvertFromUtf32(0x1F600) + ('Z' * 100)))
            [Console]::Error.Flush()
            [Console]::Out.WriteLine((@{ id = $message.id; result = @{ emitted = 20 } } | ConvertTo-Json -Depth 20 -Compress))
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

        'test/echo' {
            [Console]::Out.WriteLine((@{
                        id = $message.id
                        result = @{ sequence = $message.params.sequence }
                    } | ConvertTo-Json -Depth 20 -Compress))
            [Console]::Out.Flush()
        }
    }
}
