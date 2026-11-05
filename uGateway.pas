unit uGateway;

interface

uses
  Winapi.Windows, System.Classes, System.SysUtils,
  uSerialPort, uTcpClient;

type
  TGatewayConfig = record
    Port: string;              // COM-порт, например 'COM5'
    Baud: Integer;
    Parity: TSerialParity;
    DataBits: Byte;
    StopBits: TSerialStopBits;
    Host: string;              // IP/имя устройства Modbus TCP
    TcpPort: Word;             // обычно 502
    ResponseTimeoutMs: Integer;
  end;

  TGatewayState = (gsRunning, gsStopped, gsError);

  TLogEvent = procedure(ASender: TObject; const AText: string) of object;
  TStateEvent = procedure(ASender: TObject; AState: TGatewayState;
    const AMessage: string) of object;

  // Рабочий поток шлюза: слушает RTU-запросы мастера на COM-порту,
  // переадресует их устройству по Modbus TCP и возвращает ответ по RTU.
  TGatewayThread = class(TThread)
  private
    FConfig: TGatewayConfig;
    FSerial: TSerialPort;
    FTcp: TTcpClient;
    FTransId: Word;
    FOnLog: TLogEvent;
    FOnState: TStateEvent;
    FRequests: Integer;
    FResponses: Integer;
    FErrors: Integer;
    function IsTerminated: Boolean;
    procedure Log(const AText: string);
    procedure LogFmt(const AFmt: string; const AArgs: array of const);
    procedure SetState(AState: TGatewayState; const AMsg: string);
    function InterFrameGapMs: DWORD;
    function ReadRtuFrame(out AFrame: TBytes): Boolean;
    procedure ProcessFrame(const AFrame: TBytes);
    function TcpExchange(const APdu: TBytes; AUnit: Byte;
      out ARespPdu: TBytes; out AErrCode: Byte): Boolean;
    procedure SendRtuException(AUnit, AFunc, AErrCode: Byte);
    procedure EnsureTcpConnected;
  protected
    procedure Execute; override;
  public
    // Поток создаётся приостановленным — запуск методом Start
    constructor Create(const AConfig: TGatewayConfig);
    destructor Destroy; override;
    property OnLog: TLogEvent read FOnLog write FOnLog;
    property OnState: TStateEvent read FOnState write FOnState;
    property Requests: Integer read FRequests;
    property Responses: Integer read FResponses;
    property Errors: Integer read FErrors;
  end;

implementation

uses
  System.Math, uModbusProto;

const
  MAX_RTU_ADU = 256; // максимальный кадр Modbus RTU
  TCP_RECONNECT_DELAY_MS = 3000;

constructor TGatewayThread.Create(const AConfig: TGatewayConfig);
begin
  inherited Create(True); // suspended
  FreeOnTerminate := False;
  FConfig := AConfig;
  FSerial := TSerialPort.Create;
  FTcp := TTcpClient.Create;
end;

destructor TGatewayThread.Destroy;
begin
  FTcp.Free;
  FSerial.Free;
  inherited;
end;

function TGatewayThread.IsTerminated: Boolean;
begin
  Result := Terminated;
end;

procedure TGatewayThread.Log(const AText: string);
var
  S: string;
  H: TLogEvent;
begin
  H := FOnLog;
  if not Assigned(H) then
    Exit;
  S := AText;
  // Копия обработчика захватывается замыканием: безопасно,
  // даже если поток к моменту вызова уже завершён
  TThread.Queue(nil,
    procedure
    begin
      H(nil, S);
    end);
end;

procedure TGatewayThread.LogFmt(const AFmt: string; const AArgs: array of const);
begin
  Log(Format(AFmt, AArgs));
end;

procedure TGatewayThread.SetState(AState: TGatewayState; const AMsg: string);
var
  H: TStateEvent;
  St: TGatewayState;
  M: string;
begin
  H := FOnState;
  if not Assigned(H) then
    Exit;
  St := AState;
  M := AMsg;
  TThread.Queue(nil,
    procedure
    begin
      H(nil, St, M);
    end);
end;

// Пауза 3,5 символа — признак конца кадра RTU (по спецификации Modbus)
function TGatewayThread.InterFrameGapMs: DWORD;
begin
  if FConfig.Baud > 19200 then
    Result := 2 // для высоких скоростей спецификация фиксирует 1,75 мс
  else
    // 11 бит на символ (старт + 8 данных + чётность + стоп), запас 1 мс
    Result := DWORD(Ceil(3.5 * 11 * 1000 / FConfig.Baud)) + 1;
end;

procedure TGatewayThread.Execute;
var
  Frame: TBytes;
begin
  try
    FSerial.Open(FConfig.Port, DWORD(FConfig.Baud), FConfig.Parity,
      FConfig.DataBits, FConfig.StopBits, InterFrameGapMs, 200);
    LogFmt('COM-порт %s открыт (%d бод)', [FConfig.Port, FConfig.Baud]);
    SetState(gsRunning, 'Работает');
    while not Terminated do
    begin
      EnsureTcpConnected;
      if Terminated then
        Break;
      if ReadRtuFrame(Frame) then
      begin
        Inc(FRequests);
        if not CheckCrc(Frame) then
        begin
          Inc(FErrors);
          Log('ОШИБКА: RX: кадр отброшен (длина/CRC): ' + BytesToHex(Frame));
        end
        else
          ProcessFrame(Frame);
      end;
    end;
    SetState(gsStopped, 'Остановлен');
  except
    on E: Exception do
    begin
      Log('ОШИБКА: ' + E.Message);
      SetState(gsError, E.Message);
    end;
  end;
end;

// Держим TCP-подключение постоянно поднятым; при обрыве — переподключаемся
procedure TGatewayThread.EnsureTcpConnected;
var
  I: Integer;
begin
  while not Terminated and not FTcp.Connected do
  begin
    try
      FTcp.Connect(FConfig.Host, FConfig.TcpPort, 3000);
      LogFmt('TCP: подключено к %s:%d', [FConfig.Host, FConfig.TcpPort]);
    except
      on E: Exception do
      begin
        LogFmt('ОШИБКА: TCP: %s. Повтор через %d с.',
          [E.Message, TCP_RECONNECT_DELAY_MS div 1000]);
        for I := 1 to TCP_RECONNECT_DELAY_MS div 100 do
        begin
          if Terminated then
            Exit;
          Sleep(100);
        end;
      end;
    end;
  end;
end;

// Накопление кадра до межкадровой паузы (тайм-аут между байтами)
function TGatewayThread.ReadRtuFrame(out AFrame: TBytes): Boolean;
var
  Buf: array[0..MAX_RTU_ADU + 3] of Byte;
  N, Total: DWORD;
begin
  Result := False;
  Total := 0;
  while not Terminated do
  begin
    N := FSerial.Read(Buf[Total], DWORD(Length(Buf)) - Total);
    if N > 0 then
    begin
      Inc(Total, N);
      if Total >= DWORD(Length(Buf)) then
      begin
        Log('ОШИБКА: RX: кадр длиннее допустимого, буфер очищен');
        FSerial.Purge;
        Inc(FErrors);
        Exit;
      end;
    end
    else if Total > 0 then
    begin
      // Пауза на линии — кадр завершён
      SetLength(AFrame, Total);
      Move(Buf[0], AFrame[0], Total);
      Exit(True);
    end;
    // Total = 0 и тайм-аут: просто новая итерация (проверка Terminated)
  end;
end;

procedure TGatewayThread.ProcessFrame(const AFrame: TBytes);
var
  UnitId, FuncCode, ErrCode: Byte;
  Pdu, RespPdu, Resp: TBytes;
  PduLen: Integer;
  Desc: string;
  Valid: Boolean;
begin
  UnitId := AFrame[0];
  FuncCode := AFrame[1];
  PduLen := Length(AFrame) - 3; // без адреса и двух байт CRC
  SetLength(Pdu, PduLen);
  Move(AFrame[1], Pdu[0], PduLen);
  // Одна строка на кадр: f03, адрес @100, количество n2, данные =[...].
  // Дамп пакета показываем только если структура PDU не распознана.
  Desc := DescribePdu(Pdu, False, Valid);
  if not Valid then
    Desc := Desc + ' | ' + BytesToHex(AFrame);
  if UnitId = 0 then
    Desc := Desc + ' (широковещ.)';
  Log('RX: ' + Desc);

  if not TcpExchange(Pdu, UnitId, RespPdu, ErrCode) then
  begin
    Inc(FErrors);
    // Мастер ждёт ответ: возвращаем шлюзовое исключение Modbus
    if UnitId <> 0 then
      SendRtuException(UnitId, FuncCode, ErrCode);
    Exit;
  end;

  Inc(FResponses);
  if UnitId = 0 then
    Exit; // широковещательный запрос — ответ мастеру не требуется

  // Ответ устройства -> кадр RTU для мастера
  SetLength(Resp, Length(RespPdu) + 1);
  Resp[0] := UnitId;
  Move(RespPdu[0], Resp[1], Length(RespPdu));
  AppendCrc(Resp);
  FSerial.Write(Resp[0], Length(Resp));
  Desc := DescribePdu(RespPdu, True, Valid);
  if not Valid then
    Desc := Desc + ' | ' + BytesToHex(Resp);
  Log('TX: ' + Desc);
end;

// PDU RTU -> транзакция Modbus TCP (MBAP + PDU) -> PDU ответа
function TGatewayThread.TcpExchange(const APdu: TBytes; AUnit: Byte;
  out ARespPdu: TBytes; out AErrCode: Byte): Boolean;
var
  Adu: TBytes;
  Hdr: array[0..5] of Byte;
  Body: TBytes;
  L, RLen: Integer;
  RTransId: Word;
begin
  Result := False;
  AErrCode := EX_GATEWAY_TARGET_NO_RESPONSE;

  Inc(FTransId);
  L := Length(APdu) + 1; // Unit ID + PDU
  SetLength(Adu, 7 + Length(APdu));
  Adu[0] := Hi(FTransId);
  Adu[1] := Lo(FTransId);
  Adu[2] := 0; // Protocol ID = 0 (Modbus)
  Adu[3] := 0;
  Adu[4] := Hi(Word(L));
  Adu[5] := Lo(Word(L));
  Adu[6] := AUnit; // адрес ведомого RTU становится Unit ID
  Move(APdu[0], Adu[7], Length(APdu));

  try
    FTcp.SendAll(Adu[0], Length(Adu));

    if not FTcp.RecvExact(Hdr[0], 6, FConfig.ResponseTimeoutMs, IsTerminated) then
    begin
      LogFmt('ОШИБКА: TCP: устройство не ответило за %d мс',
        [FConfig.ResponseTimeoutMs]);
      // Поздний ответ собьёт синхронизацию потока — переподключимся
      FTcp.Disconnect;
      Exit;
    end;

    RTransId := (Word(Hdr[0]) shl 8) or Hdr[1];
    RLen := (Hdr[4] shl 8) or Hdr[5];
    if (RLen < 2) or (RLen > 254) then
    begin
      LogFmt('ОШИБКА: TCP: некорректная длина ответа (%d), переподключение', [RLen]);
      FTcp.Disconnect;
      AErrCode := EX_GATEWAY_PATH_UNAVAILABLE;
      Exit;
    end;

    SetLength(Body, RLen);
    if not FTcp.RecvExact(Body[0], RLen, FConfig.ResponseTimeoutMs, IsTerminated) then
    begin
      Log('ОШИБКА: TCP: тайм-аут приёма тела ответа');
      FTcp.Disconnect;
      Exit;
    end;

    if RTransId <> FTransId then
      LogFmt('ОШИБКА: TCP: Transaction ID не совпадает (ждали %d, получили %d)',
        [FTransId, RTransId]);

    // Body[0] — Unit ID, далее PDU ответа
    SetLength(ARespPdu, RLen - 1);
    Move(Body[1], ARespPdu[0], RLen - 1);
    Result := True;
  except
    on E: ETcpError do
    begin
      Log('ОШИБКА: TCP: ' + E.Message);
      FTcp.Disconnect;
      AErrCode := EX_GATEWAY_PATH_UNAVAILABLE;
    end;
  end;
end;

// Исключение Modbus для мастера RTU, если обмен с устройством не удался
procedure TGatewayThread.SendRtuException(AUnit, AFunc, AErrCode: Byte);
var
  Resp: TBytes;
begin
  try
    SetLength(Resp, 3);
    Resp[0] := AUnit;
    Resp[1] := AFunc or $80;
    Resp[2] := AErrCode;
    AppendCrc(Resp);
    FSerial.Write(Resp[0], Length(Resp));
    LogFmt('TX: !f%s %s (%s)',
      [IntToHex(AFunc or $80, 2), IntToHex(AErrCode, 2), ExceptionName(AErrCode)]);
  except
    on E: Exception do
      Log('ОШИБКА: запись в COM-порт: ' + E.Message);
  end;
end;

end.
