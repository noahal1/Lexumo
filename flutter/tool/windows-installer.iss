; Inno Setup script for the Lexumo Windows installer.
;
; Consumed by the release workflow, which builds the Flutter Windows bundle
; first, then runs:
;     iscc tool/windows-installer.iss /DAppVersion=0.2.25 /DAppBuild=26
; The two defines exist because the version lives in pubspec.yaml, which Inno
; cannot read; a missing or empty define fails the compile, so a tag/pubspec
; mismatch cannot ship an installer with the wrong version stamped in
; Add/Remove Programs.
;
; Why an installer at all when the exe runs portable: a bare Release folder
; needs the VC++ runtime DLLs beside it, and users who installed 0.2.x by
; hand have no uninstall entry. Setup names those files itself and writes the
; uninstaller — the two things copying a folder cannot do.

#ifndef AppVersion
  #error "Pass /DAppVersion=<name> from pubspec.yaml's version line"
#endif
#ifndef AppBuild
  #error "Pass /DAppBuild=<code> from pubspec.yaml's version line"
#endif

#define AppName "Lexumo"
#define AppExe "lexumo.exe"

[Setup]
AppId={{8F4B6A52-9C1E-4D3A-B7E2-LEXUMO0001}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion} ({#AppBuild})
AppPublisher=noahal1
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
OutputDir=..\build\installer
OutputBaseFilename=lexumo-{#AppVersion}-{#AppBuild}-setup
Compression=lzma2/max
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
; The app writes nothing into its own directory (data lives in %APPDATA%), so
; a per-user install is unnecessary; admin rights match {autopf}'s ACLs.
PrivilegesRequired=admin
; Modern Windows look; no shortcut-shaped wizard noise.
WizardStyle=modern
UninstallDisplayIcon={app}\{#AppExe}

[Languages]
; ChineseSimplified.isl is not part of the Inno Setup installer itself (only
; Default.isl ships); it lives in the upstream Languages repo, so the workflow
; fetches it beside the script before running iscc. Name must stay lowercase
; with the isl extension — iscc resolves relative to the script's directory.
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
    GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole Release bundle: exe, DLLs and the data/ folder Flutter requires.
; recurse is what picks up icudtl.dat and the subdirectories; missing files
; here fail at compile time, which is the cheapest place to find out.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; \
    Flags: nowait postinstall skipifsilent
