# Codex 额度监控快捷方式图标 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 生成纯白和白蓝两套原创多尺寸 Windows 图标，并把白蓝图标安全应用到当前用户现有的 `Codex 额度监控.lnk` 桌面快捷方式。

**Architecture:** 一个仅用于构建的 Python/Pillow 生成器从同一组固定几何和颜色常量生成 SVG 源文件及多尺寸 ICO，Pester 单元测试直接验证资源契约。一个独立 PowerShell 脚本验证 ICO、复制到稳定的 `%LOCALAPPDATA%` 路径，并通过 `WScript.Shell` 只更新现有桌面快捷方式的 `IconLocation`；真实 `.lnk` 集成测试证明目标、参数和工作目录保持不变。

**Tech Stack:** Python 3、Pillow、SVG、Windows ICO、PowerShell 7.4、Pester 5、WScript.Shell COM

---

## 文件结构

- `build/New-ShortcutIcons.py`：唯一的图标生成源，集中保存颜色、几何、SVG 输出和 ICO 渲染逻辑。
- `assets/codex-quota-monitor-white.svg`：纯白色系可编辑矢量源文件，由生成器创建。
- `assets/codex-quota-monitor-white-blue.svg`：白蓝色系可编辑矢量源文件，由生成器创建。
- `assets/codex-quota-monitor-white.ico`：纯白色系多尺寸 Windows 图标，由生成器创建。
- `assets/codex-quota-monitor-white-blue.ico`：白蓝色系多尺寸 Windows 图标，由生成器创建。
- `tests/Unit/ShortcutIconAssets.Tests.ps1`：验证 SVG 配色、几何标记以及 ICO 的 7 个目录项。
- `scripts/Set-CodexQuotaMonitorShortcutIcon.ps1`：验证并安装白蓝 ICO，只修改现有桌面快捷方式的图标位置，失败时回滚。
- `tests/Integration/DesktopShortcutIcon.Tests.ps1`：用真实 `.lnk` 验证成功更新与失败不改动行为。
- `README.md`：说明两套资源和桌面图标应用命令，明确不改开机启动项。

### Task 1: 建立图标资源契约测试

**Files:**
- Create: `tests/Unit/ShortcutIconAssets.Tests.ps1`

- [ ] **Step 1: 写入当前必然失败的资源测试**

```powershell
BeforeAll {
    $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

    function Read-TestIcoDirectory {
        param([Parameter(Mandatory)][string]$Path)

        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 6) {
            throw 'ICO header is truncated.'
        }

        $reserved = [BitConverter]::ToUInt16($bytes, 0)
        $type = [BitConverter]::ToUInt16($bytes, 2)
        $count = [BitConverter]::ToUInt16($bytes, 4)
        if ($reserved -ne 0 -or $type -ne 1 -or $bytes.Length -lt (6 + 16 * $count)) {
            throw 'ICO directory is invalid.'
        }

        $entries = for ($index = 0; $index -lt $count; $index++) {
            $offset = 6 + (16 * $index)
            $width = if ($bytes[$offset] -eq 0) { 256 } else { [int]$bytes[$offset] }
            $height = if ($bytes[$offset + 1] -eq 0) { 256 } else { [int]$bytes[$offset + 1] }
            $length = [BitConverter]::ToUInt32($bytes, $offset + 8)
            $imageOffset = [BitConverter]::ToUInt32($bytes, $offset + 12)
            if ($width -ne $height -or $length -eq 0 -or
                ([uint64]$imageOffset + [uint64]$length) -gt [uint64]$bytes.Length) {
                throw 'ICO image entry is invalid.'
            }
            [pscustomobject]@{
                Width = $width
                Height = $height
                Length = $length
                Offset = $imageOffset
            }
        }

        [pscustomobject]@{
            Count = [int]$count
            Entries = @($entries)
        }
    }
}

Describe 'shortcut icon assets' {
    It 'matches the <Name> SVG design contract' -TestCases @(
        @{
            Name = 'white'
            File = 'codex-quota-monitor-white.svg'
            Colors = @('#FFFFFF', '#D7DDE5', '#E7EBF0', '#64748B', '#1F2937')
        }
        @{
            Name = 'white-blue'
            File = 'codex-quota-monitor-white-blue.svg'
            Colors = @('#FFFFFF', '#BFDBFE', '#DBEAFE', '#60A5FA', '#2563EB', '#1E3A8A')
        }
    ) {
        param($Name, $File, $Colors)

        $path = Join-Path $RepoRoot "assets\$File"
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $svg = [IO.File]::ReadAllText($path)
        $svg | Should -Match 'viewBox="0 0 128 128"'
        $svg | Should -Match '<rect x="5" y="5" width="118" height="118" rx="29"'
        $svg | Should -Match '<circle cx="64" cy="64" r="41"'
        $svg | Should -Match 'M64 23a41 41 0 1 1-37\.9 56\.5'
        $svg | Should -Match 'm47 51 13 13-13 13M66 78h18'
        foreach ($color in $Colors) {
            $svg | Should -Match ([regex]::Escape($color))
        }
        $svg | Should -Not -Match '(?i)openai|blossom|wordmark'
    }

    It 'contains all required frames in <File>' -TestCases @(
        @{ File = 'codex-quota-monitor-white.ico' }
        @{ File = 'codex-quota-monitor-white-blue.ico' }
    ) {
        param($File)

        $path = Join-Path $RepoRoot "assets\$File"
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $directory = Read-TestIcoDirectory -Path $path
        $directory.Count | Should -Be 7
        @($directory.Entries.Width | Sort-Object) | Should -Be @(16, 24, 32, 48, 64, 128, 256)
    }
}
```

- [ ] **Step 2: 运行定向测试并确认红灯原因正确**

Run:

```powershell
pwsh -NoProfile -File .\build\Test.ps1 -Suite Unit
```

Expected: `ShortcutIconAssets.Tests.ps1` 的 4 个用例因为四个资源文件尚不存在而失败，既有单元测试继续通过。

### Task 2: 从统一源生成两套 SVG 和 ICO

**Files:**
- Create: `build/New-ShortcutIcons.py`
- Create: `assets/codex-quota-monitor-white.svg`
- Create: `assets/codex-quota-monitor-white-blue.svg`
- Create: `assets/codex-quota-monitor-white.ico`
- Create: `assets/codex-quota-monitor-white-blue.ico`
- Test: `tests/Unit/ShortcutIconAssets.Tests.ps1`

- [ ] **Step 1: 创建确定性图标生成器**

```python
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw


VIEW_SIZE = 128
ICO_SIZES = (16, 24, 32, 48, 64, 128, 256)
VARIANTS = {
    "white": {
        "border": "#D7DDE5",
        "track": "#E7EBF0",
        "arc_start": "#64748B",
        "arc_end": "#64748B",
        "glyph": "#1F2937",
    },
    "white-blue": {
        "border": "#BFDBFE",
        "track": "#DBEAFE",
        "arc_start": "#60A5FA",
        "arc_end": "#2563EB",
        "glyph": "#1E3A8A",
    },
}


def svg_document(colors: dict[str, str]) -> str:
    arc_paint = colors["arc_start"]
    definitions = ""
    if colors["arc_start"] != colors["arc_end"]:
        definitions = (
            '  <defs>\n'
            '    <linearGradient id="quotaArc" x1="0" y1="0" x2="1" y2="1">\n'
            f'      <stop stop-color="{colors["arc_start"]}"/>\n'
            f'      <stop offset="1" stop-color="{colors["arc_end"]}"/>\n'
            '    </linearGradient>\n'
            '  </defs>\n'
        )
        arc_paint = "url(#quotaArc)"

    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" '
        'role="img" aria-label="Quota monitor gauge">\n'
        f'{definitions}'
        f'  <rect x="5" y="5" width="118" height="118" rx="29" fill="#FFFFFF" '
        f'stroke="{colors["border"]}" stroke-width="4"/>\n'
        f'  <circle cx="64" cy="64" r="41" fill="none" stroke="{colors["track"]}" '
        'stroke-width="12"/>\n'
        '  <path d="M64 23a41 41 0 1 1-37.9 56.5" fill="none" '
        f'stroke="{arc_paint}" stroke-width="12" stroke-linecap="round"/>\n'
        '  <path d="m47 51 13 13-13 13M66 78h18" fill="none" '
        f'stroke="{colors["glyph"]}" stroke-width="7" stroke-linecap="round" '
        'stroke-linejoin="round"/>\n'
        '</svg>\n'
    )


def rgb(hex_color: str) -> tuple[int, int, int, int]:
    value = hex_color.removeprefix("#")
    return tuple(int(value[index : index + 2], 16) for index in (0, 2, 4)) + (255,)


def scaled(value: float, factor: int) -> int:
    return round(value * factor)


def draw_round_line(
    draw: ImageDraw.ImageDraw,
    points: list[tuple[float, float]],
    color: tuple[int, int, int, int] | int,
    width: int,
    factor: int,
) -> None:
    rendered = [(scaled(x, factor), scaled(y, factor)) for x, y in points]
    draw.line(rendered, fill=color, width=width, joint="curve")
    radius = width // 2
    for x, y in (rendered[0], rendered[-1]):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)


def diagonal_gradient(size: int, start: str, end: str) -> Image.Image:
    first = rgb(start)
    last = rgb(end)
    denominator = max(1, 2 * (size - 1))
    pixels = []
    for y in range(size):
        for x in range(size):
            position = (x + y) / denominator
            pixels.append(
                tuple(round(first[channel] + (last[channel] - first[channel]) * position)
                      for channel in range(4))
            )
    image = Image.new("RGBA", (size, size))
    image.putdata(pixels)
    return image


def render_icon(colors: dict[str, str], output_size: int = 256) -> Image.Image:
    factor = 4
    canvas_size = output_size * factor
    unit = canvas_size // VIEW_SIZE
    image = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    draw.rounded_rectangle(
        tuple(scaled(value, unit) for value in (5, 5, 123, 123)),
        radius=scaled(29, unit),
        fill=rgb("#FFFFFF"),
        outline=rgb(colors["border"]),
        width=scaled(4, unit),
    )
    gauge_box = tuple(scaled(value, unit) for value in (23, 23, 105, 105))
    draw.ellipse(gauge_box, outline=rgb(colors["track"]), width=scaled(12, unit))

    arc_mask = Image.new("L", (canvas_size, canvas_size), 0)
    arc_draw = ImageDraw.Draw(arc_mask)
    arc_width = scaled(12, unit)
    arc_draw.arc(gauge_box, start=-90, end=157.7, fill=255, width=arc_width)
    arc_radius = arc_width // 2
    for x, y in ((64, 23), (26.1, 79.5)):
        center_x, center_y = scaled(x, unit), scaled(y, unit)
        arc_draw.ellipse(
            (center_x - arc_radius, center_y - arc_radius,
             center_x + arc_radius, center_y + arc_radius),
            fill=255,
        )

    if colors["arc_start"] == colors["arc_end"]:
        arc_layer = Image.new("RGBA", image.size, rgb(colors["arc_start"]))
    else:
        arc_layer = diagonal_gradient(canvas_size, colors["arc_start"], colors["arc_end"])
    image.paste(arc_layer, (0, 0), arc_mask)

    draw = ImageDraw.Draw(image)
    glyph_width = scaled(7, unit)
    glyph_color = rgb(colors["glyph"])
    draw_round_line(draw, [(47, 51), (60, 64), (47, 77)], glyph_color, glyph_width, unit)
    draw_round_line(draw, [(66, 78), (84, 78)], glyph_color, glyph_width, unit)

    return image.resize((output_size, output_size), Image.Resampling.LANCZOS)


def generate(output_directory: Path) -> None:
    output_directory.mkdir(parents=True, exist_ok=True)
    for name, colors in VARIANTS.items():
        stem = f"codex-quota-monitor-{name}"
        (output_directory / f"{stem}.svg").write_text(
            svg_document(colors), encoding="utf-8", newline="\n"
        )
        render_icon(colors).save(
            output_directory / f"{stem}.ico",
            format="ICO",
            sizes=ICO_SIZES,
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate Codex quota monitor shortcut icons.")
    parser.add_argument("--output-dir", type=Path, required=True)
    arguments = parser.parse_args()
    generate(arguments.output_dir.resolve())


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: 使用工作区自带 Python/Pillow 生成四个资源**

Run:

```powershell
$python = 'C:\Users\335\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $python .\build\New-ShortcutIcons.py --output-dir .\assets
```

Expected: 退出码为 0，`assets` 中出现两份 SVG 和两份 ICO；不覆盖既有的 `plugin-icon.svg`。

- [ ] **Step 3: 运行资源测试并确认绿灯**

Run:

```powershell
pwsh -NoProfile -File .\build\Test.ps1 -Suite Unit
```

Expected: `Result: Passed` 且 `FailedCount: 0`，资源测试的 4 个用例全部通过。

- [ ] **Step 4: 提交生成器、资源和契约测试**

```powershell
git add -- build/New-ShortcutIcons.py assets/codex-quota-monitor-white.svg assets/codex-quota-monitor-white-blue.svg assets/codex-quota-monitor-white.ico assets/codex-quota-monitor-white-blue.ico tests/Unit/ShortcutIconAssets.Tests.ps1
git commit -m "feat: add shortcut icon assets"
```

### Task 3: 建立桌面快捷方式安全更新测试

**Files:**
- Create: `tests/Integration/DesktopShortcutIcon.Tests.ps1`

- [ ] **Step 1: 写入真实 `.lnk` 集成测试**

```powershell
BeforeAll {
    $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:SetIconScript = Join-Path $RepoRoot 'scripts\Set-CodexQuotaMonitorShortcutIcon.ps1'
    $script:BlueIcon = Join-Path $RepoRoot 'assets\codex-quota-monitor-white-blue.ico'

    function New-TestDesktopShortcut {
        param([Parameter(Mandatory)][string]$Path)

        $shell = $null
        $shortcut = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($Path)
            $shortcut.TargetPath = (Join-Path $env:SystemRoot 'System32\cmd.exe')
            $shortcut.Arguments = '/c echo quota monitor'
            $shortcut.WorkingDirectory = [IO.Path]::GetFullPath($TestDrive)
            $shortcut.Description = 'Codex quota monitor test'
            $shortcut.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',1'
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
        param([Parameter(Mandatory)][string]$Path)

        $shell = $null
        $shortcut = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($Path)
            [pscustomobject]@{
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
        [IO.File]::ReadAllBytes($result.InstalledIconPath) | Should -Be ([IO.File]::ReadAllBytes($BlueIcon))
    }

    It 'leaves the shortcut bytes unchanged when the source icon is missing' {
        $shortcutPath = Join-Path $TestDrive 'Codex 额度监控 missing source.lnk'
        $localAppData = Join-Path $TestDrive 'Missing LocalAppData'
        New-TestDesktopShortcut -Path $shortcutPath
        $before = [Convert]::ToHexString([IO.File]::ReadAllBytes($shortcutPath))

        {
            & $SetIconScript `
                -ShortcutPath $shortcutPath `
                -IconSourcePath (Join-Path $TestDrive 'missing.ico') `
                -LocalAppData $localAppData
        } | Should -Throw '*source icon does not exist*'

        [Convert]::ToHexString([IO.File]::ReadAllBytes($shortcutPath)) | Should -BeExactly $before
    }
}
```

- [ ] **Step 2: 运行定向集成测试并确认红灯原因正确**

Run:

```powershell
pwsh -NoProfile -File .\build\Test.ps1 -Suite Integration
```

Expected: 新增的 2 个测试因为 `Set-CodexQuotaMonitorShortcutIcon.ps1` 尚不存在而失败，既有集成测试继续通过。

### Task 4: 实现带回滚的快捷方式图标更新器

**Files:**
- Create: `scripts/Set-CodexQuotaMonitorShortcutIcon.ps1`
- Test: `tests/Integration/DesktopShortcutIcon.Tests.ps1`

- [ ] **Step 1: 创建只修改 `IconLocation` 的更新脚本**

```powershell
#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex 额度监控.lnk'),
    [string]$IconSourcePath = (Join-Path $PSScriptRoot '..\assets\codex-quota-monitor-white-blue.ico'),
    [string]$LocalAppData = $env:LOCALAPPDATA
)

$ErrorActionPreference = 'Stop'
$requiredSizes = @(16, 24, 32, 48, 64, 128, 256)

function Get-IcoSizes {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 6 -or [BitConverter]::ToUInt16($bytes, 0) -ne 0 -or
        [BitConverter]::ToUInt16($bytes, 2) -ne 1) {
        throw [IO.InvalidDataException]::new('The source icon has an invalid ICO header.')
    }
    $count = [BitConverter]::ToUInt16($bytes, 4)
    if ($count -lt 1 -or $bytes.Length -lt (6 + 16 * $count)) {
        throw [IO.InvalidDataException]::new('The source icon has an invalid ICO directory.')
    }

    @(
        for ($index = 0; $index -lt $count; $index++) {
            $offset = 6 + (16 * $index)
            $width = if ($bytes[$offset] -eq 0) { 256 } else { [int]$bytes[$offset] }
            $height = if ($bytes[$offset + 1] -eq 0) { 256 } else { [int]$bytes[$offset + 1] }
            $length = [BitConverter]::ToUInt32($bytes, $offset + 8)
            $imageOffset = [BitConverter]::ToUInt32($bytes, $offset + 12)
            if ($width -ne $height -or $length -eq 0 -or
                ([uint64]$imageOffset + [uint64]$length) -gt [uint64]$bytes.Length) {
                throw [IO.InvalidDataException]::new('The source icon contains an invalid image entry.')
            }
            $width
        }
    ) | Sort-Object -Unique
}

function Get-ShortcutState {
    param([Parameter(Mandatory)][string]$Path)

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        [pscustomobject]@{
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

function Set-ShortcutIconLocation {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$IconLocation
    )

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.IconLocation = $IconLocation
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

$fullShortcutPath = [IO.Path]::GetFullPath($ShortcutPath)
$fullIconSourcePath = [IO.Path]::GetFullPath($IconSourcePath)
if (-not (Test-Path -LiteralPath $fullShortcutPath -PathType Leaf)) {
    throw [IO.FileNotFoundException]::new('The desktop shortcut does not exist.', $fullShortcutPath)
}
if (-not $fullShortcutPath.EndsWith('.lnk', [StringComparison]::OrdinalIgnoreCase)) {
    throw [ArgumentException]::new('ShortcutPath must end in .lnk.', 'ShortcutPath')
}
if (-not (Test-Path -LiteralPath $fullIconSourcePath -PathType Leaf)) {
    throw [IO.FileNotFoundException]::new('The source icon does not exist.', $fullIconSourcePath)
}
if ([string]::IsNullOrWhiteSpace($LocalAppData)) {
    throw [ArgumentException]::new('LocalAppData is required.', 'LocalAppData')
}

$actualSizes = @(Get-IcoSizes -Path $fullIconSourcePath)
if (Compare-Object -ReferenceObject $requiredSizes -DifferenceObject $actualSizes) {
    throw [IO.InvalidDataException]::new('The source icon does not contain the required frame sizes.')
}

$monitorInstallRoot = [IO.Path]::GetFullPath((Join-Path $LocalAppData 'CodexQuotaMonitor'))
$iconDirectory = Join-Path $monitorInstallRoot 'assets'
$installedIconPath = Join-Path $iconDirectory 'CodexQuotaMonitor.ico'
$token = [guid]::NewGuid().ToString('N')
$temporaryIconPath = "$installedIconPath.new.$token"
$iconBackupPath = "$installedIconPath.backup.$token"
$shortcutBackupPath = "$fullShortcutPath.backup.$token.lnk"
$hadInstalledIcon = Test-Path -LiteralPath $installedIconPath -PathType Leaf
$shortcutBackupCreated = $false
$iconBackupCreated = $false

$before = Get-ShortcutState -Path $fullShortcutPath
try {
    $null = New-Item -ItemType Directory -Path $iconDirectory -Force
    Copy-Item -LiteralPath $fullIconSourcePath -Destination $temporaryIconPath -Force
    $null = Get-IcoSizes -Path $temporaryIconPath

    if ($hadInstalledIcon) {
        Copy-Item -LiteralPath $installedIconPath -Destination $iconBackupPath -Force
        $iconBackupCreated = $true
    }
    Move-Item -LiteralPath $temporaryIconPath -Destination $installedIconPath -Force

    Copy-Item -LiteralPath $fullShortcutPath -Destination $shortcutBackupPath -Force
    $shortcutBackupCreated = $true
    $newIconLocation = "$installedIconPath,0"
    Set-ShortcutIconLocation -Path $fullShortcutPath -IconLocation $newIconLocation
    $after = Get-ShortcutState -Path $fullShortcutPath

    foreach ($property in @('TargetPath', 'Arguments', 'WorkingDirectory', 'Description')) {
        if ($after.$property -cne $before.$property) {
            throw [IO.IOException]::new("Shortcut property changed unexpectedly: $property")
        }
    }
    if ($after.IconLocation -cne $newIconLocation) {
        throw [IO.IOException]::new('The shortcut icon location was not saved correctly.')
    }

    [pscustomobject]@{
        ShortcutPath = $fullShortcutPath
        InstalledIconPath = $installedIconPath
        PreviousIconLocation = $before.IconLocation
        IconLocation = $after.IconLocation
        TargetPath = $after.TargetPath
        Arguments = $after.Arguments
        WorkingDirectory = $after.WorkingDirectory
    }
}
catch {
    if ($shortcutBackupCreated) {
        Copy-Item -LiteralPath $shortcutBackupPath -Destination $fullShortcutPath -Force
    }
    if ($iconBackupCreated) {
        Copy-Item -LiteralPath $iconBackupPath -Destination $installedIconPath -Force
    }
    elseif (-not $hadInstalledIcon -and (Test-Path -LiteralPath $installedIconPath -PathType Leaf)) {
        Remove-Item -LiteralPath $installedIconPath -Force
    }
    throw
}
finally {
    foreach ($temporaryPath in @($temporaryIconPath, $iconBackupPath, $shortcutBackupPath)) {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}
```

- [ ] **Step 2: 运行集成测试并确认绿灯**

Run:

```powershell
pwsh -NoProfile -File .\build\Test.ps1 -Suite Integration
```

Expected: `Result: Passed` 且 `FailedCount: 0`；新增的成功路径与源文件缺失路径均通过。

- [ ] **Step 3: 提交快捷方式更新器和集成测试**

```powershell
git add -- scripts/Set-CodexQuotaMonitorShortcutIcon.ps1 tests/Integration/DesktopShortcutIcon.Tests.ps1
git commit -m "feat: apply desktop shortcut icon safely"
```

### Task 5: 记录用户操作方式

**Files:**
- Modify: `README.md`，在“开机启动”之后添加“桌面快捷方式图标”章节

- [ ] **Step 1: 添加两套图标和应用命令说明**

````markdown
## 桌面快捷方式图标

项目提供纯白和白蓝两套原创图标：

- `assets/codex-quota-monitor-white.ico`；
- `assets/codex-quota-monitor-white-blue.ico`。

已有桌面快捷方式名为 `Codex 额度监控.lnk` 时，可在仓库根目录运行：

```powershell
pwsh -NoProfile -File .\scripts\Set-CodexQuotaMonitorShortcutIcon.ps1
```

该脚本把白蓝图标复制到 `%LOCALAPPDATA%\CodexQuotaMonitor\assets\CodexQuotaMonitor.ico`，只更新桌面快捷方式的图标位置，不改变目标、参数、工作目录或开机启动快捷方式。源图标缺失、尺寸不完整或复制失败时，原快捷方式保持不变。

本项目是非官方工具，与 OpenAI 不存在隶属、认可或合作关系。项目图标不使用 OpenAI/Codex 官方花结或字标。
````

- [ ] **Step 2: 检查 README 代码围栏和差异格式**

Run:

```powershell
git diff --check
rg -n "桌面快捷方式图标|Set-CodexQuotaMonitorShortcutIcon|不改变目标|非官方工具" README.md
```

Expected: `git diff --check` 无输出；`rg` 返回新章节标题、命令、安全边界和非官方声明四处匹配。

- [ ] **Step 3: 提交文档**

```powershell
git add -- README.md
git commit -m "docs: explain desktop shortcut icon"
```

### Task 6: 在当前机器应用白蓝图标并完成验证

**Files:**
- Modify outside repository: `%LOCALAPPDATA%\CodexQuotaMonitor\assets\CodexQuotaMonitor.ico`
- Modify outside repository: `%USERPROFILE%\Desktop\Codex 额度监控.lnk` 的 `IconLocation`
- Do not modify: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Codex Quota Monitor.lnk`

- [ ] **Step 1: 预览两套 256 像素图标**

Run:

```powershell
$python = 'C:\Users\335\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $python -c "from pathlib import Path; from PIL import Image; sizes=(16,24,32,48,64,128,256); out=Path('outputs/icon-preview'); out.mkdir(parents=True, exist_ok=True); icons=list(Path('assets').glob('codex-quota-monitor-*.ico')); [(lambda source, sheet: ([sheet.paste(source.ico.getimage((s,s)).resize((256,256), Image.Resampling.NEAREST), (i*256,0), source.ico.getimage((s,s)).resize((256,256), Image.Resampling.NEAREST)) for i,s in enumerate(sizes)], sheet.save(out/(p.stem+'-all-sizes.png'))))(Image.open(p), Image.new('RGBA',(256*len(sizes),256),(241,245,249,255))) for p in icons]"
```

Expected: `outputs/icon-preview` 中出现纯白和白蓝两张尺寸对照图，每张从左到右展示 16、24、32、48、64、128、256 像素的真实 ICO 帧；使用本地图片查看工具检查两套图标与已批准设计一致，白蓝图标在 16、32、48 和 256 像素下仍可辨认，背景外缘透明、线条无裁切。

- [ ] **Step 2: 在同一 PowerShell 进程中保存基线、应用图标并比较关键字段**

Run:

```powershell
$shortcutPath = 'C:\Users\335\Desktop\Codex 额度监控.lnk'
$shell = New-Object -ComObject WScript.Shell
$beforeLink = $shell.CreateShortcut($shortcutPath)
$before = [pscustomobject]@{
    TargetPath = [string]$beforeLink.TargetPath
    Arguments = [string]$beforeLink.Arguments
    WorkingDirectory = [string]$beforeLink.WorkingDirectory
}
[Runtime.InteropServices.Marshal]::FinalReleaseComObject($beforeLink) | Out-Null

$result = .\scripts\Set-CodexQuotaMonitorShortcutIcon.ps1 -ShortcutPath $shortcutPath
$afterLink = $shell.CreateShortcut($shortcutPath)
$after = [pscustomobject]@{
    TargetPath = [string]$afterLink.TargetPath
    Arguments = [string]$afterLink.Arguments
    WorkingDirectory = [string]$afterLink.WorkingDirectory
    IconLocation = [string]$afterLink.IconLocation
}
[Runtime.InteropServices.Marshal]::FinalReleaseComObject($afterLink) | Out-Null
[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null

foreach ($property in @('TargetPath', 'Arguments', 'WorkingDirectory')) {
    if ($before.$property -cne $after.$property) {
        throw "快捷方式字段发生意外变化: $property"
    }
}
if ($after.IconLocation -cne ($result.InstalledIconPath + ',0')) {
    throw '快捷方式未保存白蓝图标位置。'
}
$result

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexQuotaMonitorShellRefresh {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);
}
'@
[CodexQuotaMonitorShellRefresh]::SHChangeNotify(
    0x08000000,
    0,
    [IntPtr]::Zero,
    [IntPtr]::Zero
)
```

Expected: 输出稳定图标路径和新 `IconLocation`；没有字段变化异常；目标仍为 PowerShell 7，参数仍指向已安装的 `Start-CodexQuotaMonitor.ps1`；Shell 收到刷新通知且不删除或重建图标缓存。

- [ ] **Step 3: 通过桌面快捷方式启动或唤起程序并检查实时健康状态**

Run:

```powershell
Start-Process -FilePath 'C:\Users\335\Desktop\Codex 额度监控.lnk'
pwsh -NoProfile -File .\scripts\Test-CodexQuotaMonitorHealth.ps1 -Live
```

Expected: 快捷方式可启动或唤起现有实例；健康检查退出码为 0，状态为 `Live`，真实额度窗口仍可读取。

- [ ] **Step 4: 运行完整测试和仓库完整性检查**

Run:

```powershell
pwsh -NoProfile -File .\build\Test.ps1 -Suite All
git diff --check
git status -sb
```

Expected: 全部测试 `Result: Passed`、`FailedCount: 0`；`git diff --check` 无输出；已追踪实现文件均已提交，状态中只允许保留既有且未提交的 `.superpowers/` 预览临时目录。
