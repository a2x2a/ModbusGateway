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
    CacheEnabled: Boolean;     // кэш значений для f03/f04
    CacheTtlMs: Integer;       // время жизни записи кэша, мс
  end;

  TGatewayState = (gsRunning, gsStopped, gsError);

  TLogEvent = procedure(ASender: TObject; const AText: string) of object;
  TStateEvent = procedure(ASender: TObject; AState: TGatewayState;
    const AMessage: string) of object;

  // Запись кэша значений регистров (ключ — unit/функция/адрес/количество)
  TCacheEntry = record
    UnitId: Byte;
    Func: Byte;
    Addr: Word;
    Qty: Word;
    Data: TBytes;   // данные ответа (после байта количества)
    Stamp: UInt64;  // GetTickCount64
  end;
  TCacheArray = array of TCacheEntry;

  // Отложенный TCP-запрос на обновление кэша
  TRefreshItem = record
    UnitId: Byte;
    Func: Byte;
    Addr: Word;
    Qty: Word;
    Pdu: TBytes;
  end;

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
    FCache: TCacheArray;
    FCacheHits: Integer;
    FRefreshQueue: array of TRefreshItem;
    FRxBuf: TBytes; // накопитель принятых байт (кадры могут идти вплотную)
    FFailCache: TCacheArray; // «отрицательный» кэш молчащих запросов
    function IsTerminated: Boolean;
    procedure Log(const AText: string);
    procedure LogFmt(const AFmt: string; const AArgs: array of const);
    procedure SetState(AState: TGatewayState; const AMsg: string);
    function InterFrameGapMs: DWORD;
    function ReadRtuFrame(out AFrame: TBytes): Boolean;
    procedure ProcessFrame(const AFrame: TBytes);
    function TcpExchange(const APdu: TBytes; AUnit: Byte;
      out ARespPdu: TBytes; out AErrCode: Byte): Boolean;
    procedure SendRtuException(AUnit, AFunc, AErrCode: Byte;
      const ASuffix: string = '');
    procedure EnsureTcpConnected;
    function CacheLookup(AUnit, AFunc: Byte; AAddr, AQty: Word;
      out AData: TBytes; out AAgeMs: Integer): Boolean;
    procedure CacheStore(AUnit, AFunc: Byte; AAddr, AQty: Word;
      const AData: TBytes);
    procedure CacheInvalidate(AUnit: Byte; AAddr, AQty: Word);
    procedure EnqueueRefresh(AUnit, AFunc: Byte; AAddr, AQty: Word;
      const APdu: TBytes);
    procedure ProcessRefreshQueue;
    function FailLookup(AUnit, AFunc: Byte; AAddr, AQty: Word;
      out AAgeMs: Integer): Boolean;
    procedure FailStore(AUnit, AFunc: Byte; AAddr, AQty: Word);
    procedure FailDelete(AUnit, AFunc: Byte; AAddr, AQty: Word);
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
    property CacheHits: Integer read FCacheHits;
  end;

implementation

uses
  System.Math, uModbusProto;

const
  MAX_RTU_ADU = 256; // максимальный кадр Modbus RTU
  TCP_RECONNECT_DELAY_MS = 3000;
  MAX_CACHE_ENTRIES = 32; // максимум записей кэша значений регистров
  MAX_REFRESH_QUEUE = 64; // максимум отложенных TCP-запросов на обновление
  FAIL_TTL_MS = 10000;    // время жизни «отрицательного» кэша (молчание устройства)

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
      // Фоновое обновление кэша — только когда линия RTU свободна
      ProcessRefreshQueue;
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

// Ожидаемая длина кадра запроса RTU (вместе с адресом и CRC) по коду функции.
// >0 — длина известна; 0 — данных пока мало; -1 — функция неизвестна.
function ExpectedReqLen(const ABuf: TBytes): Integer;
begin
  if Length(ABuf) < 2 then
    Exit(0);
  case ABuf[1] of
    $01..$06: Result := 8;
    $0F, $10:
      begin
        if Length(ABuf) < 7 then
          Exit(0);
        Result := 9 + ABuf[6]; // байт количества данных + сами данные
      end;
    $16: Result := 10;
    $17:
      begin
        if Length(ABuf) < 11 then
          Exit(0);
        Result := 13 + ABuf[10];
      end;
  else
    Result := -1;
  end;
end;

// Накопление кадра: байты копятся в FRxBuf, кадр отрезается по ожидаемой
// длине из заголовка запроса (мастер может слать кадры вплотную, без паузы
// 3,5 символа). Межкадровая пауза (тайм-аут чтения) используется только
// как запасной признак для неизвестных функций и обрывков.
function TGatewayThread.ReadRtuFrame(out AFrame: TBytes): Boolean;
var
  Buf: array[0..MAX_RTU_ADU] of Byte;
  N: DWORD;
  ExpLen, OldLen: Integer;
begin
  Result := False;
  while not Terminated do
  begin
    N := FSerial.Read(Buf[0], DWORD(Length(Buf)));
    if N > 0 then
    begin
      OldLen := Length(FRxBuf);
      SetLength(FRxBuf, OldLen + Integer(N));
      Move(Buf[0], FRxBuf[OldLen], N);
      if Length(FRxBuf) > 2 * MAX_RTU_ADU then
      begin
        Log('ОШИБКА: RX: входной буфер переполнен, очищен');
        SetLength(FRxBuf, 0);
        FSerial.Purge;
        Inc(FErrors);
      end;
    end;
    // Пытаемся отрезать полный кадр по ожидаемой длине
    ExpLen := ExpectedReqLen(FRxBuf);
    if (ExpLen > 0) and (Length(FRxBuf) >= ExpLen) then
    begin
      SetLength(AFrame, ExpLen);
      Move(FRxBuf[0], AFrame[0], ExpLen);
      if Length(FRxBuf) > ExpLen then
        Move(FRxBuf[ExpLen], FRxBuf[0], Length(FRxBuf) - ExpLen);
      SetLength(FRxBuf, Length(FRxBuf) - ExpLen);
      Exit(True);
    end;
    // Пауза на линии, а полного кадра нет: обрывок или неизвестная функция —
    // отдаём накопленное как есть (дальше его отбракует проверка CRC)
    if (N = 0) and (Length(FRxBuf) > 0) then
    begin
      AFrame := FRxBuf;
      SetLength(FRxBuf, 0);
      Exit(True);
    end;
  end;
end;

procedure TGatewayThread.ProcessFrame(const AFrame: TBytes);
var
  UnitId, FuncCode, ErrCode: Byte;
  Pdu, RespPdu, Resp, CacheData: TBytes;
  PduLen, ReqAddr, ReqQty, CacheAge, FailAge: Integer;
  Desc: string;
  Valid, IsRead: Boolean;
begin
  UnitId := AFrame[0];
  FuncCode := AFrame[1];
  PduLen := Length(AFrame) - 3; // без адреса и двух байт CRC
  SetLength(Pdu, PduLen);
  Move(AFrame[1], Pdu[0], PduLen);
  // Одна строка на кадр: f03, адрес @100, количество n2, данные [...].
  // Дамп пакета показываем только если структура PDU не распознана.
  Desc := DescribePdu(Pdu, False, Valid);
  if not Valid then
    Desc := Desc + ' | ' + BytesToHex(AFrame);
  if UnitId = 0 then
    Desc := Desc + ' (широковещ.)';
  Log('RX: ' + Desc);

  ReqAddr := 0;
  ReqQty := 0;
  IsRead := ((FuncCode = $03) or (FuncCode = $04)) and (PduLen = 5);
  if IsRead then
  begin
    ReqAddr := (Pdu[1] shl 8) or Pdu[2];
    ReqQty := (Pdu[3] shl 8) or Pdu[4];
  end;

  // «Отрицательный» кэш: этот же запрос недавно кончился тайм-аутом
  // устройства — повторно TCP не дёргаем, сразу исключение 0B. Спасает
  // от мастеров, которые безостановочно ретраят «молчащий» запрос.
  if (UnitId <> 0) and IsRead and
     FailLookup(UnitId, FuncCode, ReqAddr, ReqQty, FailAge) then
  begin
    Inc(FErrors);
    SendRtuException(UnitId, FuncCode, EX_GATEWAY_TARGET_NO_RESPONSE,
      Format(' (кэш ошибок %d мс)', [FailAge]));
    Exit;
  end;

  // Кэш значений для читающих группу регистров функций (f03/f04).
  // Есть свежая запись (в пределах TTL) — отвечаем мастеру сразу из кэша
  // и ставим TCP-запрос на обновление в очередь (без дублей по ключу);
  // очередь выполняется в паузах RTU-трафика (ProcessRefreshQueue).
  // Свежей записи нет — идём в TCP синхронно, ответ пополнит кэш.
  if FConfig.CacheEnabled and (UnitId <> 0) and IsRead then
  begin
    if CacheLookup(UnitId, FuncCode, ReqAddr, ReqQty, CacheData, CacheAge) then
    begin
      Inc(FResponses);
      Inc(FCacheHits);
      SetLength(RespPdu, 2 + Length(CacheData));
      RespPdu[0] := FuncCode;
      RespPdu[1] := Byte(Length(CacheData));
      Move(CacheData[0], RespPdu[2], Length(CacheData));
      SetLength(Resp, Length(RespPdu) + 1);
      Resp[0] := UnitId;
      Move(RespPdu[0], Resp[1], Length(RespPdu));
      AppendCrc(Resp);
      FSerial.Write(Resp[0], Length(Resp));
      Desc := DescribePdu(RespPdu, True, Valid);
      if not Valid then
        Desc := Desc + ' | ' + BytesToHex(Resp);
      LogFmt('TX: %s (кэш %d мс)', [Desc, CacheAge]);
      EnqueueRefresh(UnitId, FuncCode, ReqAddr, ReqQty, Pdu);
      Exit;
    end;
  end;

  // Запись регистров (f06/f10) вычищает из кэша (и из кэша ошибок) все
  // записи, пересекающиеся с записанным диапазоном. Записанные значения в
  // кэш НЕ кладём: у контроллера может быть своя логика на запись — кэш
  // пополняется только перечитыванием с устройства. Записи, попавшие в кэш
  // из фонового обновления, чей TCP-обмен шёл в момент записи, тоже
  // удаляются здесь (цикл однопоточный: тот обмен завершён к этому моменту).
  if (FuncCode = $06) and (PduLen = 5) then
    CacheInvalidate(UnitId, (Pdu[1] shl 8) or Pdu[2], 1)
  else if (FuncCode = $10) and (PduLen >= 5) then
    CacheInvalidate(UnitId, (Pdu[1] shl 8) or Pdu[2], (Pdu[3] shl 8) or Pdu[4]);

  if not TcpExchange(Pdu, UnitId, RespPdu, ErrCode) then
  begin
    Inc(FErrors);
    // Запоминаем «молчащий» запрос чтения — повторы в течение FAIL_TTL_MS
    // будут отклонены сразу, без блокировки шлюза секундным тайм-аутом
    if IsRead then
      FailStore(UnitId, FuncCode, ReqAddr, ReqQty);
    // Мастер ждёт ответ: возвращаем шлюзовое исключение Modbus
    if UnitId <> 0 then
      SendRtuException(UnitId, FuncCode, ErrCode);
    Exit;
  end;

  // Устройство ответило — снимаем запрос с «отрицательного» кэша, если был
  if IsRead then
    FailDelete(UnitId, FuncCode, ReqAddr, ReqQty);

  Inc(FResponses);
  if UnitId = 0 then
    Exit; // широковещательный запрос — ответ мастеру не требуется

  // Успешный ответ на чтение — обновляем кэш
  if FConfig.CacheEnabled and IsRead and
     (Length(RespPdu) >= 2) and (RespPdu[0] = FuncCode) and
     (RespPdu[1] = Length(RespPdu) - 2) then
    CacheStore(UnitId, FuncCode, (Pdu[1] shl 8) or Pdu[2],
      (Pdu[3] shl 8) or Pdu[4], Copy(RespPdu, 2, RespPdu[1]));

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

// Поиск свежей записи кэша (не старше TTL)
function TGatewayThread.CacheLookup(AUnit, AFunc: Byte; AAddr, AQty: Word;
  out AData: TBytes; out AAgeMs: Integer): Boolean;
var
  I: Integer;
  Age: UInt64;
begin
  Result := False;
  for I := 0 to High(FCache) do
    if (FCache[I].UnitId = AUnit) and (FCache[I].Func = AFunc) and
       (FCache[I].Addr = AAddr) and (FCache[I].Qty = AQty) then
    begin
      Age := GetTickCount64 - FCache[I].Stamp;
      if Age <= UInt64(FConfig.CacheTtlMs) then
      begin
        AData := FCache[I].Data;
        AAgeMs := Integer(Age);
        Exit(True);
      end;
      Exit; // запись есть, но протухла — считается промахом
    end;
end;

// Запись/обновление кэша; при переполнении вытесняется самая старая запись
procedure TGatewayThread.CacheStore(AUnit, AFunc: Byte; AAddr, AQty: Word;
  const AData: TBytes);
var
  I, Slot: Integer;
begin
  Slot := -1;
  for I := 0 to High(FCache) do
    if (FCache[I].UnitId = AUnit) and (FCache[I].Func = AFunc) and
       (FCache[I].Addr = AAddr) and (FCache[I].Qty = AQty) then
    begin
      Slot := I;
      Break;
    end;
  if Slot < 0 then // существующей записи нет
  begin
    if Length(FCache) < MAX_CACHE_ENTRIES then
    begin
      SetLength(FCache, Length(FCache) + 1);
      Slot := High(FCache);
    end
    else
    begin
      Slot := 0;
      for I := 1 to High(FCache) do
        if FCache[I].Stamp < FCache[Slot].Stamp then
          Slot := I;
    end;
  end;
  FCache[Slot].UnitId := AUnit;
  FCache[Slot].Func := AFunc;
  FCache[Slot].Addr := AAddr;
  FCache[Slot].Qty := AQty;
  FCache[Slot].Data := AData;
  FCache[Slot].Stamp := GetTickCount64;
end;

// Инвалидация кэша при записи: удаляет записи, пересекающиеся с записанным
// диапазоном [AAddr, AAddr+AQty), из кэша значений и кэша ошибок.
// AUnit = 0 (широковещательная запись) — чистим по всем ведомым.
procedure TGatewayThread.CacheInvalidate(AUnit: Byte; AAddr, AQty: Word);

  procedure PurgeRange(var AArr: TCacheArray);
  var
    I: Integer;
  begin
    I := 0;
    while I <= High(AArr) do
      if ((AUnit = 0) or (AArr[I].UnitId = AUnit)) and
         (AArr[I].Addr < AAddr + AQty) and (AAddr < AArr[I].Addr + AArr[I].Qty) then
      begin
        // сдвиг присваиванием: в записях управляемые поля (TBytes),
        // Move по ним ломает подсчёт ссылок
        for var J := I + 1 to High(AArr) do
          AArr[J - 1] := AArr[J];
        SetLength(AArr, Length(AArr) - 1);
        // без Inc(I): на место I сдвинулась следующая запись
      end
      else
        Inc(I);
  end;

begin
  PurgeRange(FCache);
  PurgeRange(FFailCache);
end;

// Постановка TCP-запроса на обновление кэша в очередь.
// Дубли по ключу (unit/функция/адрес/количество) не добавляются.
procedure TGatewayThread.EnqueueRefresh(AUnit, AFunc: Byte; AAddr, AQty: Word;
  const APdu: TBytes);
var
  I: Integer;
begin
  for I := 0 to High(FRefreshQueue) do
    if (FRefreshQueue[I].UnitId = AUnit) and (FRefreshQueue[I].Func = AFunc) and
       (FRefreshQueue[I].Addr = AAddr) and (FRefreshQueue[I].Qty = AQty) then
      Exit; // уже в очереди
  if Length(FRefreshQueue) >= MAX_REFRESH_QUEUE then
    Exit;
  SetLength(FRefreshQueue, Length(FRefreshQueue) + 1);
  with FRefreshQueue[High(FRefreshQueue)] do
  begin
    UnitId := AUnit;
    Func := AFunc;
    Addr := AAddr;
    Qty := AQty;
    Pdu := APdu;
  end;
end;

// Фоновое выполнение очереди обновлений кэша — только когда линия RTU
// свободна. Выполняется по одному запросу, не прерывая текущий TCP-обмен;
// пришедший RTU-трафик приоритетнее (проверка входного буфера порта).
procedure TGatewayThread.ProcessRefreshQueue;
var
  Item: TRefreshItem;
  RespPdu: TBytes;
  ErrCode: Byte;
  Desc: string;
  Valid: Boolean;
begin
  while (Length(FRefreshQueue) > 0) and not Terminated do
  begin
    if FSerial.InputCount > 0 then
      Exit; // RTU-запрос мастера приоритетнее фонового обновления
    Item := FRefreshQueue[0];
    // сдвиг присваиванием: в записи есть TBytes, Move ломает подсчёт ссылок
    for var J := 1 to High(FRefreshQueue) do
      FRefreshQueue[J - 1] := FRefreshQueue[J];
    SetLength(FRefreshQueue, Length(FRefreshQueue) - 1);

    if TcpExchange(Item.Pdu, Item.UnitId, RespPdu, ErrCode) then
    begin
      // Кэшируем только корректный ответ (не исключение, длина сошлась)
      if (Length(RespPdu) >= 2) and (RespPdu[0] = Item.Func) and
         (RespPdu[1] = Length(RespPdu) - 2) then
      begin
        CacheStore(Item.UnitId, Item.Func, Item.Addr, Item.Qty,
          Copy(RespPdu, 2, RespPdu[1]));
        Desc := DescribePdu(RespPdu, True, Valid);
        Log('КЭШ: обновлён: ' + Desc);
      end
      else
        Log('КЭШ: ответ устройства не распознан, запись не обновлена');
    end
    else
    begin
      Inc(FErrors);
      Log('ОШИБКА: КЭШ: обновление не удалось, запись оставлена');
    end;
  end;
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
procedure TGatewayThread.SendRtuException(AUnit, AFunc, AErrCode: Byte;
  const ASuffix: string);
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
    LogFmt('TX: !f%s %s (%s)%s',
      [IntToHex(AFunc or $80, 2), IntToHex(AErrCode, 2),
       ExceptionName(AErrCode), ASuffix]);
  except
    on E: Exception do
      Log('ОШИБКА: запись в COM-порт: ' + E.Message);
  end;
end;

// --- «Отрицательный» кэш: запросы чтения, на которые устройство молчит ---
// TTL фиксированный (FAIL_TTL_MS); по истечении — один пробный запрос в TCP.

function TGatewayThread.FailLookup(AUnit, AFunc: Byte; AAddr, AQty: Word;
  out AAgeMs: Integer): Boolean;
var
  I: Integer;
  Age: UInt64;
begin
  Result := False;
  for I := 0 to High(FFailCache) do
    if (FFailCache[I].UnitId = AUnit) and (FFailCache[I].Func = AFunc) and
       (FFailCache[I].Addr = AAddr) and (FFailCache[I].Qty = AQty) then
    begin
      Age := GetTickCount64 - FFailCache[I].Stamp;
      if Age <= FAIL_TTL_MS then
      begin
        AAgeMs := Integer(Age);
        Exit(True);
      end;
      Exit; // протухло — считается промахом, пойдёт пробный запрос в TCP
    end;
end;

procedure TGatewayThread.FailStore(AUnit, AFunc: Byte; AAddr, AQty: Word);
var
  I, Slot: Integer;
begin
  Slot := -1;
  for I := 0 to High(FFailCache) do
    if (FFailCache[I].UnitId = AUnit) and (FFailCache[I].Func = AFunc) and
       (FFailCache[I].Addr = AAddr) and (FFailCache[I].Qty = AQty) then
    begin
      Slot := I;
      Break;
    end;
  if Slot < 0 then
  begin
    if Length(FFailCache) < MAX_CACHE_ENTRIES then
    begin
      SetLength(FFailCache, Length(FFailCache) + 1);
      Slot := High(FFailCache);
    end
    else
    begin
      Slot := 0;
      for I := 1 to High(FFailCache) do
        if FFailCache[I].Stamp < FFailCache[Slot].Stamp then
          Slot := I;
    end;
  end;
  FFailCache[Slot].UnitId := AUnit;
  FFailCache[Slot].Func := AFunc;
  FFailCache[Slot].Addr := AAddr;
  FFailCache[Slot].Qty := AQty;
  FFailCache[Slot].Data := nil;
  FFailCache[Slot].Stamp := GetTickCount64;
end;

procedure TGatewayThread.FailDelete(AUnit, AFunc: Byte; AAddr, AQty: Word);
var
  I: Integer;
begin
  for I := 0 to High(FFailCache) do
    if (FFailCache[I].UnitId = AUnit) and (FFailCache[I].Func = AFunc) and
       (FFailCache[I].Addr = AAddr) and (FFailCache[I].Qty = AQty) then
    begin
      // сдвиг присваиванием: в записи есть TBytes, Move ломает подсчёт ссылок
      for var J := I + 1 to High(FFailCache) do
        FFailCache[J - 1] := FFailCache[J];
      SetLength(FFailCache, Length(FFailCache) - 1);
      Exit;
    end;
end;

end.
