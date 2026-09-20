@echo off
rem Проверка проекта одной командой: форматирование, сборка, тесты.
rem Возвращает 0 только если прошло всё. Задумано как единственный способ
rem сказать «работает» — без «запусти и посмотри».
setlocal enabledelayedexpansion
cd /d "%~dp0.."

rem Zig из PATH, иначе из установки winget: после winget install PATH
rem обновляется только в новых окнах, а проверка должна работать сразу.
set "ZIG="
for /f "delims=" %%i in ('where zig 2^>nul') do if not defined ZIG set "ZIG=%%i"
if not defined ZIG if exist "%LOCALAPPDATA%\Microsoft\WinGet\Links\zig.exe" set "ZIG=%LOCALAPPDATA%\Microsoft\WinGet\Links\zig.exe"
if not defined ZIG (
  rem dir /s ищет по ИМЕНИ файла от каталога: подстановка в середине пути не работает.
  for /f "delims=" %%i in ('dir /b /s "%LOCALAPPDATA%\Microsoft\WinGet\Packages\zig.exe" 2^>nul') do if not defined ZIG set "ZIG=%%i"
)
if not defined ZIG (
  echo [check] Zig не найден. Поставить: winget install --id zig.zig -e
  exit /b 127
)

for /f "delims=" %%v in ('"%ZIG%" version') do set "ZIGVER=%%v"
echo [check] zig %ZIGVER%  ^(%ZIG%^)

echo [check] формат
"%ZIG%" fmt --check build.zig src tools 2>nul
if errorlevel 1 (
  echo [check] ПРОВАЛ: код не отформатирован. Поправить: zig fmt build.zig src
  exit /b 1
)

echo [check] сборка
"%ZIG%" build
if errorlevel 1 (
  echo [check] ПРОВАЛ: сборка
  exit /b 1
)

echo [check] тесты
"%ZIG%" build test
if errorlevel 1 (
  echo [check] ПРОВАЛ: тесты
  exit /b 1
)

echo [check] релизная сборка
"%ZIG%" build -Doptimize=ReleaseFast
if errorlevel 1 (
  echo [check] ПРОВАЛ: релизная сборка
  exit /b 1
)

for %%f in ("zig-out\bin\zigrec.exe") do set "EXESIZE=%%~zf"
set /a EXEKB=%EXESIZE%/1024
echo [check] zigrec.exe: %EXEKB% КБ
"zig-out\bin\zigrec.exe" --version
if errorlevel 1 (
  echo [check] ПРОВАЛ: exe не запускается
  exit /b 1
)

echo [check] самопроверка захвата
"zig-out\bin\zigrec.exe" capture-smoke 60
if errorlevel 1 (
  echo [check] ПРОВАЛ: захват не снимает то, что показано
  exit /b 1
)

echo [check] самопроверка кодирования
if not exist ".check" mkdir ".check"
"zig-out\bin\zigrec.exe" encode-smoke ".check\encode.mp4" 90
if errorlevel 1 (
  echo [check] ПРОВАЛ: mp4 не получился или получился негодным
  exit /b 1
)

rem Обратная проверка чужим декодером: наш файл распаковывает ffmpeg, а мы
rem читаем таймкоды из распакованных кадров. Своим декодером проверять себя же
rem — значит не заметить общей ошибки в обе стороны. ffmpeg нужен только для
rem проверки, в самой программе его нет.
set "FFMPEG="
for /f "delims=" %%i in ('where ffmpeg 2^>nul') do if not defined FFMPEG set "FFMPEG=%%i"
if not defined FFMPEG (
  for /f "delims=" %%i in ('dir /b /s "%LOCALAPPDATA%\Microsoft\WinGet\Packages\ffmpeg.exe" 2^>nul') do if not defined FFMPEG set "FFMPEG=%%i"
)
if not defined FFMPEG (
  echo [check] ffmpeg не найден — обратная проверка таймкодов пропущена
) else (
  "%FFMPEG%" -y -v error -i ".check\encode.mp4" -pix_fmt bgra -f rawvideo ".check\encode.raw"
  if errorlevel 1 (
    echo [check] ПРОВАЛ: чужой декодер не смог открыть наш mp4
    exit /b 1
  )
  "zig-out\bin\zigrec.exe" verify-raw ".check\encode.raw" 384 64
  if errorlevel 1 (
    echo [check] ПРОВАЛ: таймкоды не пережили кодирование
    exit /b 1
  )
)

rem Открытие файла коротким путём. Редактор не должен поднимать в память
rem всю запись ради того, чтобы узнать её длину и дорожки, — но короткий путь
rem обязан сказать ровно то же, что и полное чтение. Разойдясь, они разойдутся
rem молча: окно покажет одну длительность, а играть будет другая.
echo [check] самопроверка быстрого открытия
"zig-out\bin\zigrec.exe" open-smoke ".check\encode.mp4"
if errorlevel 1 (
  echo [check] ПРОВАЛ: быстрое открытие разошлось с полным
  exit /b 1
)
"zig-out\bin\zigrec.exe" open-smoke ".check\sound.mp4"
if errorlevel 1 (
  echo [check] ПРОВАЛ: быстрое открытие разошлось с полным
  exit /b 1
)

rem Навигация. Меряем то, на что тратит время ОКНО: сколько занимает
rem просьба показать кадр. Она должна оставаться мгновенной независимо
rem от того, сколько длится само раскодирование.
echo [check] самопроверка навигации
"zig-out\bin\zigrec.exe" nav-smoke ".check\encode.mp4" 40
if errorlevel 1 (
  echo [check] ПРОВАЛ: окно ждёт декодер
  exit /b 1
)

rem Окно собирается целиком и меряется, не показываясь: «кнопка не влезла» —
rem ошибка, которую видно только глазами и только на той машине, где рамка
rem окна оказалась толще ожидаемой.
echo [check] самопроверка окна
"zig-out\bin\zigrec.exe" ui-smoke
if errorlevel 1 (
  echo [check] ПРОВАЛ: в окно поместилось не всё
  exit /b 1
)

rem Пульт съёмки: ширину кнопок мы считаем прикидкой по буквам, а подпись
rem рисует настоящий шрифт. Разойдутся — подпись обрежется молча, и на
rem пульте окажется кнопка «⏸ Пауз». Здесь меряет сама Windows.
echo [check] самопроверка пульта съёмки
"zig-out\bin\zigrec.exe" remote-smoke
if errorlevel 1 (
  echo [check] ПРОВАЛ: на пульте не всё читается
  exit /b 1
)

rem Системный звук: loopback молчит вместе с колонками, поэтому стенд сам
rem играет известный тон и ловит его. Без устройства вывода проверка
rem честно пропускается — сборочная машина бывает без колонок.
echo [check] самопроверка системного звука
"zig-out\bin\zigrec.exe" loopback-smoke
if errorlevel 1 (
  echo [check] ПРОВАЛ: системный звук не ловится
  exit /b 1
)

rem Микрофоны (#22): список устройств читается, проба «записать и сыграть»
rem проходит тем же путём, что кнопка в окне. Без микрофона или колонок
rem проба честно пропускается.
echo [check] самопроверка микрофонов и пробы
"zig-out\bin\zigrec.exe" devices-smoke
if errorlevel 1 (
  echo [check] ПРОВАЛ: список микрофонов не читается
  exit /b 1
)
"zig-out\bin\zigrec.exe" probe-smoke 1
if errorlevel 1 (
  echo [check] ПРОВАЛ: проба микрофона не проходит
  exit /b 1
)

rem Ключевые кадры (#24): наш разбор таблиц mp4 против I-кадров ffmpeg.
rem Файл — своя запись на шесть секунд: сверять есть что, а не один
rem кадр в начале. Код 3 у записи (пропуски кадров) здесь не важен.
if defined FFMPEG (
  echo [check] самопроверка ключевых кадров
  "zig-out\bin\zigrec.exe" record ".check\keys.mp4" --sec 6 --fps 30 --gop 30 --area 0,0,320,200 > nul
  rem Новый ffmpeg не знает -vsync, старый — -fps_mode: пробуем оба,
  rem иначе список I-кадров пуст и стенд врёт про расхождение.
  "%FFMPEG%" -i ".check\keys.mp4" -vf "select='eq(pict_type,I)',showinfo" -fps_mode passthrough -f null - > ".check\iframes.txt" 2>&1
  %SystemRoot%\System32\find.exe "pts_time" ".check\iframes.txt" > nul
  if errorlevel 1 "%FFMPEG%" -i ".check\keys.mp4" -vf "select='eq(pict_type,I)',showinfo" -vsync 0 -f null - > ".check\iframes.txt" 2>&1
  "zig-out\bin\zigrec.exe" keyframes-smoke ".check\keys.mp4" ".check\iframes.txt"
  if errorlevel 1 (
    echo [check] ПРОВАЛ: ключевые кадры разошлись с ffmpeg
    exit /b 1
  )
  rem Экспорт (#27): gate.mp4 (восемь ключевых, список правок) — клип с ключевого кадра без перекодирования
  rem и клип не с ключевого с перекодированием; ffmpeg раскодирует оба без ошибок.
  echo [check] самопроверка экспорта
  "zig-out\bin\zigrec.exe" export-smoke ".check\gate.mp4" ".check\export_pass.mp4"
  if errorlevel 1 (
    echo [check] ПРОВАЛ: экспорт без перекодирования
    exit /b 1
  )
  "zig-out\bin\zigrec.exe" export-smoke ".check\gate.mp4" ".check\export_re.mp4" --offkey
  if errorlevel 1 (
    echo [check] ПРОВАЛ: экспорт с перекодированием
    exit /b 1
  )
  rem Курсор из слоя (#91): экспорт с впечатыванием, ffmpeg вынимает кадр
  rem на полсекунде сырым BGRA, pixel-check ищет стрелку в 300,200.
  "zig-out\bin\zigrec.exe" export-smoke ".check\gate.mp4" ".check\export_burn.mp4" --burn
  if errorlevel 1 (
    echo [check] ПРОВАЛ: экспорт с курсором из слоя
    exit /b 1
  )
  "%FFMPEG%" -v error -ss 0.5 -i ".check\export_burn.mp4" -frames:v 1 -f rawvideo -pix_fmt bgra -y ".check\burn_frame.bgra" > nul 2>&1
  "zig-out\bin\zigrec.exe" pixel-check ".check\burn_frame.bgra" 1920 1080 302 206
  if errorlevel 1 (
    echo [check] ПРОВАЛ: в экспортированном кадре нет курсора из слоя
    exit /b 1
  )
  rem Аннотации (#28): экспорт с жёлтой надписью в середине кадра; ffmpeg вынимает
  rem кадр, pixel-color ждёт цвет подложки (жёлтый 0xE8C820 в BGR → R232 G200 B32)
  rem чуть правее и ниже левого верхнего угла надписи (960+30, 540+12).
  "zig-out\bin\zigrec.exe" export-smoke ".check\gate.mp4" ".check\export_annot.mp4" --annot
  if errorlevel 1 (
    echo [check] ПРОВАЛ: экспорт с аннотацией
    exit /b 1
  )
  "%FFMPEG%" -v error -ss 0.5 -i ".check\export_annot.mp4" -frames:v 1 -f rawvideo -pix_fmt bgra -y ".check\annot_frame.bgra" > nul 2>&1
  "zig-out\bin\zigrec.exe" pixel-color ".check\annot_frame.bgra" 1920 1080 990 552 232 200 32
  if errorlevel 1 (
    echo [check] ПРОВАЛ: в экспортированном кадре нет подложки аннотации
    exit /b 1
  )
  "%FFMPEG%" -v error -i ".check\export_pass.mp4" -f null - > ".check\export_errors.txt" 2>&1
  "%FFMPEG%" -v error -i ".check\export_re.mp4" -f null - >> ".check\export_errors.txt" 2>&1
  rem Пустой файл ошибок — ноль байт. Проверяем размер прямо в теле for:
  rem переменная, выставленная внутри скобок, до конца блока не видна.
  for %%A in (".check\export_errors.txt") do if not "%%~zA"=="0" (
    echo [check] ПРОВАЛ: ffmpeg нашёл ошибки в экспортированных файлах
    type ".check\export_errors.txt"
    exit /b 1
  )
)

rem Слой событий (#88): наш писатель и читатель, потом сторонний читатель
rem на Python — формат должен быть понятен не только нам.
echo [check] самопроверка слоя событий
"zig-out\bin\zigrec.exe" events-smoke ".check\smoke.events"
if errorlevel 1 (
  echo [check] ПРОВАЛ: слой событий не пишется или не читается
  exit /b 1
)
python "tools\check_events.py" ".check\smoke.events" --expect-area --min-moves 30
if errorlevel 1 (
  echo [check] ПРОВАЛ: сторонний читатель не принял слой событий
  exit /b 1
)

rem Автопанорама (#29): правило без мыши и настоящая запись с --follow
rem на две секунды — код пути должен хотя бы не падать.
echo [check] самопроверка автопанорамы
"zig-out\bin\zigrec.exe" pan-smoke
if errorlevel 1 (
  echo [check] ПРОВАЛ: автопанорама дёргается или выходит за экран
  exit /b 1
)
"zig-out\bin\zigrec.exe" record ".check\follow.mp4" --sec 2 --area 0,0,320,200 --follow > nul
if errorlevel 4 (
  echo [check] ПРОВАЛ: запись с --follow не удалась
  exit /b 1
)
rem Слой событий при записи (#89): рядом с записью лежит .events с областью
rem — читает сторонний читатель. Положений курсора не требуем: пока идёт
rem проверка, курсор бывает скрыт, а скрытый в слой не пишется.
python "tools\check_events.py" ".check\follow.events" --expect-area --min-moves 0
if errorlevel 1 (
  echo [check] ПРОВАЛ: запись не оставила слой событий или он негодный
  exit /b 1
)

rem Пауза записи (#96): настоящий рекордер, длинная и короткая пауза. Кадр,
rem снятый до паузы, не должен попасть в запись после неё — время кадра
rem тогда уходит назад, а писатель mp4 это глотает молча.
echo [check] самопроверка паузы записи
"zig-out\bin\zigrec.exe" pause-smoke ".check\pause.mp4"
if errorlevel 1 (
  echo [check] ПРОВАЛ: пауза рвёт время кадров
  exit /b 1
)

rem Замер себя (#30): две секунды 1080p60 — стенд должен отработать и
rem оставить строку таблицы; числа смотрят глазами в .check\bench.md.
echo [check] замер для сравнения
"zig-out\bin\zigrec.exe" bench-run 2 60 ".check\bench.mp4"
if errorlevel 1 (
  echo [check] ПРОВАЛ: замер не отработал
  exit /b 1
)

rem Часы плеера (#23): время идёт по отданным в колонки отсчётам.
echo [check] самопроверка часов плеера
"zig-out\bin\zigrec.exe" clock-smoke
if errorlevel 1 (
  echo [check] ПРОВАЛ: часы плеера врут
  exit /b 1
)

rem Значок, который никто не нарисовал, выглядит так же, как значок,
rem который просто не туда поставили: пустое место. А два похожих —
rem это два названия одного и того же.
echo [check] самопроверка значков
if not exist ".check" mkdir ".check"
"zig-out\bin\zigrec.exe" icons-smoke ".check\icons.png"
if errorlevel 1 (
  echo [check] ПРОВАЛ: со значками что-то не так
  exit /b 1
)

rem Захват окна обещает две вещи: окно найдётся по части заголовка
rem и область поедет за ним. Второе глазами не проверить: надо двигать
rem окно и смотреть, что снимается.
echo [check] самопроверка захвата окна
"zig-out\bin\zigrec.exe" window-smoke
if errorlevel 1 (
  echo [check] ПРОВАЛ: захват окна не работает
  exit /b 1
)

rem Сочетание клавиш: числа модификаторов и кодов мы выписали из заголовков
rem Windows руками, и сойдутся ли они с настоящими, в памяти не проверишь.
echo [check] самопроверка сочетания клавиш
"zig-out\bin\zigrec.exe" hotkey-smoke
if errorlevel 1 (
  echo [check] ПРОВАЛ: сочетание клавиш не разбирается
  exit /b 1
)

rem Где программа хранит своё и что она помнит об открытых файлах.
rem Признак Portable трогается по-настоящему и возвращается на место:
rem самопроверка не должна менять то, как человек настроил программу.
echo [check] самопроверка хранения и списков недавних
if not exist ".check" mkdir ".check"
"zig-out\bin\zigrec.exe" home-smoke
if errorlevel 1 (
  echo [check] ПРОВАЛ: способ хранения не переключается
  exit /b 1
)
"zig-out\bin\zigrec.exe" recent-smoke ".check\recent"
if errorlevel 1 (
  echo [check] ПРОВАЛ: списки недавних не пережили диск
  exit /b 1
)

rem Снимок кадра. Записываем эталонный кадр картинкой, а читает её ЧУЖАЯ
rem программа: ffmpeg распаковывает наш png обратно в пиксели, а verify-raw
rem достаёт из них номер кадра. Так проверяется весь путь целиком: заголовки,
rem сжатие, порядок цветов и направление строк.
echo [check] самопроверка снимка кадра
if not exist ".check" mkdir ".check"
"zig-out\bin\zigrec.exe" shot-smoke ".check\shot.png" 7
if errorlevel 1 (
  echo [check] ПРОВАЛ: снимок не записался
  exit /b 1
)
if defined FFMPEG (
  "%FFMPEG%" -y -v error -i ".check\shot.png" -pix_fmt bgra -f rawvideo ".check\shot.raw"
  if errorlevel 1 (
    echo [check] ПРОВАЛ: чужой декодер не открыл наш png
    exit /b 1
  )
  "zig-out\bin\zigrec.exe" verify-raw ".check\shot.raw" 384 64
  if errorlevel 1 (
    echo [check] ПРОВАЛ: в снимке оказался не тот кадр
    exit /b 1
  )
)

rem Запись GIF. Эталонные кадры с таймкодом складываем в петлю, читаем её
rem своим разбором и сверяем номера — а потом ту же петлю распаковывает
rem ffmpeg, и номера достаёт verify-raw. Палитра в GIF всего на 256 цветов,
rem и «съела ли она то, ради чего кадр записывали» — вопрос не праздный.
echo [check] самопроверка записи GIF
"zig-out\bin\zigrec.exe" gif-write-smoke ".check\stand.gif" 12
if errorlevel 1 (
  echo [check] ПРОВАЛ: петля GIF не записалась
  exit /b 1
)
if defined FFMPEG (
  "%FFMPEG%" -y -v error -i ".check\stand.gif" -pix_fmt bgra -f rawvideo ".check\stand.raw"
  if errorlevel 1 (
    echo [check] ПРОВАЛ: чужой декодер не открыл нашу петлю
    exit /b 1
  )
  "zig-out\bin\zigrec.exe" verify-raw ".check\stand.raw" 384 64
  if errorlevel 1 (
    echo [check] ПРОВАЛ: в петле не те кадры
    exit /b 1
  )
)

rem Архив проекта .zigrec. ZIP мы пишем сами, поэтому читает нас ЧУЖАЯ
rem программа: питон умеет ZIP из коробки и проверяет контрольные суммы.
rem Своим же читателем проверять свою запись — значит повторить ошибку
rem в обе стороны и ничего не заметить.
echo [check] самопроверка архива проекта
if not exist ".check" mkdir ".check"
"zig-out\bin\zigrec.exe" pack-smoke ".check\pack.zigrec"
if errorlevel 1 (
  echo [check] ПРОВАЛ: архив проекта не сошёлся
  exit /b 1
)
where python >nul 2>&1
if errorlevel 1 (
  echo [check] python не найден — чужая проверка архива пропущена
) else (
  python "tools\check_zip.py" ".check\pack.zigrec"
  if errorlevel 1 (
    echo [check] ПРОВАЛ: чужая программа не открыла наш архив
    exit /b 1
  )
)

rem Файл проекта. Тесты проверяют запись и чтение в памяти; здесь добавляется
rem диск: путь с русскими буквами, переводы строк, кодировка файла — всё то,
rem что в памяти не проверишь.
echo [check] самопроверка файла проекта
"zig-out\bin\zigrec.exe" project-smoke ".check\проект.zrs"
if errorlevel 1 (
  echo [check] ПРОВАЛ: проект не сошёлся после записи и чтения
  exit /b 1
)

rem Чтение чужих форматов. Проверяем на файлах, сделанных ЧУЖОЙ программой:
rem на своих записях мы бы проверяли себя собой и не заметили бы общей
rem ошибки. ffmpeg делает пять форматов из одного эталонного тона и куска
rem записи, а мы должны узнать каждый и найти в нём дорожки.
if defined FFMPEG (
  echo [check] самопроверка чтения форматов
  if not exist ".check\formats" mkdir ".check\formats"
  "%FFMPEG%" -y -v error -i ".check\audio\tone_6.wav" -c:a libmp3lame -b:a 128k ".check\formats\t.mp3"
  "%FFMPEG%" -y -v error -i ".check\audio\tone_6.wav" -c:a flac ".check\formats\t.flac"
  "%FFMPEG%" -y -v error -i ".check\audio\tone_6.wav" -c:a libvorbis ".check\formats\t.ogg"
  "%FFMPEG%" -y -v error -i ".check\sound.mp4" -c copy ".check\formats\t.mov"
  "%FFMPEG%" -y -v error -i ".check\sound.mp4" -c:v mpeg4 -c:a mp3 ".check\formats\t.avi"
  rem GIF делаем из куска записи: свой разбор должен узнать кадры и их
  rem выдержку в файле, который собрала чужая программа.
  "%FFMPEG%" -y -v error -t 1 -i ".check\encode.mp4" -vf "fps=10,scale=160:-1" ".check\formats\t.gif"
  for %%f in (mp3 flac ogg mov avi gif) do (
    "zig-out\bin\zigrec.exe" info ".check\formats\t.%%f"
    if errorlevel 1 (
      echo [check] ПРОВАЛ: не прочитан формат %%f
      exit /b 1
    )
  )
  rem Свой разбор GIF сверяем с чужим декодером точка в точку. Ошибка
  rem в словаре LZW не роняет чтение и не делает картинку пустой: первые
  rem строки выходят верными, а дальше кадр тихо расползается. Заметить
  rem это можно только сравнением с тем, кто читает формат правильно.
  "zig-out\bin\zigrec.exe" gif-smoke ".check\formats\t.gif" ".check\gif_frame.png"
  if errorlevel 1 (
    echo [check] ПРОВАЛ: GIF не прочитался
    exit /b 1
  )
  "%FFMPEG%" -y -v error -i ".check\formats\t.gif" -vframes 1 -pix_fmt bgra -f rawvideo ".check\gif_from_ffmpeg.raw"
  "%FFMPEG%" -y -v error -i ".check\gif_frame.png" -pix_fmt bgra -f rawvideo ".check\gif_from_us.raw"
  fc /b ".check\gif_from_ffmpeg.raw" ".check\gif_from_us.raw" >nul
  if errorlevel 1 (
    echo [check] ПРОВАЛ: наш кадр GIF не совпал с чужим декодером
    exit /b 1
  )
  echo [check] кадр GIF совпал с чужим декодером точка в точку

  "zig-out\bin\zigrec.exe" info ".check\audio\tone_6.wav"
  if errorlevel 1 (
    echo [check] ПРОВАЛ: не прочитан формат wav
    exit /b 1
  )
)

rem Адреса прослушивания. «Разбирается» и «на нём можно слушать» — разные
rem вещи: IPv6 на машине может быть выключен. Поэтому поднимаем ожидание
rem входящего по-настоящему и по-настоящему в него стучимся.
echo [check] самопроверка адресов прослушивания
"zig-out\bin\zigrec.exe" listen-smoke
if errorlevel 1 (
  echo [check] ПРОВАЛ: адрес слушает, но не отвечает
  exit /b 1
)

rem Сервер MCP. Проверяем не «открылся ли порт», а то, ради чего он сделан:
rem что на той стороне отвечает работающее окно и что ответы — годный JSON.
rem Окно поднимаем с ключом --server: кнопку тут нажимать некому.
echo [check] самопроверка сервера MCP
start "" /b "zig-out\bin\zigrec.exe" ui --tray --server
rem Пауза без timeout: тот отказывается работать, когда ввод перенаправлен.
ping -n 5 127.0.0.1 >nul
"zig-out\bin\zigrec.exe" mcp-smoke
set "MCPRC=%errorlevel%"
taskkill /f /im zigrec.exe >nul 2>&1
if not "%MCPRC%"=="0" (
  echo [check] ПРОВАЛ: сервер MCP не ответил как надо
  exit /b 1
)

rem Звуковая дорожка внутри mp4. Пишем в файл известный рисунок — тишина и два
rem всплеска в назначенные секунды, — вынимаем дорожку чужим декодером и меряем
rem не только уровень, но и МОМЕНТ каждого всплеска. Уровень отвечает на вопрос
rem «звук дошёл», момент — на вопрос «звук не разъехался с видео», а это то,
rem что человек замечает первым.
if defined FFMPEG (
  echo [check] самопроверка звуковой дорожки в mp4
  "zig-out\bin\zigrec.exe" encode-smoke ".check\sound.mp4" 90 --audio
  if errorlevel 1 (
    echo [check] ПРОВАЛ: mp4 со звуком не получился
    exit /b 1
  )
  "%FFMPEG%" -y -v error -i ".check\sound.mp4" -map 0:a:0 -c:a pcm_s16le ".check\sound_track.wav"
  if errorlevel 1 (
    echo [check] ПРОВАЛ: чужой декодер не нашёл в файле звуковой дорожки
    exit /b 1
  )
  "zig-out\bin\zigrec.exe" audio-sync ".check\sound_track.wav"
  if errorlevel 1 (
    echo [check] ПРОВАЛ: звук в файле не тот или разъехался с видео
    exit /b 1
  )
)

rem Системный звук сквозь подачу и кодировщик: поймать в память мало,
rem в файл он идёт через смешение и AAC, и любой из них может молча потерять звук.
rem Дорожку вынимает чужой декодер, интервал всплесков мерим мы.
if defined FFMPEG (
  echo [check] системный звук сквозь запись
  "zig-out\bin\zigrec.exe" loopback-record ".check\system.mp4"
  if errorlevel 1 (
    echo [check] ПРОВАЛ: системный звук не записался
    exit /b 1
  )
  if exist ".check\system.mp4" (
    "%FFMPEG%" -y -v error -i ".check\system.mp4" -map 0:a:0 -c:a pcm_s16le ".check\system_track.wav"
    if errorlevel 1 (
      echo [check] ПРОВАЛ: ffmpeg не вынул системную дорожку
      exit /b 1
    )
    "zig-out\bin\zigrec.exe" onset-spacing ".check\system_track.wav" 1000
    if errorlevel 1 (
      echo [check] ПРОВАЛ: всплески системного звука разъехались
      exit /b 1
    )
  )
)

rem Две звуковые дорожки в одном mp4 (#21): микрофон и колонки врозь.
rem Считаем дважды: нашим читателем и ffmpeg — сойтись должны оба.
rem Без микрофона на машине дорожка будет одна — стенд об этом скажет.
if defined FFMPEG (
  echo [check] две звуковые дорожки в одном файле
  "zig-out\bin\zigrec.exe" loopback-record ".check\system2.mp4" --separate
  if errorlevel 1 (
    echo [check] ПРОВАЛ: запись двумя дорожками не удалась
    exit /b 1
  )
  if exist ".check\system2.mp4" (
    rem Сколько дорожек ждём — зависит от микрофона: считаем их ffmpeg-ом
    rem и требуем, чтобы наш читатель насчитал столько же.
    set "AUDIO_N=0"
    rem Сперва в файл, потом счёт: строка в for /f, начинающаяся с кавычки,
    rem теряет кавычки и не находит ffmpeg — счёт выходил нулём на исправном файле.
    "%FFMPEG%" -i ".check\system2.mp4" > ".check\system2_streams.txt" 2>&1
    rem find полным путём: из Git Bash в PATH первым стоит GNU find, и он обходит весь диск.
    for /f %%n in ('%SystemRoot%\System32\find.exe /c "Audio:" ^< ".check\system2_streams.txt"') do set "AUDIO_N=%%n"
    echo [check] ffmpeg насчитал звуковых дорожек: !AUDIO_N!
    if "!AUDIO_N!"=="0" (
      echo [check] ПРОВАЛ: ffmpeg не видит звука в файле
      exit /b 1
    )
    "zig-out\bin\zigrec.exe" tracks-check ".check\system2.mp4" !AUDIO_N!
    if errorlevel 1 (
      echo [check] ПРОВАЛ: наш читатель и ffmpeg насчитали разное число дорожек
      exit /b 1
    )
  )
)

rem Звук проверяем на синтезе, а не на живом микрофоне: микрофон у каждого свой
rem и шумит по-разному, а синус заданной амплитуды — проверяемое число.
if defined FFMPEG (
  echo [check] самопроверка звука на эталонных тонах
  if not exist ".check\audio" mkdir ".check\audio"
  call :tone 0.99 tone_0 -0.09
  if errorlevel 1 exit /b 1
  call :tone 0.5 tone_6 -6.02
  if errorlevel 1 exit /b 1
  call :tone 0.1 tone_20 -20.0
  if errorlevel 1 exit /b 1
  call :tone 0.001 tone_60 -60.0
  if errorlevel 1 exit /b 1
) else (
  echo [check] ffmpeg не найден — проверка звука на тонах пропущена
)

rem Громкость и кривая: нарисованная линия, которая ничего не меняет
rem в звуке, выглядит в окне точно так же, как работающая.
if defined FFMPEG (
  echo [check] самопроверка громкости и кривой
  if not exist ".check\audio" mkdir ".check\audio"
  "%FFMPEG%" -y -v error -f lavfi -i "aevalsrc=0.5*sin(2*PI*1000*t):d=10:s=48000" -c:a pcm_s16le ".check\audio\mix_src.wav"
  if errorlevel 1 (
    echo [check] ПРОВАЛ: не получилось сделать тон для сведения
    exit /b 1
  )
  "zig-out\bin\zigrec.exe" mix-smoke ".check\audio\mix_src.wav" ".check\audio\mix.wav"
  if errorlevel 1 (
    echo [check] ПРОВАЛ: громкость не идёт по кривой
    exit /b 1
  )
  rem Своим же читателем проверять свою запись — значит повторить
  rem ошибку в обе стороны и ничего не заметить.
  where python >nul 2>&1
  if errorlevel 1 (
    echo [check] python не найден — чужая проверка смеси пропущена
  ) else (
    python "tools\check_mix.py" ".check\audio\mix.wav" -20 -6.02
    if errorlevel 1 (
      echo [check] ПРОВАЛ: чужой читатель не согласен с нашей смесью
      exit /b 1
    )
  )
) else (
  echo [check] ffmpeg не найден — проверка громкости пропущена
)

echo [check] ВСЁ ЗЕЛЁНОЕ
exit /b 0

goto :eof

rem %1 — амплитуда, %2 — имя, %3 — ожидаемый уровень в децибелах
:tone
"%FFMPEG%" -y -v error -f lavfi -i "aevalsrc=%~1*sin(2*PI*1000*t):d=1:s=48000" -c:a pcm_s16le ".check\audio\%~2.wav"
if errorlevel 1 (
  echo [check] ПРОВАЛ: не получилось сделать эталонный тон %~2
  exit /b 1
)
"zig-out\bin\zigrec.exe" audio-check ".check\audio\%~2.wav" %~3
if errorlevel 1 (
  echo [check] ПРОВАЛ: уровень тона %~2 не сошёлся
  exit /b 1
)
exit /b 0
