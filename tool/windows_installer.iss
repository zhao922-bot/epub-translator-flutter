; Run after tool/package_windows.ps1 has bundled the VC++ runtime:
; ISCC /DAppVersion=1.4.9 tool/windows_installer.iss
#ifndef AppVersion
  #error AppVersion is required (for example /DAppVersion=1.4.9).
#endif
#define AppName "EPUB Translator"
#define AppExe "epub_translator_flutter_clean.exe"
#ifndef ReleaseDir
  #define ReleaseDir "..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6E8F9B31-179E-4E65-9397-C3E678828F59}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=zhao922-bot
AppPublisherURL=https://github.com/zhao922-bot/epub-translator-flutter
AppSupportURL=https://github.com/zhao922-bot/epub-translator-flutter/issues
AppUpdatesURL=https://github.com/zhao922-bot/epub-translator-flutter/releases
DefaultDirName={localappdata}\Programs\EPUB Translator
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\dist
OutputBaseFilename=epub-translator-flutter-v{#AppVersion}-windows-x64-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
