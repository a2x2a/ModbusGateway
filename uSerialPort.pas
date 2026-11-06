unit uSerialPort;

interface

uses
  Winapi.Windows, System.SysUtils;

type
  TSerialParity = (spNone, spOdd, spEven, spMark, spSpace);
  TSerialStopBits = (ssbOne, ssbOneHalf, ssbTwo);

  // Простая обёртка над COM-портом WinAPI: без сторонних компонентов
  TSerialPort = class
  private
    FHandle: THandle;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Open(const APort: string; ABaud: DWORD; AParity: TSerialParity;
      ADataBits: Byte; AStopBits: TSerialStopBits;
      AInterByteTimeoutMs, AReadTimeoutMs: DWORD);
    procedure Close;
    function IsOpen: Boolean;
    // Возвращает число прочитанных байт; 0 — тайм-аут (пауза на линии)
    function Read(var ABuf; AMax: DWORD): DWORD;
    procedure Write(const ABuf; ALen: DWORD);
    procedure Purge;
    // Сколько байт уже лежит во входном буфере порта
    function InputCount: DWORD;
  end;

implementation

// В Delphi 13 константы битовых флагов DCB не экспортируются из
// Winapi.Windows — объявляем их здесь (значения из winbase.h)
const
  dcbfBinary          = $0001;
  dcbfParity          = $0002;
  dcbfOutxCtsFlow     = $0004;
  dcbfOutxDsrFlow     = $0008;
  dcbfDsrSensitivity  = $0040;
  dcbfOutX            = $0100;
  dcbfInX             = $0200;
  dcbfErrorChar       = $0400;
  dcbfNull            = $0800;
  dcbfAbortOnError    = $4000;

constructor TSerialPort.Create;
begin
  inherited Create;
  FHandle := INVALID_HANDLE_VALUE;
end;

destructor TSerialPort.Destroy;
begin
  Close;
  inherited;
end;

procedure TSerialPort.Open(const APort: string; ABaud: DWORD;
  AParity: TSerialParity; ADataBits: Byte; AStopBits: TSerialStopBits;
  AInterByteTimeoutMs, AReadTimeoutMs: DWORD);
var
  Dcb: TDCB;
  Tm: TCommTimeouts;
begin
  Close;
  // Префикс \\.\ нужен для портов с номером больше 9
  FHandle := CreateFile(PChar('\\.\' + APort), GENERIC_READ or GENERIC_WRITE,
    0, nil, OPEN_EXISTING, 0, 0);
  if FHandle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    if not SetupComm(FHandle, 8192, 8192) then
      RaiseLastOSError;
    if not PurgeComm(FHandle, PURGE_RXCLEAR or PURGE_TXCLEAR) then
      RaiseLastOSError;

    FillChar(Dcb, SizeOf(Dcb), 0);
    Dcb.DCBlength := SizeOf(Dcb);
    if not GetCommState(FHandle, Dcb) then
      RaiseLastOSError;
    Dcb.BaudRate := ABaud;
    Dcb.ByteSize := ADataBits;
    Dcb.Parity := Ord(AParity); // совпадает с NOPARITY..SPACEPARITY
    case AStopBits of
      ssbOne:     Dcb.StopBits := ONESTOPBIT;
      ssbOneHalf: Dcb.StopBits := ONE5STOPBITS;
      ssbTwo:     Dcb.StopBits := TWOSTOPBITS;
    end;
    // Двоичный режим, без управления потоком и без замены ошибочных байт:
    // искажённые байты отловит CRC кадра.
    Dcb.Flags := (Dcb.Flags or dcbfBinary) and
      not (dcbfOutxCtsFlow or dcbfOutxDsrFlow or dcbfDsrSensitivity or
           dcbfOutX or dcbfInX or dcbfErrorChar or dcbfNull or
           dcbfAbortOnError or dcbfParity);
    if not SetCommState(FHandle, Dcb) then
      RaiseLastOSError;

    FillChar(Tm, SizeOf(Tm), 0);
    // ReadFile возвращается, когда пауза между байтами превысила
    // AInterByteTimeoutMs (конец кадра RTU), либо по общему тайм-ауту,
    // если данных нет вовсе (нужен для периодической проверки Terminated).
    Tm.ReadIntervalTimeout := AInterByteTimeoutMs;
    Tm.ReadTotalTimeoutMultiplier := 0;
    Tm.ReadTotalTimeoutConstant := AReadTimeoutMs;
    Tm.WriteTotalTimeoutMultiplier := 0;
    Tm.WriteTotalTimeoutConstant := 3000;
    if not SetCommTimeouts(FHandle, Tm) then
      RaiseLastOSError;
  except
    CloseHandle(FHandle);
    FHandle := INVALID_HANDLE_VALUE;
    raise;
  end;
end;

procedure TSerialPort.Close;
begin
  if FHandle <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FHandle);
    FHandle := INVALID_HANDLE_VALUE;
  end;
end;

function TSerialPort.IsOpen: Boolean;
begin
  Result := FHandle <> INVALID_HANDLE_VALUE;
end;

function TSerialPort.Read(var ABuf; AMax: DWORD): DWORD;
begin
  if not ReadFile(FHandle, ABuf, AMax, Result, nil) then
    RaiseLastOSError;
end;

procedure TSerialPort.Write(const ABuf; ALen: DWORD);
var
  P: PByte;
  Done, N: DWORD;
begin
  P := @ABuf;
  Done := 0;
  while Done < ALen do
  begin
    if not WriteFile(FHandle, P^, ALen - Done, N, nil) then
      RaiseLastOSError;
    if N = 0 then
      raise Exception.Create('Тайм-аут записи в COM-порт');
    Inc(Done, N);
    Inc(P, N);
  end;
end;

procedure TSerialPort.Purge;
begin
  if FHandle <> INVALID_HANDLE_VALUE then
    PurgeComm(FHandle, PURGE_RXCLEAR or PURGE_TXCLEAR);
end;

function TSerialPort.InputCount: DWORD;
var
  Errors: DWORD;
  Stat: TComStat;
begin
  if FHandle = INVALID_HANDLE_VALUE then
    Exit(0);
  if not ClearCommError(FHandle, Errors, @Stat) then
    RaiseLastOSError;
  Result := Stat.cbInQue;
end;

end.
