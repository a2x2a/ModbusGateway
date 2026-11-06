# -*- coding: utf-8 -*-
"""Эмулятор мастера Modbus RTU для теста шлюза.
Шлёт запросы в COM9 (шлюз слушает COM19 через com0com), замеряет задержку
и проверяет данные ответов. Сценарии выбираются аргументом командной строки.
"""
import serial, struct, sys, time

PORT, BAUD, UNIT = 'COM9', 9600, 1

def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (0xA001 if crc & 1 else 0)
    return crc

def frame(unit, pdu):
    f = bytes([unit]) + pdu
    return f + struct.pack('<H', crc16(f))

def read_resp(ser, want_len, timeout=2.0):
    ser.timeout = timeout
    resp = ser.read(want_len)
    return resp

def req_f03(ser, addr, qty, timeout=2.0):
    """f03: вернуть (список регистров, задержка мс) или (None, задержка)."""
    pdu = bytes([3]) + struct.pack('>HH', addr, qty)
    t0 = time.perf_counter()
    ser.write(frame(UNIT, pdu))
    resp = read_resp(ser, 5 + 2 * qty, timeout)
    ms = (time.perf_counter() - t0) * 1000
    if len(resp) < 5 + 2 * qty:
        print('  ОШИБКА: ответ короткий: %s (%.0f мс)' % (resp.hex(' '), ms))
        return None, ms
    if crc16(resp[:-2]) != struct.unpack('<H', resp[-2:])[0]:
        print('  ОШИБКА: CRC ответа: %s' % resp.hex(' '))
        return None, ms
    if resp[1] & 0x80:
        print('  исключение !%02X %02X (%.0f мс)' % (resp[1], resp[2], ms))
        return None, ms
    regs = list(struct.unpack('>%dH' % qty, resp[3:3 + 2 * qty]))
    return regs, ms

def main():
    scenario = sys.argv[1] if len(sys.argv) > 1 else 'all'
    ser = serial.Serial(PORT, BAUD, bytesize=8, parity='N', stopbits=1, timeout=2)
    ser.reset_input_buffer()
    print('мастер на %s, сценарий %s' % (PORT, scenario))

    if scenario in ('all', 'first'):
        print('[1] первый запрос (кэш пуст) @100 n2 — ожидаем ответ после TCP')
        regs, ms = req_f03(ser, 100, 2)
        print('  ответ: %s за %.0f мс' % (regs, ms))

    if scenario in ('all', 'burst'):
        print('[2] пачка из 5 одинаковых запросов @100 n2 без пауз')
        for i in range(5):
            regs, ms = req_f03(ser, 100, 2)
            print('  #%d: %s за %.0f мс' % (i + 1, regs, ms))
        print('  пауза 1,5 с — ждём фоновое обновление кэша')
        time.sleep(1.5)
        print('[3] запрос после обновления — значения должны смениться')
        regs, ms = req_f03(ser, 100, 2)
        print('  ответ: %s за %.0f мс' % (regs, ms))

    if scenario in ('all', 'glued'):
        print('[4] два разных запроса вплотную, без межкадровой паузы')
        f1 = frame(UNIT, bytes([3]) + struct.pack('>HH', 100, 2))
        f2 = frame(UNIT, bytes([3]) + struct.pack('>HH', 200, 3))
        ser.reset_input_buffer()
        ser.write(f1 + f2)
        r1 = read_resp(ser, 5 + 4)
        r2 = read_resp(ser, 5 + 6)
        print('  ответ 1: %s' % (r1.hex(' ') if r1 else 'НЕТ'))
        print('  ответ 2: %s' % (r2.hex(' ') if r2 else 'НЕТ'))
        time.sleep(1.5)  # фоновое обновление по обоим ключам

    if scenario in ('all', 'write'):
        print('[5] запись f06 @300 := 0x1234 — вне очереди, синхронно')
        pdu = bytes([6]) + struct.pack('>HH', 300, 0x1234)
        t0 = time.perf_counter()
        ser.write(frame(UNIT, pdu))
        resp = read_resp(ser, 8)
        ms = (time.perf_counter() - t0) * 1000
        print('  ответ: %s за %.0f мс' % (resp.hex(' ') if resp else 'НЕТ', ms))

    if scenario in ('all', 'ttl'):
        print('[6] проверка TTL: пауза 11 с, затем запрос — кэш протух, ждём TCP')
        time.sleep(11)
        regs, ms = req_f03(ser, 100, 2)
        print('  ответ: %s за %.0f мс' % (regs, ms))

    ser.close()

main()
