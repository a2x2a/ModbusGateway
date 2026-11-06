# -*- coding: utf-8 -*-
"""Эмулятор устройства Modbus TCP для теста шлюза.
f03/f04: возвращает регистры со счётчиком в первом регистре (видно обновление кэша).
f06: эхо-ответ (запись).
Лог каждого запроса пишется в tcp_server.log и на stdout.
"""
import socket, struct, sys, time

HOST, PORT = '127.0.0.1', 5020
counter = 0

def log(msg):
    line = '%s %s' % (time.strftime('%H:%M:%S'), msg)
    print(line, flush=True)
    with open('tcp_server.log', 'a', encoding='utf-8') as f:
        f.write(line + '\n')

def handle(pdu):
    global counter
    func = pdu[0]
    if func in (3, 4):
        addr, qty = struct.unpack('>HH', pdu[1:5])
        counter += 1
        vals = [(counter, addr + i)[i > 0] for i in range(qty)]
        data = b''.join(struct.pack('>H', v & 0xFFFF) for v in vals)
        return bytes([func, len(data)]) + data
    if func == 6:
        return pdu[:5]  # эхо: func + addr + value
    return bytes([func | 0x80, 2])

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((HOST, PORT))
srv.listen(1)
log('сервер на %s:%d' % (HOST, PORT))
while True:
    conn, _ = srv.accept()
    log('подключение')
    buf = b''
    try:
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
            while len(buf) >= 7:
                tid, pid, ln = struct.unpack('>HHH', buf[:6])
                if len(buf) < 6 + ln:
                    break
                frame, buf = buf[:6 + ln], buf[6 + ln:]
                unit, pdu = frame[6], frame[7:6 + ln]
                resp = handle(pdu)
                time.sleep(0.3)  # имитация задержки устройства: кэш-ответ заметно быстрее
                log('запрос tid=%d f%02d @%d -> %d байт' % (tid, pdu[0],
                    struct.unpack('>H', pdu[1:3])[0] if len(pdu) >= 3 else 0, len(resp)))
                out = struct.pack('>HHHB', tid, 0, len(resp) + 1, unit) + resp
                conn.sendall(out)
    except OSError:
        pass
    conn.close()
    log('отключение')
