function New-RpcRequest {
    param(
        [int]$Id,
        [string]$Method,
        [AllowNull()]$Params
    )

    $message = [ordered]@{
        method = $Method
        id = $Id
    }
    if ($null -ne $Params) {
        $message.params = $Params
    }

    [pscustomobject]$message
}

function New-RpcNotification {
    param(
        [string]$Method,
        [AllowNull()]$Params
    )

    $message = [ordered]@{
        method = $Method
    }
    if ($null -ne $Params) {
        $message.params = $Params
    }

    [pscustomobject]$message
}

function ConvertTo-JsonLine {
    param(
        [Parameter(Mandatory)]
        $Message
    )

    (($Message | ConvertTo-Json -Depth 20 -Compress) + "`n")
}
