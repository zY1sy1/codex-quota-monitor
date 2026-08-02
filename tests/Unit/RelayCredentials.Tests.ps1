BeforeAll {
    $settingsScript = "$PSScriptRoot\..\..\companion\Private\Settings.ps1"
    $credentialsScript = "$PSScriptRoot\..\..\companion\Private\RelayCredentials.ps1"
    . $settingsScript
    if (Test-Path -LiteralPath $credentialsScript -PathType Leaf) {
        . $credentialsScript
    }
}

Describe 'relay monitor paths' {
    It 'adds canonical relay paths below data and app' {
        $paths = Get-MonitorPaths -LocalAppData (Join-Path $TestDrive 'Local') -Startup (Join-Path $TestDrive 'Startup')

        $paths.RelayProviders | Should -BeExactly (Join-Path $paths.Data 'relay-providers.json')
        $paths.RelayCache | Should -BeExactly (Join-Path $paths.Data 'relay-cache.json')
        $paths.RelayHost | Should -BeExactly (Join-Path $paths.App 'Bin\relay-quota-host.exe')
        $paths.RelayPresets | Should -BeExactly (Join-Path $paths.App 'Presets\relay-usage.json')
    }
}

Describe 'relay credential protection' {
    It 'round-trips Unicode with the injected current-user protector' {
        $protected = Protect-RelaySecret -PlainText '密钥-α' -ProtectBytes {
            param($bytes)
            ,([byte[]]($bytes | ForEach-Object { $_ -bxor 0x5A }))
        }

        Unprotect-RelaySecret -CipherText $protected -UnprotectBytes {
            param($bytes)
            ,([byte[]]($bytes | ForEach-Object { $_ -bxor 0x5A }))
        } | Should -BeExactly '密钥-α'
    }

    It 'does not invoke cryptography for empty values' {
        $script:RelayProtectInvoked = $false
        $script:RelayUnprotectInvoked = $false
        try {
            Protect-RelaySecret -PlainText '' -ProtectBytes {
                $script:RelayProtectInvoked = $true
                throw 'must not run'
            } | Should -BeExactly ''
            Unprotect-RelaySecret -CipherText '' -UnprotectBytes {
                $script:RelayUnprotectInvoked = $true
                throw 'must not run'
            } | Should -BeExactly ''

            $script:RelayProtectInvoked | Should -BeFalse
            $script:RelayUnprotectInvoked | Should -BeFalse
        }
        finally {
            Remove-Variable RelayProtectInvoked, RelayUnprotectInvoked -Scope Script -ErrorAction SilentlyContinue
        }
    }

    It 'clears plaintext byte buffers after protection and unprotection' {
        $script:RelayPlainInput = $null
        $script:RelayPlainOutput = $null
        try {
            $cipherText = Protect-RelaySecret -PlainText 'buffer-sentinel' -ProtectBytes {
                param($bytes)
                $script:RelayPlainInput = $bytes
                ,([byte[]](1, 2, 3, 4))
            }
            $cipherText | Should -BeExactly 'AQIDBA=='
            @($script:RelayPlainInput | Where-Object { $_ -ne 0 }).Count | Should -Be 0

            $null = Unprotect-RelaySecret -CipherText $cipherText -UnprotectBytes {
                param($bytes)
                $script:RelayPlainOutput = [Text.Encoding]::UTF8.GetBytes('decrypted-sentinel')
                ,$script:RelayPlainOutput
            }
            @($script:RelayPlainOutput | Where-Object { $_ -ne 0 }).Count | Should -Be 0
        }
        finally {
            Remove-Variable RelayPlainInput, RelayPlainOutput -Scope Script -ErrorAction SilentlyContinue
        }
    }

    It 'rethrows cryptography failures with constant credential-free messages' {
        $secret = 'CREDENTIAL_FAILURE_SENTINEL_812'

        { Protect-RelaySecret -PlainText $secret -ProtectBytes { throw $secret } } |
            Should -Throw -ExpectedMessage 'Relay credential protection failed.'
        { Unprotect-RelaySecret -CipherText 'AQID' -UnprotectBytes { throw $secret } } |
            Should -Throw -ExpectedMessage 'Relay credential decryption failed.'
    }
}
