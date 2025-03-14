[Setup]
AppName=PaulXStretch
AppVersion={#SBVERSION}
MinVersion=6.1
WizardStyle=modern
DefaultDirName={autopf}\PaulXStretch
DefaultGroupName=PaulXStretch
UninstallDisplayIcon={uninstallexe}
Compression=lzma2
SolidCompression=yes
;ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputBaseFilename=PaulXStretch-{#SBVERSION}-Installer
LicenseFile=gpl-3.0.txt
SetupLogging=yes
SignTool=signtool $f
SignedUninstaller=yes
DisableReadyPage=true
DisableWelcomePage=yes
DisableDirPage=no
ShowComponentSizes=no

[Types]
Name: "full"; Description: "Full installation"
Name: "custom"; Description: "Custom installation"; Flags: iscustom


[Components]
Name: "app"; Description: "Standalone 64-bit application (.exe)"; Types: full custom; Check: Is64BitInstallMode;
;Name: "app32"; Description: "Standalone 32-bit application (.exe)"; Types: full custom; Check: not Is64BitInstallMode;
;Name: "vst2_64"; Description: "64-bit VST2 Plugin (.dll)"; Types: full custom; Check: Is64BitInstallMode;
Name: "vst3_64"; Description: "64-bit VST3 Plugin (.vst3)"; Types: full custom; Check: Is64BitInstallMode;
Name: "clap_64"; Description: "64-bit CLAP Plugin (.clap)"; Types: full custom; Check: Is64BitInstallMode;
;;Name: "aax_32"; Description: "32-bit AAX Plugin (.aaxplugin)"; Types: full custom;
Name: "aax_64"; Description: "64-bit AAX Plugin (.aaxplugin)"; Types: full custom; Check: Is64BitInstallMode;
;Name: "vst2_32"; Description: "32-bit VST2 Plugin (.dll)"; Types: full custom;
;Name: "vst3_32"; Description: "32-bit VST3 Plugin (.vst3)"; Types: full custom;

;Name: "manual"; Description: "User guide"; Types: full custom; Flags: fixed



[Files]
Source: "PaulXStretch\PaulXStretch.exe";  DestDir: "{app}" ; Check: Is64BitInstallMode; Components:app; Flags: ignoreversion signonce;
;Source: "SonoBus\Plugins\PaulXStretch.dll"; DestDir: {code:GetVST2Dir|0}; Check: Is64BitInstallMode; Components:vst2_64; Flags: ignoreversion signonce;
Source: "PaulXStretch\Plugins\VST3\PaulXStretch.vst3"; DestDir: "{commoncf64}\VST3\"; Check: Is64BitInstallMode; Components:vst3_64; Flags: ignoreversion recursesubdirs createallsubdirs ;
Source: "PaulXStretch\Plugins\CLAP\PaulXStretch.clap"; DestDir: "{commoncf64}\CLAP\"; Check: Is64BitInstallMode; Components:clap_64; Flags: ignoreversion  ;
Source: "PaulXStretch\Plugins\AAX\PaulXStretch.aaxplugin"; DestDir: "{commoncf64}\Avid\Audio\Plug-Ins\"; Check: Is64BitInstallMode; Components:aax_64; Flags: ignoreversion recursesubdirs createallsubdirs ;

;Source: "SonoBus\SonoBus32.exe"; DestDir: "{app}" ;  DestName:"SonoBus.exe"; Check: not Is64BitInstallMode;  Components:app32; Flags: ignoreversion signonce;
;Source: "SonoBus\Plugins32\SonoBus.dll"; DestDir: {code:GetVST2Dir|1}; Components:vst2_32; Flags: ignoreversion signonce;
;Source: "SonoBus\Plugins32\SonoBus.vst3"; DestDir: "{commoncf32}\VST3\"; Components:vst3_32; Flags: ignoreversion signonce ;
;;Source: "SonoBus\Plugins32\SonoBus.aaxplugin"; DestDir: "{commoncf32}\Avid\Audio\Plug-Ins\"; Components:aax_32; Flags: ignoreversion recursesubdirs createallsubdirs ;

;Source: "SonoBus\README.txt"; DestDir: "{app}"; DestName: "README.txt"; Flags: isreadme

[Tasks]

Name: "PaulXStretchQuickLaunch"; Description: "{cm:CreateQuickLaunchIcon}"; Components:app
Name: "PaulXStretchDesktop"; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked; Components:app



[Icons]
;Name: "{group}\PaulXStretch"; Filename: "{app}\PaulXStretch.exe"
;Name: "{group}\README"; Filename: "{app}\README.txt"
; Name: "{group}\Uninstall PaulXStretch"; Filename: "{app}\unins000.exe"; Components:app vst3_64 aax_64

Name: "{group}\PaulXStretch"; Filename: "{app}\PaulXStretch.exe"; WorkingDir: "{app}"; Tasks: "PaulXStretchQuickLaunch"; Components:app
Name: "{commondesktop}\PaulXStretch"; Filename: "{app}\PaulXStretch.exe"; WorkingDir: "{app}"; Tasks: "PaulXStretchDesktop"; Components:app


[Run]

Filename: "{app}\PaulXStretch.exe"; Flags: postinstall nowait unchecked skipifdoesntexist ; Description: "{cm:LaunchProgram,PaulXStretch}"; WorkingDir: "{app}"; Components:app



;[Registry]
;Root: HKCR; Subkey: "sonobus"; ValueType: "string"; ValueData: "URL:sonobus Protocol"; Flags: uninsdeletekey
;Root: HKCR; Subkey: "sonobus"; ValueType: "string"; ValueName: "URL Protocol"; ValueData: ""
;Root: HKCR; Subkey: "sonobus\DefaultIcon"; ValueType: "string"; ValueData: "{app}\SonoBus.exe,0"
;Root: HKCR; Subkey: "sonobus\shell\open\command"; ValueType: "string"; ValueData: """{app}\SonoBus.exe"" ""%1"""


[Code]
var
  OkToCopyLog : Boolean;
  VST2DirPage: TInputDirWizardPage;
  TypesComboOnChangePrev: TNotifyEvent;


procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssDone then
    OkToCopyLog := True;
end;

procedure DeinitializeSetup();
begin
  if OkToCopyLog then
    FileCopy (ExpandConstant ('{log}'), ExpandConstant ('{app}\InstallationLogFile.log'), FALSE);
  RestartReplace (ExpandConstant ('{log}'), '');
end;



procedure ComponentsListCheckChanges;
begin
  WizardForm.NextButton.Enabled := (WizardSelectedComponents(False) <> '');
end;

procedure ComponentsListClickCheck(Sender: TObject);
begin
  ComponentsListCheckChanges;
end;

procedure TypesComboOnChange(Sender: TObject);
begin
  TypesComboOnChangePrev(Sender);
  ComponentsListCheckChanges;
end;

procedure InitializeWizard;
begin
  WizardForm.ComponentsDiskSpaceLabel.Visible := False;
  WizardForm.ComponentsList.OnClickCheck := @ComponentsListClickCheck;
  TypesComboOnChangePrev := WizardForm.TypesCombo.OnChange;
  WizardForm.TypesCombo.OnChange := @TypesComboOnChange;

  VST2DirPage := CreateInputDirPage(wpSelectComponents,
  'Confirm VST2 Plugin Directory', '',
  'Select the folder in which setup should install the VST2 Plugin, then click Next.', False, '');

  VST2DirPage.Add('64-bit folder');
  // VST2DirPage.Values[0] := GetPreviousData('VST64', ExpandConstant('{reg:HKLM\SOFTWARE\VST,VSTPluginsPath|{pf}\Steinberg\VSTPlugins}\'));
  VST2DirPage.Values[0] := GetPreviousData('VST64', ExpandConstant('{pf}\Steinberg\VSTPlugins\'));
  VST2DirPage.Add('32-bit folder');
  VST2DirPage.Values[1] := GetPreviousData('VST32', ExpandConstant('{reg:HKLM\SOFTWARE\WOW6432NODE\VST,VSTPluginsPath|{pf32}\Steinberg\VSTPlugins}\'));

  If not Is64BitInstallMode then
  begin
    VST2DirPage.Values[1] := GetPreviousData('VST32', ExpandConstant('{reg:HKLM\SOFTWARE\VSTPluginsPath\VST,VSTPluginsPath|{pf}\Steinberg\VSTPlugins}\'));
    VST2DirPage.Buttons[0].Enabled := False;
    VST2DirPage.PromptLabels[0].Enabled := VST2DirPage.Buttons[0].Enabled;
    VST2DirPage.Edits[0].Enabled := VST2DirPage.Buttons[0].Enabled;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = VST2DirPage.ID then
  begin
    VST2DirPage.Buttons[0].Enabled := WizardIsComponentSelected('vst2_64');
    VST2DirPage.PromptLabels[0].Enabled := VST2DirPage.Buttons[0].Enabled;
    VST2DirPage.Edits[0].Enabled := VST2DirPage.Buttons[0].Enabled;

    VST2DirPage.Buttons[1].Enabled := WizardIsComponentSelected('vst2_32');
    VST2DirPage.PromptLabels[1].Enabled := VST2DirPage.Buttons[1].Enabled;
    VST2DirPage.Edits[1].Enabled := VST2DirPage.Buttons[1].Enabled;
  end;

  if CurPageID = wpSelectComponents then
  begin
    ComponentsListCheckChanges;
  end;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  if PageID = VST2DirPage.ID then
  begin
    If (not WizardIsComponentSelected('vst2_32')) and (not WizardIsComponentSelected('vst2_64'))then
      begin
        Result := True
      end;
  end;
end;

function GetVST2Dir(Param: string): string;
begin
    Result := VST2DirPage.Values[StrToInt(Param)];
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  SetPreviousData(PreviousDataKey, 'VST64', VST2DirPage.Values[0]);
  SetPreviousData(PreviousDataKey, 'VST32', VST2DirPage.Values[1]);
end;


[UninstallDelete]
Type: files; Name: "{app}\InstallationLogFile.log"

