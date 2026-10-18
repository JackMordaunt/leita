; Leita's Windows installer, built by release.yml's Windows job with Inno
; Setup's ISCC from the tree the zip is made from, so the two hold the same
; files. It is given what varies through the environment, since a quoted
; /D define does not survive Git Bash's argument handling:
;
;   LEITA_PACK     the folder holding leita.exe, app\Leita.exe, SDL3.dll,
;                  accesskit.dll, LICENSE.md and, once card 545 adds it,
;                  THIRD_PARTY.md
;   LEITA_VERSION  the release's name, v1.2.0 or v1.2.0-rc1
;   LEITA_NUMBER   its numbers alone, four of them, 1.2.0.0, for the file's
;                  version resource, which takes nothing else
;   LEITA_OUT      the folder the installer is written to
;   LEITA_OUTNAME  its name without .exe
;
; A silent uninstall (unins000.exe /SILENT) keeps the person's settings and the
; hourly task, as the question below does by default; /REMOVEDATA removes both.

#define PackDir GetEnv("LEITA_PACK")
#define ReleaseName GetEnv("LEITA_VERSION")
#define ReleaseNumber GetEnv("LEITA_NUMBER")
#define OutDir GetEnv("LEITA_OUT")
#define OutFile GetEnv("LEITA_OUTNAME")
#if PackDir == "" || ReleaseName == "" || ReleaseNumber == "" || OutDir == "" || OutFile == ""
  #error LEITA_PACK, LEITA_VERSION, LEITA_NUMBER, LEITA_OUT and LEITA_OUTNAME must all be set
#endif
#if !FileExists(PackDir + "\leita.exe") || !FileExists(PackDir + "\app\Leita.exe") || !FileExists(PackDir + "\app\SDL3.dll") || !FileExists(PackDir + "\app\accesskit.dll")
  #error LEITA_PACK lacks leita.exe, app\Leita.exe, app\SDL3.dll or app\accesskit.dll
#endif

; The id Windows files toasts and the taskbar group under. It is the one the
; programs set for themselves (appid/appid_windows.odin) and alert/notify.odin
; names; the three must agree.
#define AppUserModelID "Librium.Leita"

[Setup]
; Fixed for good: it is how a later installer finds this one to replace it.
AppId={{E7EECE0A-D9C5-40AC-8BCD-12145CD677DB}
AppName=Leita
AppVersion={#ReleaseName}
AppPublisher=Librium LLC
AppPublisherURL=https://mordaunt.dev/leita
AppSupportURL=https://mordaunt.dev/leita
VersionInfoVersion={#ReleaseNumber}
VersionInfoProductName=Leita
VersionInfoDescription=Leita setup
VersionInfoCopyright=Copyright Librium LLC
; Program Files, so the machine's own administrator installs it for everyone.
DefaultDirName={autopf}\Leita
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; 1809, the first Windows 10 with conhost --headless, which the hourly task
; runs leita.exe through (schedule/task.odin).
MinVersion=10.0.17763
DisableProgramGroupPage=yes
; Both the PATH task and the uninstaller change the environment.
ChangesEnvironment=yes
UninstallDisplayName=Leita
UninstallDisplayIcon={app}\app\Leita.exe
OutputDir={#OutDir}
OutputBaseFilename={#OutFile}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "addtopath"; Description: "Add leita to the PATH, to run it from a terminal"; Flags: unchecked

[Files]
Source: "{#PackDir}\leita.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackDir}\LICENSE.md"; DestDir: "{app}"; Flags: ignoreversion
#if FileExists(PackDir + "\THIRD_PARTY.md")
Source: "{#PackDir}\THIRD_PARTY.md"; DestDir: "{app}"; Flags: ignoreversion
#endif
; The window's folder: macOS and Windows fold case, so Leita.exe cannot sit
; beside leita.exe, and the two DLLs it loads must sit beside it.
Source: "{#PackDir}\app\Leita.exe"; DestDir: "{app}\app"; Flags: ignoreversion
Source: "{#PackDir}\app\SDL3.dll"; DestDir: "{app}\app"; Flags: ignoreversion
Source: "{#PackDir}\app\accesskit.dll"; DestDir: "{app}\app"; Flags: ignoreversion

[Icons]
; Windows shows a toast only for an application it knows, and knows one by a
; Start menu shortcut that carries its AppUserModelID: the toast then reads
; Leita, not PowerShell.
Name: "{autoprograms}\Leita"; Filename: "{app}\app\Leita.exe"; AppUserModelID: "{#AppUserModelID}"

[Registry]
; The same id with its name, so a toast says Leita even where the shortcut
; has been moved or deleted.
Root: HKLM; Subkey: "SOFTWARE\Classes\AppUserModelId\{#AppUserModelID}"; ValueType: string; ValueName: "DisplayName"; ValueData: "Leita"; Flags: uninsdeletekey
; The PATH is machine-wide since the install is. RemoveFromPath takes the
; folder out again, which Inno cannot do for an edit of a list.
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}"; Tasks: addtopath; Check: PathLacksApp

[Run]
; As the person who ran setup, not the administrator it elevated to.
Filename: "{app}\app\Leita.exe"; Description: "Open Leita"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
const
  EnvironmentKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';

var
  RemoveData: Boolean;

// PathLacksApp is whether the machine's PATH does not yet name the install folder.
function PathLacksApp: Boolean;
var
  Path: string;
begin
  if not RegQueryStringValue(HKLM, EnvironmentKey, 'Path', Path) then
    Result := True
  else
    Result := Pos(';' + Lowercase(ExpandConstant('{app}')) + ';', ';' + Lowercase(Path) + ';') = 0;
end;

// RemoveFromPath takes the install folder out of the machine's PATH, leaving
// the rest of it as it was, and says in the uninstall log (/LOG) what it read
// and wrote, since a PATH left behind is otherwise silent.
procedure RemoveFromPath;
var
  Path, Padded, Dir: string;
  At: Integer;
begin
  if not RegQueryStringValue(HKLM, EnvironmentKey, 'Path', Path) then
  begin
    Log('RemoveFromPath: no machine Path value to read');
    Exit;
  end;
  Dir := ExpandConstant('{app}');
  Padded := ';' + Path + ';';
  At := Pos(';' + Lowercase(Dir) + ';', Lowercase(Padded));
  if At = 0 then
  begin
    Log('RemoveFromPath: ' + Dir + ' is not in ' + Path);
    Exit;
  end;
  // The semicolon before the folder goes with it; the one after stays.
  Delete(Padded, At, Length(Dir) + 1);
  if Length(Padded) <= 2 then
    Path := ''
  else
    Path := Copy(Padded, 2, Length(Padded) - 2);
  if RegWriteExpandStringValue(HKLM, EnvironmentKey, 'Path', Path) then
    Log('RemoveFromPath: wrote ' + Path)
  else
    Log('RemoveFromPath: could not write the machine Path');
end;

function HasSwitch(Name: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), Name) = 0 then
      Result := True;
end;

// InitializeUninstall asks whether to remove what leita made for the person:
// the hourly task, and the settings and history in their local data folder.
// Neither is Setup's to remove unasked, so the answer is no unless they say
// yes, or a silent uninstall is given /REMOVEDATA.
function InitializeUninstall: Boolean;
begin
  Result := True;
  if HasSwitch('/REMOVEDATA') then
    RemoveData := True
  else if not UninstallSilent then
    RemoveData := SuppressibleMsgBox(
      'Also remove the hourly scan task and Leita''s settings and history?' + #13#10 + #13#10 +
      'Choose No to keep them, for a later install.',
      mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Code: Integer;
begin
  case CurUninstallStep of
    usUninstall:
      begin
        // Taken off here as well as below, which only repeats it harmlessly:
        // the folder is off the PATH as soon as its files start to go.
        RemoveFromPath;
        // Before the files go: leita.exe takes its own task out of Task
        // Scheduler, as it was put there, and records that monitoring is off.
        if RemoveData then
          Exec(ExpandConstant('{app}\leita.exe'), 'monitor off', '', SW_HIDE, ewWaitUntilTerminated, Code);
      end;
    usPostUninstall:
      begin
        RemoveFromPath;
        if RemoveData then
          DelTree(ExpandConstant('{localappdata}\leita'), True, True, True);
      end;
  end;
end;
