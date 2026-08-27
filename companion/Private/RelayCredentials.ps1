function Protect-RelaySecret {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$PlainText,

        [Parameter(Position = 1)]
        [scriptblock]$ProtectBytes = {
            param([byte[]]$Bytes)
            [Security.Cryptography.ProtectedData]::Protect(
                $Bytes,
                $null,
                [Security.Cryptography.DataProtectionScope]::CurrentUser
            )
        }
    )

    if ([string]::IsNullOrEmpty($PlainText)) {
        return ''
    }

    [byte[]]$plainBytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    try {
        try {
            [byte[]]$protectedBytes = & $ProtectBytes $plainBytes
            return [Convert]::ToBase64String($protectedBytes)
        }
        catch {
            throw [Security.Cryptography.CryptographicException]::new(
                'Relay credential protection failed.'
            )
        }
    }
    finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Unprotect-RelaySecret {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$CipherText,

        [Parameter(Position = 1)]
        [scriptblock]$UnprotectBytes = {
            param([byte[]]$Bytes)
            [Security.Cryptography.ProtectedData]::Unprotect(
                $Bytes,
                $null,
                [Security.Cryptography.DataProtectionScope]::CurrentUser
            )
        }
    )

    if ([string]::IsNullOrEmpty($CipherText)) {
        return ''
    }

    [byte[]]$cipherBytes = $null
    [byte[]]$plainBytes = $null
    try {
        try {
            $cipherBytes = [Convert]::FromBase64String($CipherText)
            $plainBytes = & $UnprotectBytes $cipherBytes
            return [Text.Encoding]::UTF8.GetString($plainBytes)
        }
        catch {
            throw [Security.Cryptography.CryptographicException]::new(
                'Relay credential decryption failed.'
            )
        }
    }
    finally {
        if ($null -ne $plainBytes) {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }
        if ($null -ne $cipherBytes) {
            [Array]::Clear($cipherBytes, 0, $cipherBytes.Length)
        }
    }
}
