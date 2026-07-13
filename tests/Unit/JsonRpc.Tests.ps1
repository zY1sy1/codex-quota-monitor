BeforeAll {
    . "$PSScriptRoot\..\..\companion\Private\JsonRpc.ps1"
}

Describe 'JSON-RPC wire messages' {
    It 'creates a request with an id and without a jsonrpc header' {
        $message = New-RpcRequest -Id 7 -Method 'account/read' -Params ([ordered]@{ refreshToken = $false })

        ($message.PSObject.Properties.Name -join ',') | Should -BeExactly 'method,id,params'
        $message.method | Should -BeExactly 'account/read'
        $message.id | Should -Be 7
        $message.id | Should -BeOfType ([int])
        $message.params.refreshToken | Should -BeFalse
        $message.PSObject.Properties.Name | Should -Not -Contain 'jsonrpc'
    }

    It 'creates a notification without an id or jsonrpc header' {
        $message = New-RpcNotification -Method 'account/updated' -Params ([ordered]@{ authMode = 'chatgpt' })

        ($message.PSObject.Properties.Name -join ',') | Should -BeExactly 'method,params'
        $message.method | Should -BeExactly 'account/updated'
        $message.PSObject.Properties.Name | Should -Not -Contain 'id'
        $message.PSObject.Properties.Name | Should -Not -Contain 'jsonrpc'
    }

    It 'omits params when the caller supplies null' {
        $request = New-RpcRequest -Id 1 -Method 'initialize' -Params $null
        $notification = New-RpcNotification -Method 'initialized' -Params $null

        $request.PSObject.Properties.Name | Should -Not -Contain 'params'
        $notification.PSObject.Properties.Name | Should -Not -Contain 'params'
    }

    It 'preserves an explicitly empty params dictionary' {
        $message = New-RpcRequest -Id 2 -Method 'account/read' -Params ([ordered]@{})

        $message.PSObject.Properties.Name | Should -Contain 'params'
        $message.params | Should -BeOfType ([System.Collections.IDictionary])
        $message.params.Count | Should -Be 0
        ($message | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly '{"method":"account/read","id":2,"params":{}}'
    }

    It 'serializes compact JSON with exactly one trailing LF' {
        $message = New-RpcRequest -Id 3 -Method 'account/rateLimits/read' -Params $null

        $line = ConvertTo-JsonLine -Message $message

        $line | Should -BeExactly ("{`"method`":`"account/rateLimits/read`",`"id`":3}`n")
        $line.EndsWith("`n") | Should -BeTrue
        $line.EndsWith("`n`n") | Should -BeFalse
        $line | Should -Not -Match "`r"
        $line.Substring(0, $line.Length - 1) | Should -Not -Match '[\r\n]'
    }
}
