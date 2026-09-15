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
  for %%f in (mp3 flac ogg mov avi) do (
    "zig-out\bin\zigrec.exe" info ".check\formats\t.%%f"
    if errorlevel 1 (
      echo [check] ПРОВАЛ: не прочитан формат %%f
      exit /b 1
    )
  )
  "zig-out\bin\zigrec.exe" info ".check\audio\tone_6.wav"
  if errorlevel 1 (
    echo [check] ПРОВАЛ: не прочитан формат wav
    exit /b 1
  )
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
