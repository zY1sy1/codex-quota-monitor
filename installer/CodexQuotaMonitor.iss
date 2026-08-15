#ifndef SourceRoot
  #error SourceRoot must be defined
#endif
#ifndef OutputDir
  #error OutputDir must be defined
#endif
#ifndef AppVersion
  #error AppVersion must be defined
#endif
#ifndef NumericVersion
  #error NumericVersion must be defined
#endif
#ifndef OutputBaseName
  #error OutputBaseName must be defined
#endif

#define ProductName "Codex Quota Monitor"
#define ProductPublisher "Local developer"

[Setup]
AppId={{7B0B5FCB-62F5-4D3C-AF28-0EE1CA930D47}
AppName={#ProductName}
AppVersion={#AppVersion}
AppVerName={#ProductName} {#AppVersion}
AppPublisher={#ProductPublisher}
DefaultDirName={localappdata}\Programs\CodexQuotaMonitor
DefaultGroupName=Codex Quota Monitor
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=none
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
VersionInfoVersion={#NumericVersion}
VersionInfoDescription={#ProductName} Setup
VersionInfoProductName={#ProductName}
VersionInfoProductVersion={#AppVersion}
SetupIconFile={#SourceRoot}\assets\CodexQuotaMonitor.ico
UninstallDisplayIcon={app}\assets\CodexQuotaMonitor.ico
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
ChangesAssociations=no
ChangesEnvironment=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: checkedonce
Name: "startup"; Description: "Start Codex Quota Monitor when I sign in"; GroupDescription: "Startup:"; Flags: checkedonce
Name: "launchafterinstall"; Description: "Launch Codex Quota Monitor after installation"; GroupDescription: "After installation:"; Flags: checkedonce

[Files]
Source: "{#SourceRoot}\installer\Stop-Package.ps1"; Flags: dontcopy
Source: "{#SourceRoot}\payload\*"; DestDir: "{app}\payload"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceRoot}\runtime\*"; DestDir: "{app}\runtime"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceRoot}\assets\*"; DestDir: "{app}\assets"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceRoot}\installer\*"; DestDir: "{app}\installer"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceRoot}\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceRoot}\installer-manifest.json"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Codex 额度监控"; Filename: "{sys}\wscript.exe"; Parameters: "//B //NoLogo ""{app}\app\Start-CodexQuotaMonitor.vbs"" ""{app}\runtime\pwsh\pwsh.exe"" ""{app}\app\Start-CodexQuotaMonitor.ps1"""; WorkingDir: "{app}\app"; IconFilename: "{app}\assets\CodexQuotaMonitor.ico"
Name: "{group}\卸载 Codex 额度监控"; Filename: "{uninstallexe}"; IconFilename: "{app}\assets\CodexQuotaMonitor.ico"
Name: "{autodesktop}\Codex 额度监控"; Filename: "{sys}\wscript.exe"; Parameters: "//B //NoLogo ""{app}\app\Start-CodexQuotaMonitor.vbs"" ""{app}\runtime\pwsh\pwsh.exe"" ""{app}\app\Start-CodexQuotaMonitor.ps1"""; WorkingDir: "{app}\app"; IconFilename: "{app}\assets\CodexQuotaMonitor.ico"; Tasks: desktopicon

[Code]
const
  StopTimeoutSeconds = 30;

function QuoteArgument(const Value: String): String;
begin
  Result := '"' + Value + '"';
end;

function RunPowerShellScript(const PwshPath, ScriptPath, Arguments: String;
  var ResultCode: Integer): Boolean;
var
  Parameters: String;
begin
  Parameters := '-NoLogo -NoProfile -NonInteractive -Sta -File ' +
    QuoteArgument(ScriptPath);
  if Arguments <> '' then
    Parameters := Parameters + ' ' + Arguments;

  Result := Exec(PwshPath, Parameters, '', SW_HIDE, ewWaitUntilTerminated,
    ResultCode);
end;

function ExistingApplicationManifest(const ProgramRoot: String): String;
begin
  Result := AddBackslash(ProgramRoot) + 'app\CodexQuotaMonitor.psd1';
end;

function LegacyApplicationManifest(): String;
begin
  Result := ExpandConstant('{localappdata}\CodexQuotaMonitor\app\CodexQuotaMonitor.psd1');
end;

function ResolveExistingPwsh(const ProgramRoot: String): String;
var
  PrivatePwsh: String;
begin
  PrivatePwsh := AddBackslash(ProgramRoot) + 'runtime\pwsh\pwsh.exe';
  if FileExists(ExistingApplicationManifest(ProgramRoot)) then
  begin
    if FileExists(PrivatePwsh) then
      Result := PrivatePwsh
    else
      Result := '';
    exit;
  end;

  if FileExists(LegacyApplicationManifest()) then
    Result := FileSearch('pwsh.exe', GetEnv('PATH'))
  else
    Result := '';
end;

function StopExistingPackage(): Boolean;
var
  ProgramRoot: String;
  PwshPath: String;
  StopScript: String;
  Parameters: String;
  ResultCode: Integer;
begin
  Result := True;
  ProgramRoot := ExpandConstant('{app}');
  if (not FileExists(ExistingApplicationManifest(ProgramRoot))) and
     (not FileExists(LegacyApplicationManifest())) then
    exit;

  PwshPath := ResolveExistingPwsh(ProgramRoot);
  if PwshPath = '' then
  begin
    Result := False;
    exit;
  end;

  ExtractTemporaryFile('installer\Stop-Package.ps1');
  StopScript := ExpandConstant('{tmp}\installer\Stop-Package.ps1');
  Parameters := '-ProgramRoot ' + QuoteArgument(ProgramRoot) +
    ' -LocalAppData ' + QuoteArgument(ExpandConstant('{localappdata}')) +
    ' -Startup ' + QuoteArgument(ExpandConstant('{userstartup}')) +
    ' -TimeoutSeconds ' + IntToStr(StopTimeoutSeconds);

  if not RunPowerShellScript(PwshPath, StopScript, Parameters, ResultCode) then
  begin
    Result := False;
    exit;
  end;
  Result := ResultCode = 0;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not StopExistingPackage() then
    Result := 'Codex Quota Monitor is still running or could not be stopped. ' +
      'Close it from the tray and run Setup again.';
end;

procedure InstallPackage();
var
  PwshPath: String;
  ScriptPath: String;
  Parameters: String;
  ResultCode: Integer;
begin
  PwshPath := ExpandConstant('{app}\runtime\pwsh\pwsh.exe');
  ScriptPath := ExpandConstant('{app}\installer\Install-Package.ps1');
  Parameters := '-ProgramRoot ' + QuoteArgument(ExpandConstant('{app}')) +
    ' -LocalAppData ' + QuoteArgument(ExpandConstant('{localappdata}')) +
    ' -Startup ' + QuoteArgument(ExpandConstant('{userstartup}')) +
    ' -PwshPath ' + QuoteArgument(PwshPath);
  if not IsTaskSelected('startup') then
    Parameters := Parameters + ' -DisableStartup';

  if (not RunPowerShellScript(PwshPath, ScriptPath, Parameters, ResultCode)) or
     (ResultCode <> 0) then
    RaiseException('Codex Quota Monitor failed its post-install validation.');

  if not IsTaskSelected('launchafterinstall') then
  begin
    ScriptPath := ExpandConstant('{app}\installer\Stop-Package.ps1');
    Parameters := '-ProgramRoot ' + QuoteArgument(ExpandConstant('{app}')) +
      ' -LocalAppData ' + QuoteArgument(ExpandConstant('{localappdata}')) +
      ' -Startup ' + QuoteArgument(ExpandConstant('{userstartup}')) +
      ' -TimeoutSeconds ' + IntToStr(StopTimeoutSeconds);
    if (not RunPowerShellScript(PwshPath, ScriptPath, Parameters, ResultCode)) or
       (ResultCode <> 0) then
      RaiseException('Codex Quota Monitor was installed but could not be stopped.');
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    InstallPackage();
end;

procedure PreparePackageUninstall();
var
  PreserveData: Boolean;
  PwshPath: String;
  ScriptPath: String;
  Parameters: String;
  ResultCode: Integer;
begin
  PreserveData := MsgBox(
    'Keep personal settings and logs for a future reinstall?',
    mbConfirmation, MB_YESNO or MB_DEFBUTTON1) = IDYES;
  PwshPath := ExpandConstant('{app}\runtime\pwsh\pwsh.exe');
  ScriptPath := ExpandConstant('{app}\installer\Prepare-Uninstall.ps1');
  Parameters := '-ProgramRoot ' + QuoteArgument(ExpandConstant('{app}')) +
    ' -LocalAppData ' + QuoteArgument(ExpandConstant('{localappdata}')) +
    ' -Startup ' + QuoteArgument(ExpandConstant('{userstartup}'));
  if PreserveData then
    Parameters := Parameters + ' -PreserveData';

  if (not RunPowerShellScript(PwshPath, ScriptPath, Parameters, ResultCode)) or
     (ResultCode <> 0) then
  begin
    MsgBox('Codex Quota Monitor could not be stopped. Uninstall was cancelled.',
      mbError, MB_OK);
    Abort;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    PreparePackageUninstall();
end;
