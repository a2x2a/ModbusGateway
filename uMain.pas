unit uMain;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls,
  uGateway, uSerialPort;

type
  TfmMain = class(TForm)
    gbCom: TGroupBox;
    lbPort: TLabel;
    cbPort: TComboBox;
    btnRefreshPorts: TButton;
    lbBaud: TLabel;
    cbBaud: TComboBox;
    lbDataBits: TLabel;
    cbDataBits: TComboBox;
    lbParity: TLabel;
    cbParity: TComboBox;
    lbStopBits: TLabel;
    cbStopBits: TComboBox;
    gbTcp: TGroupBox;
    lbHost: TLabel;
    edHost: TEdit;
    lbTcpPort: TLabel;
    edPort: TEdit;
    lbTimeout: TLabel;
    edTimeout: TEdit;
    lbHint: TLabel;
    btnStart: TButton;
    shpStatus: TShape;
    lbStatus: TLabel;
    lbStats: TLabel;
    gbLog: TGroupBox;
    memLog: TMemo;
    chkLog: TCheckBox;
    btnClearLog: TButton;
    btnSaveLog: TButton;
    dlgSave: TSaveDialog;
    tmrUi: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure btnRefreshPortsClick(Sender: TObject);
    procedure btnStartClick(Sender: TObject);
    procedure btnClearLogClick(Sender: TObject);
    procedure btnSaveLogClick(Sender: TObject);
    procedure tmrUiTimer(Sender: TObject);
  private
    FThread: TGatewayThread;
    FState: TGatewayState;
    FStateMsg: string;
    procedure RefreshPorts;
    procedure ThreadLog(ASender: TObject; const AText: string);
    procedure ThreadState(ASender: TObject; AState: TGatewayState;
      const AMessage: string);
    procedure AppendLog(const AText: string);
    procedure SetConfigEnabled(AEnabled: Boolean);
    procedure StopGateway;
    procedure LoadSettings;
    procedure SaveSettings;
  end;

var
  fmMain: TfmMain;

implementation

{$R *.dfm}

uses
  System.Math, System.Win.Registry, System.IniFiles;

const
  MAX_LOG_LINES = 5000;

procedure TfmMain.FormCreate(Sender: TObject);
begin
  FState := gsStopped;
  FStateMsg := 'Остановлен';
  RefreshPorts;
  LoadSettings;
  tmrUiTimer(nil);
end;

procedure TfmMain.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  StopGateway;
  SaveSettings;
end;

// Список доступных COM-портов из реестра
procedure TfmMain.RefreshPorts;
var
  Reg: TRegistry;
  Names: TStringList;
  I, Idx: Integer;
  Prev: string;
begin
  Prev := cbPort.Text;
  cbPort.Items.BeginUpdate;
  try
    cbPort.Items.Clear;
    Reg := TRegistry.Create(KEY_READ);
    try
      Reg.RootKey := HKEY_LOCAL_MACHINE;
      if Reg.OpenKeyReadOnly('HARDWARE\DEVICEMAP\SERIALCOMM') then
      begin
        Names := TStringList.Create;
        try
          Reg.GetValueNames(Names);
          for I := 0 to Names.Count - 1 do
            cbPort.Items.Add(Reg.ReadString(Names[I]));
        finally
          Names.Free;
        end;
        Reg.CloseKey;
      end;
    finally
      Reg.Free;
    end;
  finally
    cbPort.Items.EndUpdate;
  end;
  Idx := cbPort.Items.IndexOf(Prev);
  if Idx >= 0 then
    cbPort.ItemIndex := Idx
  else if cbPort.Items.Count > 0 then
    cbPort.ItemIndex := 0;
end;

procedure TfmMain.btnRefreshPortsClick(Sender: TObject);
begin
  RefreshPorts;
end;

procedure TfmMain.btnStartClick(Sender: TObject);
var
  Cfg: TGatewayConfig;
  Baud, TcpPort, Timeout: Integer;
begin

  if FThread <> nil then
  begin
    StopGateway;
    Exit;
  end;

  if cbPort.ItemIndex < 0 then
  begin
    MessageBox(Handle, 'Выберите COM-порт.', 'Параметры', MB_ICONWARNING);
    Exit;
  end;
  if not TryStrToInt(Trim(cbBaud.Text), Baud) or (Baud <= 0) then
  begin
    MessageBox(Handle, 'Некорректная скорость порта.', 'Параметры', MB_ICONWARNING);
    Exit;
  end;
  if Trim(edHost.Text) = '' then
  begin
    MessageBox(Handle, 'Укажите IP-адрес устройства Modbus TCP.',
      'Параметры', MB_ICONWARNING);
    Exit;
  end;
  TcpPort := StrToIntDef(Trim(edPort.Text), 0);
  if (TcpPort < 1) or (TcpPort > 65535) then
  begin
    MessageBox(Handle, 'Порт TCP должен быть от 1 до 65535.',
      'Параметры', MB_ICONWARNING);
    Exit;
  end;
  Timeout := StrToIntDef(Trim(edTimeout.Text), 0);
  if (Timeout < 100) or (Timeout > 60000) then
  begin
    MessageBox(Handle, 'Тайм-аут ответа должен быть от 100 до 60000 мс.',
      'Параметры', MB_ICONWARNING);
    Exit;
  end;

  Cfg.Port := cbPort.Text;
  Cfg.Baud := Baud;
  Cfg.Parity := TSerialParity(cbParity.ItemIndex);
  if cbDataBits.ItemIndex = 1 then
    Cfg.DataBits := 7
  else
    Cfg.DataBits := 8;
  Cfg.StopBits := TSerialStopBits(cbStopBits.ItemIndex);
  Cfg.Host := Trim(edHost.Text);
  Cfg.TcpPort := Word(TcpPort);
  Cfg.ResponseTimeoutMs := Timeout;

  FState := gsRunning;
  FStateMsg := 'Запуск…';
  FThread := TGatewayThread.Create(Cfg);
  FThread.OnLog := ThreadLog;
  FThread.OnState := ThreadState;
  FThread.Start;

  SetConfigEnabled(False);
  btnStart.Caption := 'Стоп';
  AppendLog('--- Шлюз запущен ---');
end;

procedure TfmMain.StopGateway;
begin
  if FThread <> nil then
  begin
    FThread.OnLog := nil;
    FThread.OnState := nil;
    FThread.Terminate;
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  SetConfigEnabled(True);
  btnStart.Caption := 'Старт';
  if FState <> gsError then
  begin
    FState := gsStopped;
    FStateMsg := 'Остановлен';
  end;
  AppendLog('--- Шлюз остановлен ---');
end;

procedure TfmMain.SetConfigEnabled(AEnabled: Boolean);
begin
  gbCom.Enabled := AEnabled;
  gbTcp.Enabled := AEnabled;
end;

procedure TfmMain.ThreadLog(ASender: TObject; const AText: string);
begin
  // Логирование по запросу: обычные строки — только при включённом журнале,
  // ошибки — всегда
  if chkLog.Checked or AText.StartsWith('ОШИБКА') then
    AppendLog(AText);
end;

procedure TfmMain.ThreadState(ASender: TObject; AState: TGatewayState;
  const AMessage: string);
begin
  FState := AState;
  FStateMsg := AMessage;
end;

procedure TfmMain.AppendLog(const AText: string);
begin
  memLog.Lines.BeginUpdate;
  try
    while memLog.Lines.Count >= MAX_LOG_LINES do
      memLog.Lines.Delete(0);
    memLog.Lines.Add(FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + AText);
  finally
    memLog.Lines.EndUpdate;
  end;
  memLog.SelStart := Length(memLog.Text);
  memLog.Perform(EM_SCROLLCARET, 0, 0);
end;

procedure TfmMain.btnClearLogClick(Sender: TObject);
begin
  memLog.Clear;
end;

procedure TfmMain.btnSaveLogClick(Sender: TObject);
begin
  if dlgSave.Execute then
  begin
    try
      memLog.Lines.SaveToFile(dlgSave.FileName, TEncoding.UTF8);
    except
      on E: Exception do
        MessageBox(Handle, PChar('Не удалось сохранить файл: ' + E.Message),
          'Журнал', MB_ICONERROR);
    end;
  end;
end;

procedure TfmMain.tmrUiTimer(Sender: TObject);
begin
  case FState of
    gsRunning: shpStatus.Brush.Color := clLime;
    gsStopped: shpStatus.Brush.Color := clSilver;
    gsError: shpStatus.Brush.Color := clRed;
  end;
  lbStatus.Caption := FStateMsg;
  if FThread <> nil then
    lbStats.Caption := Format('Запросов: %d   Ответов: %d   Ошибок: %d',
      [FThread.Requests, FThread.Responses, FThread.Errors])
  else
    lbStats.Caption := '';

  // Поток завершился сам (ошибка): возвращаем UI в состояние "остановлен",
  // текст ошибки остаётся в строке состояния
  if (FThread <> nil) and FThread.Finished then
  begin
    FThread.OnLog := nil;
    FThread.OnState := nil;
    FThread.WaitFor;
    FreeAndNil(FThread);
    SetConfigEnabled(True);
    btnStart.Caption := 'Старт';
  end;
end;

procedure TfmMain.LoadSettings;
var
  Ini: TIniFile;
  S: string;
  Idx: Integer;
begin
  Ini := TIniFile.Create(ChangeFileExt(ParamStr(0), '.ini'));
  try
    S := Ini.ReadString('Gateway', 'Port', '');
    Idx := cbPort.Items.IndexOf(S);
    if Idx >= 0 then
      cbPort.ItemIndex := Idx;
    cbBaud.Text := Ini.ReadString('Gateway', 'Baud', '9600');
    cbParity.ItemIndex := EnsureRange(Ini.ReadInteger('Gateway', 'Parity', 0), 0, 4);
    cbDataBits.ItemIndex := EnsureRange(Ini.ReadInteger('Gateway', 'DataBits', 0), 0, 1);
    cbStopBits.ItemIndex := EnsureRange(Ini.ReadInteger('Gateway', 'StopBits', 0), 0, 2);
    edHost.Text := Ini.ReadString('Gateway', 'Host', '192.168.0.10');
    edPort.Text := Ini.ReadString('Gateway', 'TcpPort', '502');
    edTimeout.Text := Ini.ReadString('Gateway', 'Timeout', '1000');
    chkLog.Checked := Ini.ReadBool('Gateway', 'LogEnabled', True);
  finally
    Ini.Free;
  end;
end;

procedure TfmMain.SaveSettings;
var
  Ini: TIniFile;
begin
  try
    Ini := TIniFile.Create(ChangeFileExt(ParamStr(0), '.ini'));
    try
      Ini.WriteString('Gateway', 'Port', cbPort.Text);
      Ini.WriteString('Gateway', 'Baud', cbBaud.Text);
      Ini.WriteInteger('Gateway', 'Parity', cbParity.ItemIndex);
      Ini.WriteInteger('Gateway', 'DataBits', cbDataBits.ItemIndex);
      Ini.WriteInteger('Gateway', 'StopBits', cbStopBits.ItemIndex);
      Ini.WriteString('Gateway', 'Host', edHost.Text);
      Ini.WriteString('Gateway', 'TcpPort', edPort.Text);
      Ini.WriteString('Gateway', 'Timeout', edTimeout.Text);
      Ini.WriteBool('Gateway', 'LogEnabled', chkLog.Checked);
    finally
      Ini.Free;
    end;
  except
    // Не мешаем закрытию программы, если INI недоступен для записи
  end;
end;

end.

