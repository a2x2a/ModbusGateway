unit uModbusProto;

interface

uses
  System.SysUtils;

const
  // Коды исключений Modbus, возвращаемые мастеру RTU при проблемах с TCP
  EX_GATEWAY_PATH_UNAVAILABLE = $0A; // нет связи с устройством TCP
  EX_GATEWAY_TARGET_NO_RESPONSE = $0B; // устройство не ответило вовремя

function ModbusCRC16(const AData; ALen: Integer): Word;
function CheckCrc(const AFrame: TBytes): Boolean;
procedure AppendCrc(var AFrame: TBytes);
function BytesToHex(const AData: TBytes): string;
function ExceptionName(ACode: Byte): string;
// Компактное описание PDU для журнала: f03, адрес @100 (нумерация
// протокола, с 0), количество n2, данные [...]. AIsResponse — разбор
// как ответа. AValid=True, если структура PDU распознана и длина сошлась
// (тогда дамп пакета в журнале не нужен).
function DescribePdu(const APdu: TBytes; AIsResponse: Boolean;
  out AValid: Boolean): string;

implementation

// Классический CRC16 Modbus: полином $A001, начальное значение $FFFF
function ModbusCRC16(const AData; ALen: Integer): Word;
var
  P: PByte;
  I, J: Integer;
  Crc: Word;
begin
  Crc := $FFFF;
  P := @AData;
  for I := 0 to ALen - 1 do
  begin
    Crc := Crc xor P^;
    for J := 0 to 7 do
      if (Crc and $0001) <> 0 then
        Crc := (Crc shr 1) xor $A001
      else
        Crc := Crc shr 1;
    Inc(P);
  end;
  Result := Crc;
end;

// Кадр: [адрес][PDU][CRC lo][CRC hi]
function CheckCrc(const AFrame: TBytes): Boolean;
var
  L: Integer;
  Crc: Word;
begin
  L := Length(AFrame);
  if L < 4 then
    Exit(False);
  Crc := ModbusCRC16(AFrame[0], L - 2);
  Result := (AFrame[L - 2] = Lo(Crc)) and (AFrame[L - 1] = Hi(Crc));
end;

procedure AppendCrc(var AFrame: TBytes);
var
  L: Integer;
  Crc: Word;
begin
  L := Length(AFrame);
  Crc := ModbusCRC16(AFrame[0], L);
  SetLength(AFrame, L + 2);
  AFrame[L] := Lo(Crc);
  AFrame[L + 1] := Hi(Crc);
end;

function BytesToHex(const AData: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Length(AData) - 1 do
  begin
    if I > 0 then
      Result := Result + ' ';
    Result := Result + IntToHex(AData[I], 2);
  end;
end;

function ExceptionName(ACode: Byte): string;
begin
  case ACode of
    $01: Result := 'недопустимая функция';
    $02: Result := 'недопустимый адрес';
    $03: Result := 'недопустимое значение';
    $04: Result := 'ошибка устройства';
    $05: Result := 'acknowledge';
    $06: Result := 'устройство занято';
    $08: Result := 'ошибка чётности памяти';
    $0A: Result := 'нет TCP-связи';
    $0B: Result := 'устройство не отвечает';
  else
    Result := 'код ' + IntToHex(ACode, 2);
  end;
end;

// Значения регистров (big-endian слова), все
function RegList(const AData: TBytes; AStart, ACount: Integer): string;
var
  I, V: Integer;
begin
  Result := '';
  for I := 0 to ACount - 1 do
  begin
    V := (AData[AStart + I * 2] shl 8) or AData[AStart + I * 2 + 1];
    if I > 0 then
      Result := Result + ',';
    Result := Result + IntToStr(V);
  end;
end;

function DescribePdu(const APdu: TBytes; AIsResponse: Boolean;
  out AValid: Boolean): string;
var
  Fn: Byte;
  L, Addr, Val: Integer;
begin
  L := Length(APdu);
  AValid := False;
  if L < 1 then
    Exit('пустой PDU');
  Fn := APdu[0];

  // Ответ-исключение: старший бит кода функции установлен
  if (Fn and $80) <> 0 then
  begin
    if L >= 2 then
    begin
      Result := Format('!f%s %s (%s)',
        [IntToHex(Fn, 2), IntToHex(APdu[1], 2), ExceptionName(APdu[1])]);
      AValid := True;
    end
    else
      Result := '!битый PDU';
    Exit;
  end;

  Result := 'f' + IntToHex(Fn, 2);

  if not AIsResponse then
  begin
    // --- Запрос: валиден только при точном совпадении длины PDU ---
    case Fn of
      $01..$04:
        if L = 5 then
        begin
          Result := Result + Format(' @%d n%d',
            [(APdu[1] shl 8) or APdu[2], (APdu[3] shl 8) or APdu[4]]);
          AValid := True;
        end;
      $05, $06:
        if L = 5 then
        begin
          Addr := (APdu[1] shl 8) or APdu[2];
          Val := (APdu[3] shl 8) or APdu[4];
          if (Fn = $05) and (Val = $FF00) then
            Result := Result + Format(' @%d =ВКЛ', [Addr])
          else if (Fn = $05) and (Val = $0000) then
            Result := Result + Format(' @%d =ВЫКЛ', [Addr])
          else
            Result := Result + Format(' @%d =%d', [Addr, Val]);
          AValid := True;
        end;
      $0F:
        if (L >= 6) and (APdu[5] = L - 6) then
        begin
          Result := Result + Format(' @%d n%d: %s',
            [(APdu[1] shl 8) or APdu[2], (APdu[3] shl 8) or APdu[4],
             BytesToHex(Copy(APdu, 6, APdu[5]))]);
          AValid := True;
        end;
      $10:
        if (L >= 6) and (APdu[5] = L - 6) then
        begin
          Result := Result + Format(' @%d n%d [%s]',
            [(APdu[1] shl 8) or APdu[2], (APdu[3] shl 8) or APdu[4],
             RegList(APdu, 6, APdu[5] div 2)]);
          AValid := True;
        end;
      $17:
        if (L >= 10) and (APdu[9] = L - 10) then
        begin
          Result := Result + Format(' чт @%d n%d / зап @%d n%d [%s]',
            [(APdu[1] shl 8) or APdu[2], (APdu[3] shl 8) or APdu[4],
             (APdu[5] shl 8) or APdu[6], (APdu[7] shl 8) or APdu[8],
             RegList(APdu, 10, APdu[9] div 2)]);
          AValid := True;
        end;
    // неизвестная функция — AValid=False, дамп покажем
    end;
  end
  else
  begin
    // --- Ответ ---
    case Fn of
      $01, $02:
        if (L >= 2) and (APdu[1] = L - 2) then
        begin
          Result := Result + ': ' + BytesToHex(Copy(APdu, 2, APdu[1]));
          AValid := True;
        end;
      $03, $04:
        if (L >= 2) and (APdu[1] = L - 2) then
        begin
          Result := Result + ' [' + RegList(APdu, 2, APdu[1] div 2) + ']';
          AValid := True;
        end;
      $05, $06:
        if L = 5 then
        begin
          Addr := (APdu[1] shl 8) or APdu[2];
          Val := (APdu[3] shl 8) or APdu[4];
          if (Fn = $05) and (Val = $FF00) then
            Result := Result + Format(' @%d =ВКЛ', [Addr])
          else if (Fn = $05) and (Val = $0000) then
            Result := Result + Format(' @%d =ВЫКЛ', [Addr])
          else
            Result := Result + Format(' @%d =%d', [Addr, Val]);
          AValid := True;
        end;
      $0F, $10:
        if L = 5 then
        begin
          Result := Result + Format(' @%d n%d ок',
            [(APdu[1] shl 8) or APdu[2], (APdu[3] shl 8) or APdu[4]]);
          AValid := True;
        end;
      $17:
        if (L >= 2) and (APdu[1] = L - 2) then
        begin
          Result := Result + ' [' + RegList(APdu, 2, APdu[1] div 2) + ']';
          AValid := True;
        end;
    // неизвестная функция — AValid=False, дамп покажем
    end;
  end;
end;

end.
