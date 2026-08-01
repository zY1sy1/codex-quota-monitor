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

    function Get-TestIcoEntry {
        param(
            [Parameter(Mandatory)][byte[]]$Bytes,
            [Parameter(Mandatory)][int]$Index
        )

        $entryOffset = 6 + (16 * $Index)
        [pscustomobject]@{
            DirectoryOffset = $entryOffset
            Width = if ($Bytes[$entryOffset] -eq 0) { 256 } else { [int]$Bytes[$entryOffset] }
            PayloadLength = [BitConverter]::ToUInt32($Bytes, $entryOffset + 8)
            PayloadOffset = [BitConverter]::ToUInt32($Bytes, $entryOffset + 12)
        }
    }

    function Set-TestUInt32LittleEndian {
        param(
            [Parameter(Mandatory)][byte[]]$Bytes,
            [Parameter(Mandatory)][int]$Offset,
            [Parameter(Mandatory)][uint32]$Value
        )

        [BitConverter]::GetBytes($Value).CopyTo($Bytes, $Offset)
    }

    function Set-TestUInt32BigEndian {
        param(
            [Parameter(Mandatory)][byte[]]$Bytes,
            [Parameter(Mandatory)][int]$Offset,
            [Parameter(Mandatory)][uint32]$Value
        )

        $encoded = [BitConverter]::GetBytes($Value)
        if ([BitConverter]::IsLittleEndian) {
            [Array]::Reverse($encoded)
        }
        $encoded.CopyTo($Bytes, $Offset)
    }

    function New-TestSetterFixture {
        param(
            [Parameter(Mandatory)][string]$Name
        )

        $fixtureRoot = Join-Path $TestDrive $Name
        $localAppData = Join-Path $fixtureRoot 'Local AppData'
        $assetsDirectory = Join-Path $localAppData 'CodexQuotaMonitor\assets'
        $stableIconPath = Join-Path $assetsDirectory 'CodexQuotaMonitor.ico'
        $shortcutPath = Join-Path $fixtureRoot 'Codex 额度监控.lnk'
        New-Item -ItemType Directory -Path $assetsDirectory -Force | Out-Null
        $priorIconBytes = [byte[]](101, 102, 103, 104, 105, 106)
        [IO.File]::WriteAllBytes($stableIconPath, $priorIconBytes)
        New-TestDesktopShortcut -Path $shortcutPath

        [pscustomobject]@{
            ShortcutPath = $shortcutPath
            ShortcutBytes = [IO.File]::ReadAllBytes($shortcutPath)
            LocalAppData = $localAppData
            AssetsDirectory = $assetsDirectory
            StableIconPath = $stableIconPath
            PriorIconBytes = $priorIconBytes
        }
    }

    function Get-TestIconArtifacts {
        param([Parameter(Mandatory)]$Fixture)

        @(Get-ChildItem -LiteralPath $Fixture.AssetsDirectory -Force -File |
            Where-Object Name -Like 'CodexQuotaMonitor.ico.*')
    }

    function Get-TestShortcutBackups {
        param([Parameter(Mandatory)]$Fixture)

        $parent = Split-Path -Parent $Fixture.ShortcutPath
        $leaf = Split-Path -Leaf $Fixture.ShortcutPath
        @(Get-ChildItem -LiteralPath $parent -Force -File |
            Where-Object Name -Like "$leaf.*.backup")
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

    It 'rejects malformed ICO payload <Kind> without changing existing state' -ForEach @(
        @{ Kind = 'corrupt PNG signature' }
        @{ Kind = 'truncated IHDR' }
        @{ Kind = 'IHDR dimension mismatch' }
        @{ Kind = 'duplicate directory size and payload' }
    ) {
        $fixture = New-TestSetterFixture -Name "malformed $Kind"
        $malformedIcon = Join-Path $TestDrive "$Kind.ico"
        $bytes = [IO.File]::ReadAllBytes($BlueIcon)
        $first = Get-TestIcoEntry -Bytes $bytes -Index 0

        switch ($Kind) {
            'corrupt PNG signature' {
                $bytes[$first.PayloadOffset] = 0
            }
            'truncated IHDR' {
                Set-TestUInt32LittleEndian `
                    -Bytes $bytes `
                    -Offset ($first.DirectoryOffset + 8) `
                    -Value 20
            }
            'IHDR dimension mismatch' {
                Set-TestUInt32BigEndian `
                    -Bytes $bytes `
                    -Offset ($first.PayloadOffset + 16) `
                    -Value ([uint32]($first.Width + 1))
            }
            'duplicate directory size and payload' {
                [Array]::Copy($bytes, 6, $bytes, 6 + (16 * 6), 16)
            }
        }
        [IO.File]::WriteAllBytes($malformedIcon, $bytes)

        {
            & $SetIconScript `
                -ShortcutPath $fixture.ShortcutPath `
                -IconSourcePath $malformedIcon `
                -LocalAppData $fixture.LocalAppData
        } | Should -Throw '*invalid ICO*'

        [IO.File]::ReadAllBytes($fixture.ShortcutPath) | Should -Be $fixture.ShortcutBytes
        [IO.File]::ReadAllBytes($fixture.StableIconPath) | Should -Be $fixture.PriorIconBytes
        @(Get-TestIconArtifacts -Fixture $fixture).Count | Should -Be 0
        @(Get-TestShortcutBackups -Fixture $fixture).Count | Should -Be 0
    }

    It 'rejects an incomplete PNG chunk stream <Kind> without changing existing state' -ForEach @(
        @{ Kind = 'missing terminal IEND' }
        @{ Kind = 'bytes declared after terminal IEND' }
    ) {
        $fixture = New-TestSetterFixture -Name "chunk stream $Kind"
        $malformedIcon = Join-Path $TestDrive "chunk stream $Kind.ico"
        $bytes = [IO.File]::ReadAllBytes($BlueIcon)
        $last = Get-TestIcoEntry -Bytes $bytes -Index 6

        switch ($Kind) {
            'missing terminal IEND' {
                $shorter = [byte[]]::new($bytes.Length - 12)
                [Array]::Copy($bytes, $shorter, $shorter.Length)
                Set-TestUInt32LittleEndian `
                    -Bytes $shorter `
                    -Offset ($last.DirectoryOffset + 8) `
                    -Value ([uint32]($last.PayloadLength - 12))
                $bytes = $shorter
            }
            'bytes declared after terminal IEND' {
                $longer = [byte[]]::new($bytes.Length + 4)
                [Array]::Copy($bytes, $longer, $bytes.Length)
                $trailingBytes = [byte[]](1, 2, 3, 4)
                $trailingBytes.CopyTo($longer, $bytes.Length)
                Set-TestUInt32LittleEndian `
                    -Bytes $longer `
                    -Offset ($last.DirectoryOffset + 8) `
                    -Value ([uint32]($last.PayloadLength + 4))
                $bytes = $longer
            }
        }
        [IO.File]::WriteAllBytes($malformedIcon, $bytes)

        {
            & $SetIconScript `
                -ShortcutPath $fixture.ShortcutPath `
                -IconSourcePath $malformedIcon `
                -LocalAppData $fixture.LocalAppData
        } | Should -Throw '*invalid ICO*'

        [IO.File]::ReadAllBytes($fixture.ShortcutPath) | Should -Be $fixture.ShortcutBytes
        [IO.File]::ReadAllBytes($fixture.StableIconPath) | Should -Be $fixture.PriorIconBytes
        @(Get-TestIconArtifacts -Fixture $fixture).Count | Should -Be 0
        @(Get-TestShortcutBackups -Fixture $fixture).Count | Should -Be 0
    }

    It 'restores the previous icon after a primary failure following icon replacement' {
        $fixture = New-TestSetterFixture -Name 'fault after icon replacement'
        $stages = [Collections.Generic.List[string]]::new()
        $faultInjector = {
            param($Stage, $Context)
            $stages.Add($Stage)
            if ($Stage -eq 'AfterIconReplacement') {
                throw 'primary fault after icon replacement'
            }
        }.GetNewClosure()
        $failure = $null

        try {
            & $SetIconScript `
                -ShortcutPath $fixture.ShortcutPath `
                -IconSourcePath $BlueIcon `
                -LocalAppData $fixture.LocalAppData `
                -FaultInjector $faultInjector
        }
        catch {
            $failure = $_
        }

        $failure.Exception | Should -Not -BeOfType ([AggregateException])
        $failure.Exception.Message | Should -Match 'primary fault after icon replacement'
        $stages | Should -Contain 'BeforeIconRollback'
        [IO.File]::ReadAllBytes($fixture.StableIconPath) | Should -Be $fixture.PriorIconBytes
        [IO.File]::ReadAllBytes($fixture.ShortcutPath) | Should -Be $fixture.ShortcutBytes
        @(Get-TestIconArtifacts -Fixture $fixture).Count | Should -Be 0
        @(Get-TestShortcutBackups -Fixture $fixture).Count | Should -Be 0
    }

    It 'restores both user files after a primary failure following shortcut update' {
        $fixture = New-TestSetterFixture -Name 'fault after shortcut update'
        $stages = [Collections.Generic.List[string]]::new()
        $faultInjector = {
            param($Stage, $Context)
            $stages.Add($Stage)
            if ($Stage -eq 'AfterShortcutUpdate') {
                throw 'primary fault after shortcut update'
            }
        }.GetNewClosure()
        $failure = $null

        try {
            & $SetIconScript `
                -ShortcutPath $fixture.ShortcutPath `
                -IconSourcePath $BlueIcon `
                -LocalAppData $fixture.LocalAppData `
                -FaultInjector $faultInjector
        }
        catch {
            $failure = $_
        }

        $failure.Exception | Should -Not -BeOfType ([AggregateException])
        $failure.Exception.Message | Should -Match 'primary fault after shortcut update'
        $stages | Should -Contain 'BeforeShortcutRollback'
        $stages | Should -Contain 'BeforeIconRollback'
        [IO.File]::ReadAllBytes($fixture.StableIconPath) | Should -Be $fixture.PriorIconBytes
        [IO.File]::ReadAllBytes($fixture.ShortcutPath) | Should -Be $fixture.ShortcutBytes
        @(Get-TestIconArtifacts -Fixture $fixture).Count | Should -Be 0
        @(Get-TestShortcutBackups -Fixture $fixture).Count | Should -Be 0
    }

    It 'still restores the icon and retains the shortcut backup when shortcut rollback fails' {
        $fixture = New-TestSetterFixture -Name 'shortcut rollback fault'
        $stages = [Collections.Generic.List[string]]::new()
        $faultInjector = {
            param($Stage, $Context)
            $stages.Add($Stage)
            if ($Stage -eq 'AfterShortcutUpdate') {
                throw 'primary shortcut transaction fault'
            }
            if ($Stage -eq 'BeforeShortcutRollback') {
                throw 'shortcut restore fault'
            }
        }.GetNewClosure()
        $failure = $null

        try {
            & $SetIconScript `
                -ShortcutPath $fixture.ShortcutPath `
                -IconSourcePath $BlueIcon `
                -LocalAppData $fixture.LocalAppData `
                -FaultInjector $faultInjector
        }
        catch {
            $failure = $_
        }

        $failure.Exception | Should -BeOfType ([AggregateException])
        $failure.Exception.InnerExceptions.Count | Should -Be 2
        $failure.Exception.ToString() | Should -Match 'primary shortcut transaction fault'
        $failure.Exception.ToString() | Should -Match 'shortcut restore fault'
        $stages | Should -Contain 'BeforeIconRollback'
        [IO.File]::ReadAllBytes($fixture.StableIconPath) | Should -Be $fixture.PriorIconBytes
        $shortcutBackups = @(Get-TestShortcutBackups -Fixture $fixture)
        $shortcutBackups.Count | Should -Be 1
        [IO.File]::ReadAllBytes($shortcutBackups[0].FullName) | Should -Be $fixture.ShortcutBytes
        @(Get-TestIconArtifacts -Fixture $fixture).Count | Should -Be 0
    }

    It 'still restores the shortcut and retains the icon backup when icon rollback fails' {
        $fixture = New-TestSetterFixture -Name 'icon rollback fault'
        $stages = [Collections.Generic.List[string]]::new()
        $faultInjector = {
            param($Stage, $Context)
            $stages.Add($Stage)
            if ($Stage -eq 'AfterShortcutUpdate') {
                throw 'primary icon transaction fault'
            }
            if ($Stage -eq 'BeforeIconRollback') {
                throw 'icon restore fault'
            }
        }.GetNewClosure()
        $failure = $null

        try {
            & $SetIconScript `
                -ShortcutPath $fixture.ShortcutPath `
                -IconSourcePath $BlueIcon `
                -LocalAppData $fixture.LocalAppData `
                -FaultInjector $faultInjector
        }
        catch {
            $failure = $_
        }

        $failure.Exception | Should -BeOfType ([AggregateException])
        $failure.Exception.InnerExceptions.Count | Should -Be 2
        $failure.Exception.ToString() | Should -Match 'primary icon transaction fault'
        $failure.Exception.ToString() | Should -Match 'icon restore fault'
        [IO.File]::ReadAllBytes($fixture.ShortcutPath) | Should -Be $fixture.ShortcutBytes
        $iconBackups = @(Get-TestIconArtifacts -Fixture $fixture |
            Where-Object Name -Like '*.prior')
        $iconBackups.Count | Should -Be 1
        [IO.File]::ReadAllBytes($iconBackups[0].FullName) | Should -Be $fixture.PriorIconBytes
        @(Get-TestShortcutBackups -Fixture $fixture).Count | Should -Be 0
    }

    It 'attempts both rollbacks and retains both backups when both restores fail' {
        $fixture = New-TestSetterFixture -Name 'both rollback faults'
        $stages = [Collections.Generic.List[string]]::new()
        $faultInjector = {
            param($Stage, $Context)
            $stages.Add($Stage)
            switch ($Stage) {
                'AfterShortcutUpdate' { throw 'primary both transaction fault' }
                'BeforeShortcutRollback' { throw 'shortcut rollback fault' }
                'BeforeIconRollback' { throw 'icon rollback fault' }
            }
        }.GetNewClosure()
        $failure = $null

        try {
            & $SetIconScript `
                -ShortcutPath $fixture.ShortcutPath `
                -IconSourcePath $BlueIcon `
                -LocalAppData $fixture.LocalAppData `
                -FaultInjector $faultInjector
        }
        catch {
            $failure = $_
        }

        $failure.Exception | Should -BeOfType ([AggregateException])
        $failure.Exception.InnerExceptions.Count | Should -Be 3
        $failure.Exception.ToString() | Should -Match 'primary both transaction fault'
        $failure.Exception.ToString() | Should -Match 'shortcut rollback fault'
        $failure.Exception.ToString() | Should -Match 'icon rollback fault'
        $stages | Should -Contain 'BeforeShortcutRollback'
        $stages | Should -Contain 'BeforeIconRollback'
        $shortcutBackups = @(Get-TestShortcutBackups -Fixture $fixture)
        $iconBackups = @(Get-TestIconArtifacts -Fixture $fixture |
            Where-Object Name -Like '*.prior')
        $shortcutBackups.Count | Should -Be 1
        $iconBackups.Count | Should -Be 1
        [IO.File]::ReadAllBytes($shortcutBackups[0].FullName) | Should -Be $fixture.ShortcutBytes
        [IO.File]::ReadAllBytes($iconBackups[0].FullName) | Should -Be $fixture.PriorIconBytes
    }

    It 'keeps committed state and the failed artifact when cleanup fails' {
        $fixture = New-TestSetterFixture -Name 'cleanup fault'
        $faultInjector = {
            param($Stage, $Context)
            if ($Stage -eq 'BeforeCleanup' -and $Context.CleanupArtifactPath -like '*.prior') {
                throw 'injected cleanup fault'
            }
        }
        $failure = $null

        try {
            & $SetIconScript `
                -ShortcutPath $fixture.ShortcutPath `
                -IconSourcePath $BlueIcon `
                -LocalAppData $fixture.LocalAppData `
                -FaultInjector $faultInjector
        }
        catch {
            $failure = $_
        }

        $failure.Exception.ToString() | Should -Match 'injected cleanup fault'
        [IO.File]::ReadAllBytes($fixture.StableIconPath) |
            Should -Be ([IO.File]::ReadAllBytes($BlueIcon))
        (Read-TestDesktopShortcut -Path $fixture.ShortcutPath).IconLocation |
            Should -BeExactly "$($fixture.StableIconPath),0"
        $iconBackups = @(Get-TestIconArtifacts -Fixture $fixture |
            Where-Object Name -Like '*.prior')
        $iconBackups.Count | Should -Be 1
        [IO.File]::ReadAllBytes($iconBackups[0].FullName) | Should -Be $fixture.PriorIconBytes
        @(Get-TestShortcutBackups -Fixture $fixture).Count | Should -Be 0
    }
}
