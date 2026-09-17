# -*- coding: utf-8 -*-
"""Сторонний читатель слоя событий (#88): только stdlib Python.

Проверяет файл `.events`, записанный нашим писателем: заголовок, время не
идёт назад, у каждой строки столько полей, сколько положено её слову,
и в файле есть область записи. Свой читатель на Zig проверять своим же
писателем — значит повторить ошибку в обе стороны; этот скрипт про формат
знает только то, что написано в его описании.

    python tools/check_events.py ФАЙЛ.events [--min-moves N] [--expect-area]
"""
import io
import sys

FIELDS = {"area": 4, "move": 2, "down": 3, "up": 3, "wheel": 3, "key": 1}


def main(argv):
    if len(argv) < 2:
        print("[events-py] нужен путь к файлу .events")
        return 2
    path = argv[1]
    min_moves = 0
    expect_area = False
    i = 2
    while i < len(argv):
        if argv[i] == "--min-moves" and i + 1 < len(argv):
            min_moves = int(argv[i + 1])
            i += 2
        elif argv[i] == "--expect-area":
            expect_area = True
            i += 1
        else:
            i += 1

    with io.open(path, "r", encoding="utf-8", newline="") as f:
        lines = f.read().split("\n")
    head = lines[0].rstrip("\r ").split(" ")
    if len(head) < 2 or head[0] != "zigrec-events":
        print("[events-py] ПРОВАЛ: это не файл слоя событий: %r" % lines[0][:40])
        return 1
    if int(head[1]) != 1:
        print("[events-py] ПРОВАЛ: версия %s, знаем только 1" % head[1])
        return 1

    counts = {}
    last = -1
    n = 0
    for lineno, raw in enumerate(lines[1:], start=2):
        line = raw.rstrip("\r ")
        if not line:
            continue
        parts = line.split(" ")
        try:
            t = int(parts[0])
        except ValueError:
            print("[events-py] ПРОВАЛ: строка %d: время не число: %r" % (lineno, parts[0]))
            return 1
        if t < last:
            print("[events-py] ПРОВАЛ: строка %d: время пошло назад (%d < %d)" % (lineno, t, last))
            return 1
        last = t
        if len(parts) < 2:
            print("[events-py] ПРОВАЛ: строка %d без слова" % lineno)
            return 1
        word = parts[1]
        if word in FIELDS:
            want = FIELDS[word]
            args = parts[2:]
            if len(args) != want:
                print("[events-py] ПРОВАЛ: строка %d: у «%s» %d полей, надо %d" % (lineno, word, len(args), want))
                return 1
            for a in args:
                if word in ("down", "up") and a is args[0]:
                    if a not in ("L", "R", "M"):
                        print("[events-py] ПРОВАЛ: строка %d: кнопка %r" % (lineno, a))
                        return 1
                    continue
                try:
                    int(a)
                except ValueError:
                    print("[events-py] ПРОВАЛ: строка %d: %r не число" % (lineno, a))
                    return 1
        elif word == "focus":
            pass
        else:
            # Незнакомое слово — допустимо: старый читатель его пропустит.
            pass
        counts[word] = counts.get(word, 0) + 1
        n += 1

    print("[events-py] событий %d, последнее на %.3f с: %s" % (
        n, last / 1e9 if last >= 0 else 0.0,
        ", ".join("%s %d" % (k, v) for k, v in sorted(counts.items()))))
    if expect_area and counts.get("area", 0) == 0:
        print("[events-py] ПРОВАЛ: нет строки area — не узнать, где была область записи")
        return 1
    if counts.get("move", 0) < min_moves:
        print("[events-py] ПРОВАЛ: движений %d, ждали хотя бы %d" % (counts.get("move", 0), min_moves))
        return 1
    print("[events-py] СЛОЙ СОБЫТИЙ ЧИТАЕТСЯ")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
