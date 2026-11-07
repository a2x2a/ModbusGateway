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
    """f03: вернуть (список регистров, задержка мс) или (None, задержка).
    Читает по структуре ответа: заголовок 3 байта, затем тело по длине."""
    pdu = bytes([3]) + struct.pack('>HH', addr, qty)
    t0 = time.perf_counter()
    ser.write(frame(UNIT, pdu))
    ser.timeout = timeout
    hdr = ser.read(3)
    ms = (time.perf_counter() - t0) * 1000
    if len(hdr) < 3:
        print('  ОШИБКА: нет ответа (%.0f мс)' % ms)
        return None, ms
    if hdr[1] & 0x80:
        resp = hdr + ser.read(2)  # исключение: addr func|80 code crc
    else:
        resp = hdr + ser.read(hdr[2] + 2)  # данные + CRC
    ms = (time.perf_counter() - t0) * 1000
    if len(resp) < 5 or crc16(resp[:-2]) != struct.unpack('<H', resp[-2:])[0]:
        print('  ОШИБКА: битый ответ: %s (%.0f мс)' % (resp.hex(' '), ms))
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

    if scenario in ('stress',):
        # Непрерывный опрос регистров 1-25 без пауз — нагрузка на медленное
        # устройство. Следим за дрейфом задержки и ошибками по минутам.
        print('[S] непрерывный опрос регистров 1-25, 5 минут')
        t_end = time.time() + 300
        n = ok = errs = 0
        t_min = time.time()
        cyc_ok = cyc_err = 0
        worst_all = 0.0
        while time.time() < t_end:
            n += 1
            regs, ms = req_f03(ser, 0, 25, timeout=3.0)
            if regs is None:
                errs += 1
                cyc_err += 1
                print('  #%d: ОШИБКА (%.0f мс)' % (n, ms))
            else:
                ok += 1
                cyc_ok += 1
                worst_all = max(worst_all, ms)
            if time.time() - t_min >= 60:
                print('  минута: ок=%d ошибок=%d' % (cyc_ok, cyc_err))
                t_min = time.time()
                cyc_ok = cyc_err = 0
        print('  итого за %d циклов: ок=%d ошибок=%d, худшая задержка %.0f мс'
              % (n, ok, errs, worst_all))

    if scenario in ('ranges',):
        # Диапазоны регистров (нумерация с 1), случайный порядок, 5 кругов.
        import random
        ranges = [(1, 25), (200, 214), (400, 409), (500, 599),
                  (2000, 2017), (3000, 3059)]
        print('[G] диапазоны: %s, 5 кругов в случайном порядке'
              % ', '.join('%d-%d' % r for r in ranges))
        ok = errs = 0
        for rnd in range(1, 6):
            random.shuffle(ranges)
            for first, last in ranges:
                addr, qty = first - 1, last - first + 1
                regs, ms = req_f03(ser, addr, qty, timeout=3.0)
                if regs is None:
                    errs += 1
                    print('  круг %d: %d-%d ОШИБКА (%.0f мс)' % (rnd, first, last, ms))
                else:
                    ok += 1
                    print('  круг %d: %d-%d ок, %d рег, %.0f мс, первые: %s'
                          % (rnd, first, last, len(regs), ms, regs[:4]))
                time.sleep(0.05)
        print('  итого: ок=%d ошибок=%d' % (ok, errs))

    if scenario in ('inval',):
        # Инвалидация кэша записью. Кэш включён (проверить INI!).
        # Сервер кладёт счётчик в первый регистр: счётчик растёт только
        # при реальном TCP-чтении. Задержка сервера 300 мс — кэш ~15 мс.
        def f06(ser, addr, val):
            pdu = bytes([6]) + struct.pack('>HH', addr, val)
            t0 = time.perf_counter()
            ser.write(frame(UNIT, pdu))
            ser.timeout = 2.0
            resp = ser.read(8)
            return (time.perf_counter() - t0) * 1000, resp

        print('[I] 1. чтение @100 n2 (TCP, счётчик -> N)')
        regs, ms = req_f03(ser, 100, 2)
        print('  %s за %.0f мс' % (regs, ms))
        print('[I] 2. повтор — из кэша (быстро, тот же N)')
        regs, ms = req_f03(ser, 100, 2)
        print('  %s за %.0f мс' % (regs, ms))
        time.sleep(1.5)  # фоновое обновление кэша (счётчик -> N+1)
        print('[I] 3. запись f06 @100 := 0x1234 — должна вычистить кэш')
        ms, resp = f06(ser, 100, 0x1234)
        print('  ответ за %.0f мс: %s' % (ms, resp.hex(' ') if resp else 'НЕТ'))
        print('[I] 4. чтение @100 n2 — ОБЯЗАНО идти в TCP (медленно, N+2)')
        regs, ms = req_f03(ser, 100, 2)
        print('  %s за %.0f мс' % (regs, ms))
        print('[I] 5. запись f06 @200 := 1 — НЕ пересекается, кэш жив')
        ms, resp = f06(ser, 200, 1)
        print('  ответ за %.0f мс' % ms)
        print('[I] 6. чтение @100 n2 — снова из кэша (быстро)')
        regs, ms = req_f03(ser, 100, 2)
        print('  %s за %.0f мс' % (regs, ms))

    if scenario in ('failcache',):
        # Проверка «отрицательного» кэша: @296 n2 молчит на устройстве.
        # 1-й запрос — тайм-аут ~1 с; ретраи — мгновенный 0B из кэша ошибок;
        # соседние запросы не должны тормозить.
        print('[F] первый @296 n2 — ожидаем тайм-аут ~1000 мс')
        regs, ms = req_f03(ser, 296, 2, timeout=3.0)
        print('  ответ за %.0f мс' % ms)
        print('[F] 5 ретраев подряд — ожидаем мгновенный 0B')
        for i in range(5):
            t0 = time.perf_counter()
            regs, ms = req_f03(ser, 296, 2, timeout=2.0)
            print('  #%d: %.0f мс' % (i + 1, ms))
        print('[F] соседние запросы @100 n2 — не должны тормозить')
        for i in range(3):
            regs, ms = req_f03(ser, 100, 2)
            print('  #%d: %s за %.0f мс' % (i + 1, regs, ms))
        print('[F] пауза 11 с (TTL кэша ошибок), затем @296 n2 — снова проба в TCP ~1000 мс')
        time.sleep(11)
        regs, ms = req_f03(ser, 296, 2, timeout=3.0)
        print('  ответ за %.0f мс' % ms)

    if scenario in ('probe',):
        # Карта «молчащих» адресов вокруг 296: одиночные чтения 290..305
        print('[P] проба адресов 290..305 по одному регистру')
        for addr in range(290, 306):
            regs, ms = req_f03(ser, addr, 1, timeout=2.0)
            if regs is None:
                print('  @%d n1: НЕТ ОТВЕТА / ошибка (%.0f мс)' % (addr, ms))
            else:
                print('  @%d n1: ок [%d] %.0f мс' % (addr, regs[0], ms))
            time.sleep(0.05)
        print('[P] групповые чтения через 296')
        for addr, qty in [(295, 2), (296, 2), (296, 1), (297, 1), (295, 4), (296, 3)]:
            regs, ms = req_f03(ser, addr, qty, timeout=2.0)
            if regs is None:
                print('  @%d n%d: НЕТ ОТВЕТА / ошибка (%.0f мс)' % (addr, qty, ms))
            else:
                print('  @%d n%d: ок %s %.0f мс' % (addr, qty, regs, ms))
            time.sleep(0.05)

    if scenario in ('real',):
        # Опрос реального устройства: регистры 1-25 (адреса 0-24), только чтение.
        # Период 300 мс, 100 циклов; считаем задержки и ошибки.
        print('[R] опрос регистров 1-25, период 300 мс, 100 циклов')
        ok = errs = 0
        worst = 0.0
        for i in range(100):
            regs, ms = req_f03(ser, 0, 25, timeout=3.0)
            if regs is None:
                errs += 1
                print('  #%d: ОШИБКА (%.0f мс)' % (i + 1, ms))
            else:
                ok += 1
                worst = max(worst, ms)
                if (i + 1) % 10 == 0:
                    print('  #%d: ок, %.0f мс, рег1=%d' % (i + 1, ms, regs[0]))
            time.sleep(0.3)
        print('  итого: ок=%d ошибок=%d, худшая задержка %.0f мс' % (ok, errs, worst))

    if scenario in ('all', 'ttl'):
        print('[6] проверка TTL: пауза 11 с, затем запрос — кэш протух, ждём TCP')
        time.sleep(11)
        regs, ms = req_f03(ser, 100, 2)
        print('  ответ: %s за %.0f мс' % (regs, ms))

    ser.close()

main()
