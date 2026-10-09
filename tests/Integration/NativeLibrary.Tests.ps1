BeforeAll {
    $script:NativeManifest = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\companion\CodexQuotaMonitor.psd1'))
}

Describe 'precompiled native helpers' {
    It 'loads transport icon and theme helpers without loading a C sharp compiler' {
        $probe = @'
param($Manifest)
$ErrorActionPreference = 'Stop'
Import-Module -Name $Manifest
$capture = [CodexQuotaMonitor.ProcessTransport.V2.CaptureState]::new(10,10,128)
if ($capture.GetType().Assembly.GetName().Name -ne 'CodexQuotaMonitor.Native') { throw 'Wrong helper assembly.' }
if ($null -eq ('CodexQuotaMonitor.NativeIconMethodsV1' -as [type])) { throw 'Icon helpers missing.' }
if ($null -eq ('CodexQuotaMonitor.Theme.NativeMethods' -as [type])) { throw 'Theme helpers missing.' }
if (@([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -like 'Microsoft.CodeAnalysis*' }).Count -gt 0) { throw 'Roslyn was loaded at runtime.' }
'PRECOMPILED'
'@
        $probePath = Join-Path $TestDrive 'native-probe.ps1'
        [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
        $output = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -File $probePath -Manifest $script:NativeManifest
        $LASTEXITCODE | Should -Be 0
        $output | Should -BeExactly 'PRECOMPILED'
    }
}
