BeforeAll {
    if ([string]::IsNullOrEmpty($env:windir) -and -not [string]::IsNullOrEmpty($env:SystemRoot)) {
        $env:windir = $env:SystemRoot
    }
    $script:CompanionRoot = Join-Path $PSScriptRoot '..\..\companion'
    $script:XamlPath = Join-Path $script:CompanionRoot 'UI\CcSwitchImport.xaml'
    $script:ViewPath = Join-Path $script:CompanionRoot 'Private\CcSwitchImportView.ps1'
    $script:InspectorSourcePath = Join-Path $script:CompanionRoot '..\sidecar\relay-quota-host\src\cc_switch.rs'
    if (Test-Path -LiteralPath $script:ViewPath -PathType Leaf) {
        . $script:ViewPath
    }
}

Describe 'CC Switch import WPF composition' {
    BeforeEach { $script:View = $null }
    AfterEach {
        if ($null -ne $script:View) {
            & $script:View.Dispose
        }
    }

    It 'declares the accessible import dialog contract without a script binding' {
        Test-Path -LiteralPath $XamlPath -PathType Leaf | Should -BeTrue
        [xml]$xaml = Get-Content -LiteralPath $XamlPath -Raw
        $manager = [Xml.XmlNamespaceManager]::new($xaml.NameTable)
        $manager.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
        $manager.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')

        foreach ($name in @(
            'SourceList','RefreshButton','StatusText','EndpointComboBox','ConversionText',
            'ImportModeComboBox','UpdateRadioButton','CopyRadioButton','ImportButton','CancelButton'
        )) {
            $xaml.SelectSingleNode("//*[@x:Name='$name']", $manager) |
                Should -Not -BeNullOrEmpty -Because "the import dialog requires $name"
        }
        $xaml.SelectSingleNode("//w:ListBox[@x:Name='SourceList']", $manager).DisplayMemberPath |
            Should -BeExactly 'DisplayName'
        $xaml.SelectSingleNode("//w:ComboBox[@x:Name='EndpointComboBox']", $manager).IsEditable |
            Should -BeExactly 'True'
        $raw = Get-Content -LiteralPath $XamlPath -Raw
        $raw | Should -Not -Match '(?i)\{Binding\s+(?:Path\s*=\s*)?(?:Code|Script)\b'
        $raw | Should -Not -Match '(?i)DisplayMemberPath\s*=\s*"(?:Code|Script)"'
    }

    It 'gives every interactive control a nonempty automation name' {
        [xml]$xaml = Get-Content -LiteralPath $XamlPath -Raw
        $manager = [Xml.XmlNamespaceManager]::new($xaml.NameTable)
        $manager.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
        $manager.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
        foreach ($name in @(
            'SourceList','RefreshButton','EndpointComboBox','ImportModeComboBox',
            'UpdateRadioButton','CopyRadioButton','ImportButton','CancelButton'
        )) {
            $node = $xaml.SelectSingleNode("//*[@x:Name='$name']", $manager)
            $node.GetAttribute('AutomationProperties.Name') |
                Should -Not -BeNullOrEmpty
        }
    }

    It 'exposes the exact callable adapter contract and projects away raw code' {
        $script:View = New-CcSwitchImportView -XamlPath $XamlPath `
            -CustomImportPrompt { param($name) $false }
        $callable = @(
            $script:View.PSObject.Properties |
                Where-Object { $_.Value -is [scriptblock] } |
                Select-Object -ExpandProperty Name
        )
        $callable | Should -Be @(
            'ShowDialog','SetSources','GetSelection','SetSelectionDetails','SetBusy',
            'SetStatus','ConfirmCustomImport','SetCallbacks','Dispose'
        )

        $sentinel = 'VIEW_RAW_CODE_SENTINEL_86420'
        & $script:View.SetSources @([pscustomobject]@{
            SourceProviderId='source-1'; SourceAppType='codex'; DisplayName='wakaka'
            ImportStatus='Ready'; EndpointCandidates=@('https://api.wkkapi.com')
            Code=$sentinel
        })

        ($script:View.State.Sources | ConvertTo-Json -Depth 6 -Compress) |
            Should -Not -Match $sentinel
        ($script:View.Controls.SourceList.ItemsSource | ConvertTo-Json -Depth 6 -Compress) |
            Should -Not -Match $sentinel
    }

    It 'cancels ordinary closing and keeps the same window reopenable' {
        $script:View = New-CcSwitchImportView -XamlPath $XamlPath `
            -CustomImportPrompt { param($name) $false }
        $window = $script:View.Window
        $window.Show()
        $window.Close()

        $window.IsVisible | Should -BeFalse
        $window.IsLoaded | Should -BeTrue

        $dispatcher = [Windows.Threading.Dispatcher]::CurrentDispatcher
        $null = $dispatcher.BeginInvoke(
            [Action]{ $window.Hide() },
            [Windows.Threading.DispatcherPriority]::ApplicationIdle
        )
        $null = & $script:View.ShowDialog
        $script:View.State.Disposed | Should -BeFalse
    }

    It 'keeps inspector SQL on the approved usage-script and public-endpoint allowlist' {
        $source = Get-Content -LiteralPath $InspectorSourcePath -Raw
        $providerQuery = [regex]::Match(
            $source,
            'const PROVIDER_QUERY: &str = r#"(?<sql>.*?)"#;',
            [Text.RegularExpressions.RegexOptions]::Singleline
        ).Groups['sql'].Value
        $endpointQuery = [regex]::Match(
            $source,
            'const ENDPOINT_QUERY: &str = r#"(?<sql>.*?)"#;',
            [Text.RegularExpressions.RegexOptions]::Singleline
        ).Groups['sql'].Value

        $providerQuery | Should -Not -BeNullOrEmpty
        $providerQuery | Should -Match '\$\.usage_script\.code'
        $providerQuery | Should -Not -Match '(?i)settings_config|\$\.usage_script\.apiKey|SELECT\s+\*'
        $providerQuery | Should -Not -Match '(?im)^\s*meta\s*,?\s*$'
        $endpointQuery | Should -Match '(?s)SELECT\s+provider_id,\s*app_type,\s*url\s+FROM\s+provider_endpoints'
        $endpointQuery | Should -Not -Match '(?i)log|rollup|balance|cache|secret|credential|SELECT\s+\*'
    }
}
