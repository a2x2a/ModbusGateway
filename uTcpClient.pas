unit uTcpClient;

interface

uses
  Winapi.Windows, Winapi.WinSock2, System.SysUtils;

type
  ETcpError = class(Exception);

  // Минимальный блокирующий TCP-клиент на Winsock с тайм-аутами.
  // Используется только из потока шлюза, синхронизация не требуется.
  TTcpClient = class
  private
    FSocket: TSocket;
    FConnected: Boolean;
    class var FWsaReady: Boolean;
    class procedure EnsureWsa; static;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Connect(const AHost: string; APort: Word; ATimeoutMs: Integer);
    procedure Disconnect;
    procedure SendAll(const AData; ALen: Integer);
    // False — тайм-аут или отмена; исключение — ошибка сокета.
    // ACancelled опрашивается не реже, чем раз в 100 мс.
    function RecvExact(var ABuf; ALen: Integer; ATimeoutMs: Integer;
      ACancelled: TFunc<Boolean>): Boolean;
    property Connected: Boolean read FConnected;
  end;

implementation

// FD_SET в Winapi.WinSock2 не экспортирован (это макрос C) — своя реализация
procedure FdAdd(S: TSocket; var F: TFdSet);
begin
  if F.fd_count < FD_SETSIZE then
  begin
    F.fd_array[F.fd_count] := S;
    Inc(F.fd_count);
  end;
end;

class procedure TTcpClient.EnsureWsa;
var
  Wsa: TWSAData;
begin
  if FWsaReady then
    Exit;
  if WSAStartup($0202, Wsa) <> 0 then
    raise ETcpError.CreateFmt('WSAStartup: ошибка %d', [WSAGetLastError]);
  FWsaReady := True;
end;

constructor TTcpClient.Create;
begin
  inherited Create;
  FSocket := INVALID_SOCKET;
end;

destructor TTcpClient.Destroy;
begin
  Disconnect;
  inherited;
end;

procedure TTcpClient.Connect(const AHost: string; APort: Word; ATimeoutMs: Integer);
var
  Addr: TSockAddrIn;
  HostA: AnsiString;
  Ip: u_long;
  He: PHostEnt;
  Mode: u_long;
  WSet: fd_set;
  Tv: TTimeVal;
  Err, ErrLen, Flag: Integer;
begin
  Disconnect;
  EnsureWsa;

  HostA := AnsiString(AHost);
  Ip := inet_addr(PAnsiChar(HostA));
  if Ip = u_long(INADDR_NONE) then
  begin
    He := gethostbyname(PAnsiChar(HostA));
    if He = nil then
      raise ETcpError.CreateFmt('Не удаётся разрешить имя "%s"', [AHost]);
    Ip := PLongWord(He.h_addr_list^[0])^;
  end;

  FSocket := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if FSocket = INVALID_SOCKET then
    raise ETcpError.CreateFmt('socket: ошибка %d', [WSAGetLastError]);
  try
    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family := AF_INET;
    Addr.sin_port := htons(APort);
    Addr.sin_addr.S_addr := Ip;

    // Неблокирующий connect с тайм-аутом через select
    Mode := 1;
    ioctlsocket(FSocket, LongInt(FIONBIO), Mode);
    if Winapi.WinSock2.connect(FSocket, TSockAddr(Addr), SizeOf(Addr)) = SOCKET_ERROR then
    begin
      Err := WSAGetLastError;
      if Err <> WSAEWOULDBLOCK then
        raise ETcpError.CreateFmt('connect: ошибка %d', [Err]);
      FD_ZERO(WSet);
      FdAdd(FSocket, WSet);
      Tv.tv_sec := ATimeoutMs div 1000;
      Tv.tv_usec := (ATimeoutMs mod 1000) * 1000;
      if select(0, nil, @WSet, nil, @Tv) <= 0 then
        raise ETcpError.Create('Тайм-аут подключения');
      ErrLen := SizeOf(Err);
      Err := 0;
      if (getsockopt(FSocket, SOL_SOCKET, SO_ERROR, PAnsiChar(@Err), ErrLen) <> 0) or
         (Err <> 0) then
        raise ETcpError.CreateFmt('Подключение не удалось (код %d)', [Err]);
    end;

    // Обратно в блокирующий режим
    Mode := 0;
    ioctlsocket(FSocket, LongInt(FIONBIO), Mode);

    // Запрос-ответный протокол: Nagle только мешает
    Flag := 1;
    setsockopt(FSocket, IPPROTO_TCP, TCP_NODELAY, PAnsiChar(@Flag), SizeOf(Flag));

    FConnected := True;
  except
    closesocket(FSocket);
    FSocket := INVALID_SOCKET;
    raise;
  end;
end;

procedure TTcpClient.Disconnect;
begin
  FConnected := False;
  if FSocket <> INVALID_SOCKET then
  begin
    shutdown(FSocket, SD_BOTH);
    closesocket(FSocket);
    FSocket := INVALID_SOCKET;
  end;
end;

procedure TTcpClient.SendAll(const AData; ALen: Integer);
var
  P: PByte;
  Sent, N: Integer;
begin
  P := @AData;
  Sent := 0;
  while Sent < ALen do
  begin
    N := send(FSocket, P^, ALen - Sent, 0);
    if N = SOCKET_ERROR then
    begin
      FConnected := False;
      raise ETcpError.CreateFmt('send: ошибка %d', [WSAGetLastError]);
    end;
    Inc(Sent, N);
    Inc(P, N);
  end;
end;

function TTcpClient.RecvExact(var ABuf; ALen: Integer; ATimeoutMs: Integer;
  ACancelled: TFunc<Boolean>): Boolean;
var
  Deadline: UInt64;
  Got, N, Sel: Integer;
  P: PByte;
  RSet: fd_set;
  Tv: TTimeVal;
  WaitMs: Int64;
begin
  Result := False;
  P := @ABuf;
  Got := 0;
  Deadline := GetTickCount64 + UInt64(ATimeoutMs);
  while Got < ALen do
  begin
    if Assigned(ACancelled) and ACancelled() then
      Exit;
    WaitMs := Int64(Deadline) - Int64(GetTickCount64);
    if WaitMs <= 0 then
      Exit;
    // Ждём короткими интервалами, чтобы быстро реагировать на остановку
    if WaitMs > 100 then
      WaitMs := 100;
    FD_ZERO(RSet);
    FdAdd(FSocket, RSet);
    Tv.tv_sec := LongInt(WaitMs div 1000);
    Tv.tv_usec := LongInt((WaitMs mod 1000) * 1000);
    Sel := select(0, @RSet, nil, nil, @Tv);
    if Sel = 0 then
      Continue; // истёк интервал ожидания — проверим отмену и дедлайн
    if Sel = SOCKET_ERROR then
    begin
      FConnected := False;
      raise ETcpError.CreateFmt('select: ошибка %d', [WSAGetLastError]);
    end;
    N := recv(FSocket, P^, ALen - Got, 0);
    if N = 0 then
    begin
      FConnected := False;
      raise ETcpError.Create('Соединение закрыто удалённой стороной');
    end;
    if N = SOCKET_ERROR then
    begin
      FConnected := False;
      raise ETcpError.CreateFmt('recv: ошибка %d', [WSAGetLastError]);
    end;
    Inc(P, N);
    Inc(Got, N);
  end;
  Result := True;
end;

end.
