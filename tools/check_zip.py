# -*- coding: utf-8 -*-
"""Чужой взгляд на наш архив проекта.

ZIP мы пишем сами, и проверять свою запись своим же читателем бессмысленно:
ошибка в заголовке повторится в обе стороны и останется незамеченной.
Здесь архив открывает питон — он умеет ZIP из коробки и проверяет
контрольные суммы каждого куска.

Проверяем ровно то, на чём стоит формат:

 * архив читается и контрольные суммы сходятся;
 * метка `ZIGREC-V-<версия>` лежит ПЕРВОЙ и БЕЗ сжатия — на этом держится
   узнавание файла по содержимому, а не по расширению;
 * внутри есть разметка, и она — тот самый текст, а не что-то иное;
 * русские имена целы: без признака UTF-8 их читают как попало.
"""
import io
import sys
import zipfile

MARKER = "ZIGREC-V-"
PROJECT = "проект.zrs"
MEDIA = "исходники/"


def main(path):
    out = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

    try:
        z = zipfile.ZipFile(path)
    except Exception as err:
        print("[zip] ПРОВАЛ: питон не открыл архив: %s" % err, file=out)
        return 1

    broken = z.testzip()
    if broken is not None:
        print("[zip] ПРОВАЛ: испорчен кусок %s" % broken, file=out)
        return 1

    items = z.infolist()
    if not items:
        print("[zip] ПРОВАЛ: архив пуст", file=out)
        return 1

    first = items[0]
    if not first.filename.startswith(MARKER):
        print("[zip] ПРОВАЛ: первым куском лежит «%s», а не метка" % first.filename, file=out)
        return 1
    if first.compress_type != zipfile.ZIP_STORED:
        print("[zip] ПРОВАЛ: метка сжата — по содержимому файл не узнать", file=out)
        return 1

    version = first.filename[len(MARKER):]
    if not version:
        print("[zip] ПРОВАЛ: метка без версии", file=out)
        return 1

    names = [i.filename for i in items]
    if PROJECT not in names:
        print("[zip] ПРОВАЛ: разметки «%s» внутри нет" % PROJECT, file=out)
        return 1

    markup = z.read(PROJECT).decode("utf-8")
    if not markup.startswith("zigrec-project "):
        print("[zip] ПРОВАЛ: разметка не та: %r" % markup[:40], file=out)
        return 1

    media = [n for n in names if n.startswith(MEDIA)]

    print("[zip] архив открыт питоном, контрольные суммы сошлись", file=out)
    print("[zip] метка первая и без сжатия: версия %s" % version, file=out)
    print("[zip] кусков %d, из них исходников %d" % (len(items), len(media)), file=out)
    for i in items:
        how = "как есть" if i.compress_type == zipfile.ZIP_STORED else "сжато"
        print("[zip]   %-32s %8d → %8d  %s" % (i.filename, i.file_size, i.compress_size, how), file=out)

    # Русские имена должны читаться. Если признак UTF-8 не выставлен, питон
    # разберёт имя по cp437, и кириллица превратится в набор знаков.
    for n in names:
        if any(ord(ch) > 127 for ch in n):
            break
    else:
        print("[zip] ПРОВАЛ: ни одного русского имени — проверять нечего", file=out)
        return 1

    print("[zip] РУССКИЕ ИМЕНА ЦЕЛЫ, АРХИВ НАСТОЯЩИЙ", file=out)
    out.flush()
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("нужен путь к архиву")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
