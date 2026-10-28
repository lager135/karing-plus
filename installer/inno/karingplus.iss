; Karing+ installer (Inno Setup 6). One exe with a wizard: folder choice, progress, finish options.
; Installing over an existing Karing+ is an update: same folder, the app and the core service are
; stopped first, settings in %APPDATA%\KaringPlus are kept.
;
;   ISCC.exe /DMyAppVersion=0.1.0_b karingplus.iss

#define MyAppName "Karing+"
#ifndef MyAppVersion
#define MyAppVersion "0.2.0_b"
#endif
#define MyAppPublisher "IceFusion"
#define MyAppURL "https://github.com/lager135/karing-plus"
#define MyAppExeName "karing.exe"
#define ServiceName "KaringPlusService"
#define ReleaseDir "..\..\app\build\windows\x64\runner\Release"

[Setup]
AppId={{DE8F1C8E-669F-45E1-816B-71CA0030B29A}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
; An update keeps the folder of the installed version and skips the folder page.
UsePreviousAppDir=yes
DisableDirPage=auto
DisableProgramGroupPage=yes
DisableWelcomePage=no
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist
OutputBaseFilename=Karing+-{#MyAppVersion}-Setup
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
CloseApplications=no
VersionInfoVersion=0.2.0.705

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
russian.UpdateWelcome=Найдена установленная версия %1 %2.%n%nМастер обновит её до %3 в той же папке. Настройки и профили сохранятся.%n%nKaring+ и его служба будут остановлены на время обновления.
english.UpdateWelcome=%1 %2 is installed.%n%nThe wizard will update it to %3 in the same folder. Settings and profiles are kept.%n%nKaring+ and its service are stopped during the update.
russian.StoppingApp=Остановка Karing+ и службы ядра...
english.StoppingApp=Stopping Karing+ and the core service...
russian.OpenReadme=Открыть README (описание и первые шаги)
english.OpenReadme=Open README (overview and first steps)

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Excludes: "app.log,karing_setting.json,remote_config.json,karing.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "README.txt"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
; Fresh copy of the app files: nothing from an earlier version stays behind.
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}\zapret"
; Leftovers of the earlier one-file installer.
Type: files; Name: "{app}\uninstall.exe"

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent runasoriginaluser
Filename: "{app}\README.txt"; Description: "{cm:OpenReadme}"; Flags: postinstall shellexec skipifsilent unchecked runasoriginaluser
; Silent update: start the app again if it was open before.
Filename: "{app}\{#MyAppExeName}"; Flags: nowait runasoriginaluser; Check: RestartAfterSilentUpdate

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#MyAppExeName}"; Flags: runhidden; RunOnceId: "KillApp"
Filename: "{sys}\sc.exe"; Parameters: "stop {#ServiceName}"; Flags: runhidden; RunOnceId: "StopService"
Filename: "{sys}\sc.exe"; Parameters: "delete {#ServiceName}"; Flags: runhidden; RunOnceId: "DeleteService"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
const
  OldUninstKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\KaringPlus';
  InnoUninstKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{DE8F1C8E-669F-45E1-816B-71CA0030B29A}_is1';

var
  PrevVersion: String;
  AppWasRunning: Boolean;

function ExecHidden(const FileName, Params: String): Integer;
var
  Code: Integer;
begin
  if not Exec(FileName, Params, '', SW_HIDE, ewWaitUntilTerminated, Code) then
    Code := -1;
  Result := Code;
end;

{ Version of an installed Karing+: this installer's own entry, or the earlier one-file installer's. }
function InstalledVersion(): String;
begin
  Result := '';
  if not RegQueryStringValue(HKLM, InnoUninstKey, 'DisplayVersion', Result) then
    RegQueryStringValue(HKLM, OldUninstKey, 'DisplayVersion', Result);
end;

function InitializeSetup(): Boolean;
begin
  PrevVersion := InstalledVersion();
  Result := True;
end;

procedure InitializeWizard();
begin
  if PrevVersion <> '' then
    WizardForm.WelcomeLabel2.Caption :=
      FmtMessage(CustomMessage('UpdateWelcome'), ['{#MyAppName}', PrevVersion, '{#MyAppVersion}']);
end;

function IsAppRunning(): Boolean;
begin
  Result := ExecHidden(ExpandConstant('{cmd}'),
    '/C tasklist /FI "IMAGENAME eq {#MyAppExeName}" /NH | find /I "{#MyAppExeName}" >nul') = 0;
end;

function IsServiceProcessRunning(): Boolean;
begin
  Result := ExecHidden(ExpandConstant('{cmd}'),
    '/C tasklist /FI "IMAGENAME eq karingService.exe" /NH | find /I "karingService.exe" >nul') = 0;
end;

{ Stops the app and the core service before files are replaced. The service process can hold
  karingService.exe for a few seconds after "sc stop", so wait until it is gone. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  I: Integer;
begin
  Result := '';
  WizardForm.PreparingLabel.Caption := CustomMessage('StoppingApp');
  AppWasRunning := IsAppRunning();
  ExecHidden(ExpandConstant('{sys}\taskkill.exe'), '/F /IM {#MyAppExeName}');
  ExecHidden(ExpandConstant('{sys}\sc.exe'), 'stop {#ServiceName}');
  for I := 1 to 30 do
  begin
    if not IsServiceProcessRunning() then
      Break;
    if I mod 4 = 0 then
      ExecHidden(ExpandConstant('{sys}\taskkill.exe'), '/F /IM karingService.exe');
    Sleep(500);
  end;
  { The app installs the service again from the new folder on the first connect. }
  ExecHidden(ExpandConstant('{sys}\sc.exe'), 'delete {#ServiceName}');
  { The earlier one-file installer registered itself separately: drop that entry. }
  if RegKeyExists(HKLM, OldUninstKey) then
    RegDeleteKeyIncludingSubkeys(HKLM, OldUninstKey);
end;

function RestartAfterSilentUpdate(): Boolean;
begin
  Result := WizardSilent() and AppWasRunning;
end;
