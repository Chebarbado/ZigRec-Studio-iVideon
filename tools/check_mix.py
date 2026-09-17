# -*- coding: utf-8 -*-
"""Чужая проверка сведённого звука.

Задачи #61 и #62. Мы сами написали WAV, сами его прочитали и сами
померили — и получили ровно то, что ожидали. Это ничего не доказывает:
ошибка в записи и та же ошибка в чтении дают сходящийся ответ.

Здесь файл читает стандартный модуль `wave` — чужой код, который про наш
формат ничего не знает, — а уровень считается прямо по правилу кривой.
Сойдётся — значит сведение действительно делает то, что нарисовано.

    python tools/check_mix.py .check/audio/mix.wav ПАДЕНИЕ_ДБ ИСХОДНЫЙ_ДБ
"""
import math
import struct
import sys
import wave

# Насколько уровень может разойтись с кривой. Пик берётся в короткое окно
# и на спуске неизбежно чуть отстаёт от точного значения.
TOLERANCE_DB = 1.5
# Доля секунды, по которой меряется пик.
WINDOW = 0.05


def peak_db(frames, rate, at_seconds):
    """Пик в коротком окне вокруг точки, в децибелах."""
    width = int(rate * WINDOW)
    start = max(0, min(int(at_seconds * rate), len(frames) - width))
    piece = frames[start:start + width]
    if not piece:
        return -120.0
    # Вниз шкала уходит на шаг дальше, чем вверх: каждая сторона
    # меряется своим пределом, иначе исправный звук даёт «пик больше единицы».
    top = max(abs(v) / (32768.0 if v < 0 else 32767.0) for v in piece)
    return 20.0 * math.log10(top) if top > 0 else -120.0


def main():
    if len(sys.argv) < 4:
        print('нужны: файл, падение кривой в дБ, уровень исходника в дБ')
        return 2

    path, fall_db, source_db = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])

    with wave.open(path, 'rb') as f:
        channels = f.getnchannels()
        width = f.getsampwidth()
        rate = f.getframerate()
        count = f.getnframes()
        raw = f.readframes(count)

    print('[mix-py] %s: %d Гц, каналов %d, %d бит, %.2f с'
          % (path, rate, channels, width * 8, count / float(rate)))

    if width != 2:
        print('[mix-py] ПРОВАЛ: ждали 16 бит, а в файле %d' % (width * 8))
        return 1
    if channels != 1:
        print('[mix-py] ПРОВАЛ: ждали моно, а каналов %d' % channels)
        return 1

    frames = struct.unpack('<%dh' % (len(raw) // 2), raw)
    if len(frames) != count * channels:
        print('[mix-py] ПРОВАЛ: отсчётов %d, а заголовок обещал %d'
              % (len(frames), count * channels))
        return 1

    seconds = count / float(rate)
    bad = 0
    for part in (0.05, 0.5, 0.95):
        want = source_db + fall_db * part
        got = peak_db(frames, rate, seconds * part)
        gap = abs(got - want)
        print('[mix-py] на %3.0f%%: ждали %7.2f дБ, вышло %7.2f дБ, разница %.2f'
              % (part * 100, want, got, gap))
        if gap > TOLERANCE_DB:
            print('[mix-py] ПРОВАЛ: громкость не идёт по кривой')
            bad = 1

    # Кривая обязана именно падать: сошедшиеся числа при ровном звуке
    # означали бы, что мы сравниваем одно и то же с самим собой.
    first = peak_db(frames, rate, seconds * 0.05)
    last = peak_db(frames, rate, seconds * 0.95)
    print('[mix-py] спуск от %.2f до %.2f дБ' % (first, last))
    if first - last < 10:
        print('[mix-py] ПРОВАЛ: звук не стал заметно тише к концу')
        bad = 1

    if bad:
        return 1
    print('[mix-py] ЧУЖОЙ ЧИТАТЕЛЬ СОГЛАСЕН: ГРОМКОСТЬ ИДЁТ ПО КРИВОЙ')
    return 0


if __name__ == '__main__':
    sys.exit(main())
