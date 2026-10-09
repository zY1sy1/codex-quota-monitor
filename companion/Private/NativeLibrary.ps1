function Initialize-MonitorNativeLibrary {
    [CmdletBinding()]
    param()

    if ($null -ne ('CodexQuotaMonitor.ProcessTransport.V2.CaptureState' -as [type]) -and
        $null -ne ('CodexQuotaMonitor.NativeIconMethodsV1' -as [type]) -and
        $null -ne ('CodexQuotaMonitor.Theme.NativeMethods' -as [type])) {
        return
    }

    $assemblyPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Bin\CodexQuotaMonitor.Native.dll'))
    if (-not [IO.File]::Exists($assemblyPath)) {
        throw [IO.FileNotFoundException]::new(
            'The precompiled monitor helpers are missing. Build with build\Build-NativeHelpers.ps1 or reinstall the monitor.',
            $assemblyPath
        )
    }
    # Loading a DLL does not load Roslyn or compile C# in the resident process.
    $null = [Reflection.Assembly]::LoadFrom($assemblyPath)
}
