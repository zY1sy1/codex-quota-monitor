BeforeAll {
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $SetIconScript = Join-Path $RepoRoot 'scripts\Set-CodexQuotaMonitorShortcutIcon.ps1'
    $BlueIcon = Join-Path $RepoRoot 'assets\codex-quota-monitor-white-blue.ico'

    function New-TestDesktopShortcut {
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        $shell = $null
        $shortcut = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($Path)
            $shortcut.TargetPath = '%SystemRoot%\System32\cmd.exe'
            $shortcut.Arguments = '/c echo quota monitor'
            $shortcut.WorkingDirectory = [IO.Path]::GetFullPath($TestDrive)
            $shortcut.Description = 'Codex quota monitor test'
            $shortcut.IconLocation = '%SystemRoot%\System32\shell32.dll,1'
            $shortcut.Save()
        }
        finally {
            if ($null -ne $shortcut) {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
            }
            if ($null -ne $shell) {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
            }
        }
    }

    function Read-TestDesktopShortcut {
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        $shell = $null
        $shortcut = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($Path)
            return [pscustomobject]@{
                TargetPath = [string]$shortcut.TargetPath
                Arguments = [string]$shortcut.Arguments
                WorkingDirectory = [string]$shortcut.WorkingDirectory
                Description = [string]$shortcut.Description
                IconLocation = [string]$shortcut.IconLocation
            }
        }
        finally {
            if ($null -ne $shortcut) {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
            }
            if ($null -ne $shell) {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
            }
        }
    }
}

Describe 'desktop shortcut icon updater' {
    It 'installs the icon and changes no launch properties' {
        $shortcutPath = Join-Path $TestDrive 'Codex 额度监控.lnk'
        $localAppData = Join-Path $TestDrive 'Local AppData'
        New-Item -ItemType Directory -Path $localAppData -Force | Out-Null
        New-TestDesktopShortcut -Path $shortcutPath
        $before = Read-TestDesktopShortcut -Path $shortcutPath

        $result = & $SetIconScript `
            -ShortcutPath $shortcutPath `
            -IconSourcePath $BlueIcon `
            -LocalAppData $localAppData

        $after = Read-TestDesktopShortcut -Path $shortcutPath
        $after.TargetPath | Should -BeExactly $before.TargetPath
        $after.Arguments | Should -BeExactly $before.Arguments
        $after.WorkingDirectory | Should -BeExactly $before.WorkingDirectory
        $after.Description | Should -BeExactly $before.Description
        $after.IconLocation | Should -BeExactly ($result.InstalledIconPath + ',0')
        Test-Path -LiteralPath $result.InstalledIconPath -PathType Leaf | Should -BeTrue
        [IO.File]::ReadAllBytes($result.InstalledIconPath) |
            Should -Be ([IO.File]::ReadAllBytes($BlueIcon))
    }

    It 'leaves the shortcut bytes unchanged when the source icon is missing' {
        $shortcutPath = Join-Path $TestDrive 'missing source icon.lnk'
        $localAppData = Join-Path $TestDrive 'Missing Source Local AppData'
        $missingIcon = Join-Path $TestDrive 'missing.ico'
        New-Item -ItemType Directory -Path $localAppData -Force | Out-Null
        New-TestDesktopShortcut -Path $shortcutPath
        $before = [Convert]::ToHexString([IO.File]::ReadAllBytes($shortcutPath))

        {
            & $SetIconScript `
                -ShortcutPath $shortcutPath `
                -IconSourcePath $missingIcon `
                -LocalAppData $localAppData
        } | Should -Throw '*source icon does not exist*'

        $after = [Convert]::ToHexString([IO.File]::ReadAllBytes($shortcutPath))
        $after | Should -BeExactly $before
    }
}
