param(
    [switch]$Stubborn
)

$ErrorActionPreference = 'Stop'

if ($Stubborn) {
    [Threading.Thread]::Sleep(30000)
    exit 0
}

while ($null -ne ($line = [Console]::In.ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    try {
        $command = $line | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        [Console]::Out.WriteLine('{"id":"","ok":false,"error":{"category":"Protocol","message":"Invalid command.","httpStatus":null,"retryAfterSeconds":null}}')
        [Console]::Out.Flush()
        continue
    }

    switch ([string]$command.extractorScript) {
        'delayed-success' {
            [Threading.Thread]::Sleep(5000)
        }
        'malformed-output' {
            [Console]::Out.WriteLine('not-json')
            [Console]::Out.Flush()
            continue
        }
        'exit-17' {
            exit 17
        }
        'sanitized-failure' {
            $failure = [ordered]@{
                id = [string]$command.id
                ok = $false
                error = [ordered]@{
                    category = 'HttpStatus'
                    message = 'Relay request returned HTTP 401.'
                    httpStatus = 401
                    retryAfterSeconds = $null
                }
            }
            [Console]::Out.WriteLine(($failure | ConvertTo-Json -Depth 6 -Compress))
            [Console]::Out.Flush()
            continue
        }
        'stderr-burst' {
            foreach ($index in 1..12) {
                [Console]::Error.WriteLine("diagnostic-$index")
            }
            [Console]::Error.Flush()
        }
    }

    $response = [ordered]@{
        id = [string]$command.id
        ok = $true
        results = [object[]]@(
            [ordered]@{
                isValid = $true
                invalidMessage = $null
                remaining = [double]7
                unit = 'USD'
                planName = 'Fixture'
                total = [double]10
                used = [double]3
                extra = $null
            }
        )
        meta = [ordered]@{
            httpStatus = 200
            destinationHost = 'fixture.invalid'
            durationMs = 1
        }
    }
    [Console]::Out.WriteLine(($response | ConvertTo-Json -Depth 8 -Compress))
    [Console]::Out.Flush()
}
