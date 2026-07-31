#requires -Version 7.4

param(
    [Parameter(Mandatory)][string]$Prefix,
    [Parameter(Mandatory)][string]$SingleInstancePath,
    [Parameter(Mandatory)][string]$ReadyPath
)

$ErrorActionPreference = 'Stop'
. $SingleInstancePath

$instance = Enter-MonitorInstance -Prefix $Prefix -Signal None
if (-not $instance.IsPrimary) {
    exit 23
}

try {
    [IO.File]::WriteAllText(
        $ReadyPath,
        [string]$PID,
        [Text.UTF8Encoding]::new($false)
    )
    if ($instance.ExitEvent.WaitOne([TimeSpan]::FromSeconds(30))) {
        exit 0
    }
    exit 24
}
finally {
    Close-MonitorInstance -Instance $instance
}
