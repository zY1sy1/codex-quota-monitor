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
            $shortcut.WindowStyle = 7
            $shortcut.Hotkey = 'CTRL+ALT+Q'
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
                WindowStyle = [int]$shortcut.WindowStyle
                Hotkey = [string]$shortcut.Hotkey
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
        $expectedShortcutPath = [IO.Path]::GetFullPath($shortcutPath)
        $expectedIconPath = [IO.Path]::GetFullPath(
            (Join-Path $localAppData 'CodexQuotaMonitor\assets\CodexQuotaMonitor.ico')
        )
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
        $after.WindowStyle | Should -BeExactly $before.WindowStyle
        $after.Hotkey | Should -BeExactly $before.Hotkey
        $result.ShortcutPath | Should -BeExactly $expectedShortcutPath
        $result.InstalledIconPath | Should -BeExactly $expectedIconPath
        $after.IconLocation | Should -BeExactly "$expectedIconPath,0"
        Test-Path -LiteralPath $expectedIconPath -PathType Leaf | Should -BeTrue
        [IO.File]::ReadAllBytes($expectedIconPath) |
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

    It 'rejects a directory collision at the stable icon path without changing the shortcut' {
        $shortcutPath = Join-Path $TestDrive 'directory collision.lnk'
        $localAppData = Join-Path $TestDrive 'Directory Collision Local AppData'
        $collisionPath = Join-Path $localAppData 'CodexQuotaMonitor\assets\CodexQuotaMonitor.ico'
        New-Item -ItemType Directory -Path $collisionPath -Force | Out-Null
        New-TestDesktopShortcut -Path $shortcutPath
        $before = [Convert]::ToHexString([IO.File]::ReadAllBytes($shortcutPath))

        {
            & $SetIconScript `
                -ShortcutPath $shortcutPath `
                -IconSourcePath $BlueIcon `
                -LocalAppData $localAppData
        } | Should -Throw '*destination collides*'

        [Convert]::ToHexString([IO.File]::ReadAllBytes($shortcutPath)) |
            Should -BeExactly $before
        @(Get-ChildItem -LiteralPath $collisionPath -Force).Count | Should -Be 0
    }

    It 'preserves an existing stable icon when staging is denied before replacement' {
        $shortcutPath = Join-Path $TestDrive 'staging denied.lnk'
        $localAppData = Join-Path $TestDrive 'Staging Denied Local AppData'
        $assetsDirectory = Join-Path $localAppData 'CodexQuotaMonitor\assets'
        $stableIconPath = Join-Path $assetsDirectory 'CodexQuotaMonitor.ico'
        New-Item -ItemType Directory -Path $assetsDirectory -Force | Out-Null
        $priorIconBytes = [byte[]](11, 22, 33, 44, 55)
        [IO.File]::WriteAllBytes($stableIconPath, $priorIconBytes)
        New-TestDesktopShortcut -Path $shortcutPath
        $shortcutBefore = [Convert]::ToHexString([IO.File]::ReadAllBytes($shortcutPath))

        $originalAcl = Get-Acl -LiteralPath $assetsDirectory
        $blockedAcl = Get-Acl -LiteralPath $assetsDirectory
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $denyCreateFiles = [Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [Security.AccessControl.FileSystemRights]::CreateFiles,
            [Security.AccessControl.AccessControlType]::Deny
        )
        $blockedAcl.AddAccessRule($denyCreateFiles) | Out-Null
        $failure = $null
        try {
            Set-Acl -LiteralPath $assetsDirectory -AclObject $blockedAcl
            try {
                & $SetIconScript `
                    -ShortcutPath $shortcutPath `
                    -IconSourcePath $BlueIcon `
                    -LocalAppData $localAppData
            }
            catch {
                $failure = $_
            }
        }
        finally {
            Set-Acl -LiteralPath $assetsDirectory -AclObject $originalAcl
        }

        $failure | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $stableIconPath -PathType Leaf | Should -BeTrue
        [IO.File]::ReadAllBytes($stableIconPath) | Should -Be $priorIconBytes
        [Convert]::ToHexString([IO.File]::ReadAllBytes($shortcutPath)) |
            Should -BeExactly $shortcutBefore
    }
}
