# Polished Quota Focus Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the quota card's font-circle selector and default WPF button chrome with a crisp vector radio control and restrained selected, hover, pressed, and keyboard-focus states.

**Architecture:** Keep selection behavior in the existing `DisplayModeController` and rebuild only the full-window presentation. `Theme.ps1` owns the exact state colors, `MainWindow.xaml` owns the reusable button template, and `WpfView.ps1` supplies selected state plus the two concentric `Ellipse` shapes. Existing snapshot rerendering continues to update theme and selection without new persistent state or event handlers.

**Tech Stack:** PowerShell 7, WPF/XAML, Pester 5.7.1, existing visual capture and installation scripts.

---

## File Map And Working-Tree Guard

- Modify `companion/Private/Theme.ps1`: add exact selector palette colors and update the window resource brushes used by the XAML template.
- Modify `companion/UI/MainWindow.xaml`: add dynamic selector brushes, a circular keyboard focus visual, and the `QuotaFocusButton` control template.
- Modify `companion/Private/WpfView.ps1`: preserve existing callbacks while rendering vector ring/dot content and selected card surfaces.
- Modify `tests/Integration/ThemeComposition.Tests.ps1`: lock the palette and XAML template contract.
- Modify `tests/Integration/WpfComposition.Tests.ps1`: lock the vector geometry, selected/unselected visuals, theme resource updates, accessibility, and click behavior.
- Generate only `outputs/visual/*.png` during visual verification; these are ignored artifacts.
- Read only the installed app path reported by existing scripts; never edit `%LOCALAPPDATA%\CodexQuotaMonitor\app` directly.

`companion/Private/WpfView.ps1` and `tests/Integration/WpfComposition.Tests.ps1` already contain user-owned, uncommitted relay text-centering changes. Preserve the `SourceKind`/`$isRelay` logic and the test named `vertically centers relay card text without changing the official card`. When committing Task 2, stage only selector hunks and verify those pre-existing hunks remain unstaged.

### Task 1: Add Theme Colors And A Circular Button Template

**Files:**
- Modify: `tests/Integration/ThemeComposition.Tests.ps1:9-47`
- Modify: `companion/Private/Theme.ps1:9-76`
- Modify: `companion/UI/MainWindow.xaml:16-66`

- [ ] **Step 1: Write failing palette and XAML contract tests**

Update the exact palette-key assertion in `ThemeComposition.Tests.ps1` to include the three selector colors immediately after `Accent`:

```powershell
@($palette.Keys) | Should -Be @(
    'Surface', 'SurfaceStrong', 'TextPrimary', 'TextSecondary', 'Accent',
    'AccentSoft', 'AccentPressed', 'SelectionSurface',
    'Track', 'Separator', 'Shadow', 'Warning', 'Danger'
)
```

Extend `uses transparent cohesive surfaces without opaque white borders` with exact values:

```powershell
$light.AccentSoft | Should -BeExactly '#244DADB3'
$light.AccentPressed | Should -BeExactly '#3D4DADB3'
$light.SelectionSurface | Should -BeExactly '#D9E4E4DE'
$dark.AccentSoft | Should -BeExactly '#2458C2C7'
$dark.AccentPressed | Should -BeExactly '#3D58C2C7'
$dark.SelectionSurface | Should -BeExactly '#D93C4B5F'
```

Add this test after the existing XAML surface test:

```powershell
It 'declares a circular quota focus template with theme-driven interaction brushes' {
    $xaml = Get-Content -LiteralPath $XamlPath -Raw

    foreach ($resourceName in @(
        'QuotaFocusRingBrush', 'QuotaFocusHoverBrush', 'QuotaFocusPressedBrush',
        'QuotaFocusKeyboardVisual', 'QuotaFocusButton'
    )) {
        $xaml | Should -Match ('x:Key="' + [regex]::Escape($resourceName) + '"')
    }
    $xaml | Should -Match 'x:Name="QuotaFocusSurface"'
    $xaml | Should -Match 'CornerRadius="12"'
    $xaml | Should -Match 'FocusVisualStyle"\s+Value="\{StaticResource QuotaFocusKeyboardVisual\}"'
}
```

- [ ] **Step 2: Run the theme test and verify the new assertions fail**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\ThemeComposition.Tests.ps1 -Output Detailed"
```

Expected: FAIL because `AccentSoft`, `AccentPressed`, and `SelectionSurface` are absent and `QuotaFocusButton` is not declared.

- [ ] **Step 3: Add exact selector colors to both theme palettes**

In each ordered palette in `Theme.ps1`, insert the following keys immediately after `Accent`:

```powershell
# Light
AccentSoft = '#244DADB3'
AccentPressed = '#3D4DADB3'
SelectionSurface = '#D9E4E4DE'

# Dark
AccentSoft = '#2458C2C7'
AccentPressed = '#3D58C2C7'
SelectionSurface = '#D93C4B5F'
```

In `Set-MonitorWindowTheme`, update the three dynamic XAML brushes before theming named controls:

```powershell
$Window.Resources['QuotaFocusRingBrush'] = ConvertTo-MonitorThemeBrush $palette.Accent
$Window.Resources['QuotaFocusHoverBrush'] = ConvertTo-MonitorThemeBrush $palette.AccentSoft
$Window.Resources['QuotaFocusPressedBrush'] = ConvertTo-MonitorThemeBrush $palette.AccentPressed
```

- [ ] **Step 4: Add the reusable XAML resources and control template**

Add these resources at the start of `Window.Resources` in `MainWindow.xaml`:

```xml
<SolidColorBrush x:Key="QuotaFocusRingBrush" Color="#FF58C2C7" />
<SolidColorBrush x:Key="QuotaFocusHoverBrush" Color="#2458C2C7" />
<SolidColorBrush x:Key="QuotaFocusPressedBrush" Color="#3D58C2C7" />

<Style x:Key="QuotaFocusKeyboardVisual">
    <Setter Property="Control.Template">
        <Setter.Value>
            <ControlTemplate TargetType="Control">
                <Ellipse Width="24"
                         Height="24"
                         HorizontalAlignment="Center"
                         VerticalAlignment="Center"
                         Stroke="{DynamicResource QuotaFocusRingBrush}"
                         StrokeThickness="1"
                         Opacity="0.75"
                         SnapsToDevicePixels="True" />
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>

<Style x:Key="QuotaFocusButton" TargetType="Button">
    <Setter Property="Width" Value="28" />
    <Setter Property="Height" Value="28" />
    <Setter Property="Padding" Value="0" />
    <Setter Property="Background" Value="Transparent" />
    <Setter Property="BorderBrush" Value="Transparent" />
    <Setter Property="BorderThickness" Value="0" />
    <Setter Property="Focusable" Value="True" />
    <Setter Property="Cursor" Value="Hand" />
    <Setter Property="FocusVisualStyle" Value="{StaticResource QuotaFocusKeyboardVisual}" />
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="Button">
                <Grid Width="28" Height="28" Background="Transparent">
                    <Border x:Name="QuotaFocusSurface"
                            Width="24"
                            Height="24"
                            HorizontalAlignment="Center"
                            VerticalAlignment="Center"
                            Background="{TemplateBinding Background}"
                            CornerRadius="12" />
                    <ContentPresenter HorizontalAlignment="Center"
                                      VerticalAlignment="Center"
                                      RecognizesAccessKey="False" />
                </Grid>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter Property="Foreground" Value="{DynamicResource QuotaFocusRingBrush}" />
                        <Setter TargetName="QuotaFocusSurface"
                                Property="Background"
                                Value="{DynamicResource QuotaFocusHoverBrush}" />
                    </Trigger>
                    <Trigger Property="IsPressed" Value="True">
                        <Setter Property="Foreground" Value="{DynamicResource QuotaFocusRingBrush}" />
                        <Setter TargetName="QuotaFocusSurface"
                                Property="Background"
                                Value="{DynamicResource QuotaFocusPressedBrush}" />
                    </Trigger>
                    <Trigger Property="IsEnabled" Value="False">
                        <Setter Property="Opacity" Value="0.45" />
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
```

The 28-pixel root preserves the hit target. Only the 24-pixel circular surface receives state color, so no rectangular system chrome remains.

- [ ] **Step 5: Run the theme test and verify it passes**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\ThemeComposition.Tests.ps1 -Output Detailed"
```

Expected: PASS with zero failed tests.

- [ ] **Step 6: Commit the clean theme/template slice**

Run:

```powershell
git add companion/Private/Theme.ps1 companion/UI/MainWindow.xaml tests/Integration/ThemeComposition.Tests.ps1
git diff --cached --check
git diff --cached --name-only
git commit -m "feat: add polished quota focus template"
```

Expected: the cached name list contains exactly the three files above; the pre-existing `WpfView.ps1` and `WpfComposition.Tests.ps1` changes remain unstaged.

### Task 2: Render The Vector Selector And Selected Card Surface

**Files:**
- Modify: `tests/Integration/WpfComposition.Tests.ps1:336-390`
- Modify: `companion/Private/WpfView.ps1:74-177`
- Modify: `companion/Private/WpfView.ps1:328-397`
- Modify: `companion/Private/WpfView.ps1:510-532`

- [ ] **Step 1: Expand the focus-control test to cover both vector states**

Replace the existing `renders accessible focus controls and marks the selected quota` test body with:

```powershell
It 'renders accessible vector focus controls and marks only the selected quota' {
    $focused = [Collections.Generic.List[string]]::new()
    $script:View = New-QuotaWindowView -XamlPath $XamlPath `
        -OnFocusRequested { param($key) $focused.Add($key) }

    & $View.RenderGroups `
        -OfficialRows @(
            (New-TestPresentationRow -Key 'official|selected'),
            (New-TestPresentationRow -Key 'official|automatic' -Label '每周额度')
        ) `
        -RelayRows @() `
        -FocusKey 'official|selected'

    $selectedCard = $View.Controls.OfficialRows.Children[0]
    $selectedCard.BorderBrush.ToString() | Should -BeExactly '#FF58C2C7'
    $selectedCard.Background.ToString() | Should -BeExactly '#D93C4B5F'
    $selectedCard.BorderThickness.Left | Should -Be 1

    $selectedButton = @(Get-TestDescendant -Root $selectedCard -Type ([Windows.Controls.Button]) -Tag 'QuotaFocus')[0]
    $selectedButton | Should -Not -BeNullOrEmpty
    $selectedButton.Style | Should -BeOfType ([Windows.Style])
    $selectedButton.Template | Should -BeOfType ([Windows.Controls.ControlTemplate])
    $selectedButton.FocusVisualStyle | Should -BeOfType ([Windows.Style])
    $selectedButton.Focusable | Should -BeTrue
    $selectedButton.Width | Should -Be 28
    $selectedButton.Height | Should -Be 28
    $selectedButton.Background.ToString() | Should -BeExactly '#2458C2C7'
    [string]$selectedButton.ToolTip | Should -BeExactly '取消迷你模式固定显示'
    [Windows.Automation.AutomationProperties]::GetName($selectedButton) |
        Should -BeExactly '取消迷你模式固定显示'

    $selectedVisual = $selectedButton.Content
    $selectedVisual | Should -BeOfType ([Windows.Controls.Grid])
    $selectedVisual.Width | Should -Be 16
    $selectedVisual.Height | Should -Be 16
    $selectedRing = @($selectedVisual.Children | Where-Object { [string]$_.Tag -eq 'QuotaFocusRing' })[0]
    $selectedDot = @($selectedVisual.Children | Where-Object { [string]$_.Tag -eq 'QuotaFocusDot' })[0]
    $selectedRing | Should -BeOfType ([Windows.Shapes.Ellipse])
    $selectedRing.Width | Should -Be 16
    $selectedRing.Height | Should -Be 16
    $selectedRing.StrokeThickness | Should -Be 1.5
    $selectedDot | Should -BeOfType ([Windows.Shapes.Ellipse])
    $selectedDot.Width | Should -Be 6
    $selectedDot.Height | Should -Be 6
    $selectedDot.Visibility | Should -Be ([Windows.Visibility]::Visible)

    $automaticCard = $View.Controls.OfficialRows.Children[1]
    $automaticCard.BorderBrush.ToString() | Should -BeExactly '#4D707A90'
    $automaticCard.Background.ToString() | Should -BeExactly '#D93A4358'
    $automaticButton = @(Get-TestDescendant -Root $automaticCard -Type ([Windows.Controls.Button]) -Tag 'QuotaFocus')[0]
    $automaticButton.Background.ToString() | Should -BeExactly '#00FFFFFF'
    $automaticButton.Foreground.ToString() | Should -BeExactly '#FFAFB8CB'
    $automaticDot = @($automaticButton.Content.Children | Where-Object { [string]$_.Tag -eq 'QuotaFocusDot' })[0]
    $automaticDot.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
    [string]$automaticButton.ToolTip | Should -BeExactly '设为迷你模式显示项'

    $selectedButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    @($focused) | Should -Be @('official|selected')
}
```

Extend `rethemes and relayouts from the existing snapshot without losing rows` immediately after `SetTheme Light`:

```powershell
$View.State.Palette.AccentSoft | Should -BeExactly '#244DADB3'
$View.Window.Resources['QuotaFocusRingBrush'].ToString() | Should -BeExactly '#FF4DADB3'
$View.Window.Resources['QuotaFocusHoverBrush'].ToString() | Should -BeExactly '#244DADB3'
$View.Window.Resources['QuotaFocusPressedBrush'].ToString() | Should -BeExactly '#3D4DADB3'
```

- [ ] **Step 2: Run the focused WPF test and verify it fails for the old glyph button**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\WpfComposition.Tests.ps1 -Output Detailed"
```

Expected: FAIL because `Content` is still the `●` string, the button has no custom style/template, and the selected card still uses `SurfaceStrong`.

- [ ] **Step 3: Pass the XAML style into each generated quota card**

Add a mandatory style parameter to `New-WpfQuotaCard`:

```powershell
[Parameter(Mandatory)]
[Windows.Style]$FocusButtonStyle,
```

After loading and validating named controls in `New-QuotaWindowView`, resolve the style once and fail clearly if the XAML contract is broken:

```powershell
$focusButtonStyle = $window.TryFindResource('QuotaFocusButton')
if ($focusButtonStyle -isnot [Windows.Style]) {
    $window.Close()
    throw "The Codex quota floating-window XAML is missing style 'QuotaFocusButton'."
}
```

Store it in view state:

```powershell
FocusButtonStyle = $focusButtonStyle
```

Pass it from `$renderPanel`:

```powershell
$card = & $state.CreateQuotaCard -PresentationRow $row -Palette $state.Palette `
    -FocusButtonStyle $state.FocusButtonStyle `
    -OnFocusRequested $focusRequest -SelectedKey $state.FocusKey
```

- [ ] **Step 4: Render the selected card and vector ring/dot content**

Use the selected surface when creating the card:

```powershell
$card.Background = & $brush $(if ($selected) { $Palette.SelectionSurface } else { $Palette.SurfaceStrong })
$card.BorderBrush = & $brush $(if ($selected) { $Palette.Accent } else { $Palette.Separator })
```

Replace the existing font-glyph button construction with:

```powershell
$focusButton = [Windows.Controls.Button]::new()
$focusButton.Style = $FocusButtonStyle
$focusButton.Margin = [Windows.Thickness]::new(6, 0, 0, 0)
$focusButton.Foreground = & $brush $(if ($selected) { $Palette.Accent } else { $Palette.TextSecondary })
$focusButton.Background = $(
    if ($selected) { & $brush $Palette.AccentSoft }
    else { [Windows.Media.Brushes]::Transparent }
)
$focusButton.Tag = 'QuotaFocus'
$focusButton.ToolTip = $(if ($selected) { '取消迷你模式固定显示' } else { '设为迷你模式显示项' })

$focusVisual = [Windows.Controls.Grid]::new()
$focusVisual.Width = 16
$focusVisual.Height = 16
$focusVisual.IsHitTestVisible = $false

$focusRing = [Windows.Shapes.Ellipse]::new()
$focusRing.Width = 16
$focusRing.Height = 16
$focusRing.StrokeThickness = 1.5
$focusRing.Tag = 'QuotaFocusRing'

$focusDot = [Windows.Shapes.Ellipse]::new()
$focusDot.Width = 6
$focusDot.Height = 6
$focusDot.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
$focusDot.VerticalAlignment = [Windows.VerticalAlignment]::Center
$focusDot.Visibility = $(
    if ($selected) { [Windows.Visibility]::Visible }
    else { [Windows.Visibility]::Collapsed }
)
$focusDot.Tag = 'QuotaFocusDot'

$ringBinding = [Windows.Data.Binding]::new('Foreground')
$ringBinding.RelativeSource = [Windows.Data.RelativeSource]::new(
    [Windows.Data.RelativeSourceMode]::FindAncestor,
    [Windows.Controls.Button],
    1
)
[Windows.Data.BindingOperations]::SetBinding(
    $focusRing,
    [Windows.Shapes.Shape]::StrokeProperty,
    $ringBinding
) | Out-Null

$dotBinding = [Windows.Data.Binding]::new('Foreground')
$dotBinding.RelativeSource = [Windows.Data.RelativeSource]::new(
    [Windows.Data.RelativeSourceMode]::FindAncestor,
    [Windows.Controls.Button],
    1
)
[Windows.Data.BindingOperations]::SetBinding(
    $focusDot,
    [Windows.Shapes.Shape]::FillProperty,
    $dotBinding
) | Out-Null

$focusVisual.Children.Add($focusRing) | Out-Null
$focusVisual.Children.Add($focusDot) | Out-Null
$focusButton.Content = $focusVisual
```

Keep the current `AutomationProperties.Name`, grid-column assignment, click delegate, `CommandParameter`, and card resource registrations immediately after this block. Do not add mouse event handlers; XAML triggers own hover and pressed states.

- [ ] **Step 5: Run both focused composition files**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\ThemeComposition.Tests.ps1, .\tests\Integration\WpfComposition.Tests.ps1 -Output Detailed"
```

Expected: both files pass with zero failures, including the pre-existing relay vertical-centering test.

- [ ] **Step 6: Stage and commit only selector hunks from the overlapping dirty files**

Run:

```powershell
git add -p -- companion/Private/WpfView.ps1 tests/Integration/WpfComposition.Tests.ps1
git diff --cached --check
git diff --cached -- companion/Private/WpfView.ps1 tests/Integration/WpfComposition.Tests.ps1
git diff -- companion/Private/WpfView.ps1 tests/Integration/WpfComposition.Tests.ps1
```

Stage only hunks containing `FocusButtonStyle`, `SelectionSurface`, `QuotaFocusRing`, `QuotaFocusDot`, and the expanded selector assertions. Leave the `$isRelay` assignment, relay vertical-alignment loop, and `vertically centers relay card text without changing the official card` test in the unstaged diff. If Git combines a selector hunk with a pre-existing hunk, split it before staging; do not accept the combined hunk.

After the cached diff contains only selector work, run:

```powershell
git commit -m "feat: polish quota focus selection"
```

Expected: the commit contains only selector implementation/tests, while `git status --short` still reports the two user-owned files as modified for their relay-centering changes.

### Task 3: Verify Visually And Install The Trial Build

**Files:**
- Verify: `tests/Integration/ThemeComposition.Tests.ps1`
- Verify: `tests/Integration/WpfComposition.Tests.ps1`
- Verify: all `tests/Unit` and `tests/Integration`
- Generate: `outputs/visual/*.png`
- Deploy through: `scripts/Install-CodexQuotaMonitor.ps1`
- Read installed status through: `scripts/Test-CodexQuotaMonitorHealth.ps1`, `scripts/Get-CodexQuotaMonitorStatus.ps1`

- [ ] **Step 1: Run the complete PowerShell suite**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All
```

Expected: all unit and integration tests pass with zero failed containers and zero failed tests.

- [ ] **Step 2: Capture the deterministic visual matrix**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\tests\Visual\Capture-QuotaMonitorMatrix.ps1
Get-ChildItem .\outputs\visual\*-full-overview.png | Sort-Object Name | Select-Object Name, Length
```

Expected: the harness refreshes 44 PNG files and lists four full-overview captures: light/dark at 100%/150%.

- [ ] **Step 3: Inspect selected and unselected controls at both scale factors**

Open these four images with the local image viewer:

```text
outputs/visual/light-100-full-overview.png
outputs/visual/light-150-full-overview.png
outputs/visual/dark-100-full-overview.png
outputs/visual/dark-150-full-overview.png
```

Confirm all of the following before installation:

- the ring is circular and centered;
- the selected dot is centered and visibly smaller than the ring;
- no blue rectangular system button appears;
- the selected card has a subtle accent border/background and does not shift layout;
- quota labels, values, progress bars, and the user-owned relay vertical-centering behavior remain intact.

- [ ] **Step 4: Install through the repository script**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Install-CodexQuotaMonitor.ps1
```

Expected: the installer copies the repository payload to the deployment output, restarts the monitor, and reports a healthy running instance. Do not edit the installed files directly.

- [ ] **Step 5: Run health and status checks against the installed instance**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Test-CodexQuotaMonitorHealth.ps1
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Get-CodexQuotaMonitorStatus.ps1
```

Expected: ordinary health is valid, installed and running are true, and status output contains only sanitized public fields.

- [ ] **Step 6: Review the final repository state without disturbing user changes**

Run:

```powershell
git log -3 --oneline --decorate
git status --short
git diff --check
```

Expected: the design, template, and selector commits are present. Only the pre-existing relay text-centering changes remain uncommitted; no generated visual or deployment files are staged.
