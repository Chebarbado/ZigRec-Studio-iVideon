# 7. Видео, превью и звук

**Теги:** #видео #FLV #H264 #H265 #FFmpeg #WebSocket #protobuf #Opus #JNI

Как приложение получает живое видео, архив, картинки-превью и как передаёт голос на камеру.

**Главное:**

* Единственный путь видео — **FLV поверх HTTP(S)**: обычный `GET` по подписанному URL, в теле ответа — поток FLV с H.264/H.265 и AAC/MP3/G.711.
* Поток скачивает и разбирает **собственный C++-плеер Ivideon** (`libivplayerjni.so`: Boost.Beast + свой FLV-демуксер). FFmpeg в приложении собран **без единого демуксера и протокола** — только декодеры.
* ExoPlayer, WebRTC, HLS, RTSP, MJPEG в приложении **нет**.
* «Поток превью» для сетки камер — **WebSocket с protobuf-сообщениями**, внутри которых JPEG.

Достоверность: Java-часть — **[код]**; сведения о нативной части получены **по строкам в `.so`**, без дизассемблирования, сетевых дампов нет. Контейнер FLV — **[вывод]** из имён классов (`FlvHandler`, `flv::VideoPacket`…) и сообщений парсера; очень надёжный, но живым запросом не подтверждён.

## 7.1. Эндпоинты

| что | запрос | авторизация | ответ |
|---|---|---|---|
| живое видео | `GET /cameras/{cameraId}/live_stream?q=&video_codecs=&audio_codecs=` | `access_token` + подпись | поток FLV |
| архив | `GET /cameras/{cameraId}/archive_stream?start_time=&end_time=&speed=&q=&video_codecs=&audio_codecs=` | `access_token` + подпись | поток FLV |
| кадр-превью | `GET /cameras/{cameraId}/live_preview?q=` | `access_token` + подпись | JPEG |
| поток превью | `POST /cameras/{cameraId}/live_preview?op=STREAM&fps=&q=` | `access_token` | JSON `{"url": "ws(s)://…"}` |
| миниатюры события | `GET /events/{eventId}/thumbnails?qty=&width=&height=&columns=` | `Authorization: Bearer` | картинка (спрайт из `qty` кадров в `columns` столбцов **[вывод]**) |
| картинка по готовому URL | `GET <url>[?h=<высота>]` | `Authorization: Bearer` | картинка |
| голос на камеру | `POST /cameras/{cameraId}/voice_message?op=START` | `access_token` | JSON `{"url": "…"}` |

Подпись — в [05-url-signing.md](05-url-signing.md). Определения: `p000/InterfaceC2236lu.java:78-81, 105-108, 275-277, 19-21`; `p000/InterfaceC2345or.java`.

### Параметры

| параметр | значения | примечание |
|---|---|---|
| `q` | `0` low, `1` medium, `2` high | enum `p000/sw4.java`, сериализуется числом. В плеере хранится в SharedPreferences `player/quality`, по умолчанию `2`. Для превью приложение всегда шлёт `0` |
| `video_codecs` | `h265,h264` | константа, `PlayerController.java:790` — клиент объявляет, что умеет декодировать; порядок = предпочтение **[вывод]** |
| `audio_codecs` | `pcmu,pcma,aac,mp3` | константа, `PlayerController.java:791` |
| `start_time` | Unix-время, **миллисекунды** | точка начала/перемотки (`dateFrom.getTime()`, `PlayerController.java:834`) |
| `end_time` | Unix-время, мс; опц. | приложение шлёт `start + min(1 ч × speed, now − start)` (строки 813–819) |
| `speed` | `1, 2, 4, 8, 16`; опц. | ускорение архива. Сервер может выдать иную скорость — фактическая приходит в событии плеера |
| `fps` | float | для `live_preview?op=STREAM`; приложение шлёт `1.0` |

Хотите видео только в H.264 (например, плеер не умеет HEVC-in-FLV) — передайте `video_codecs=h264` **[вывод; проверить]**.

## 7.2. Как приложение открывает поток

1. `PlayerController.m4284C0` (строки 785–837). Перед сборкой URL проверяется токен: `i85.m10135f()` считает его истёкшим **за 300 с до реального срока** (`p000/i85.java:218-240`); если истёк — сначала refresh, потом URL.
2. Retrofit-запрос **не выполняется**: `C2199ku.m14125h` (`p000/C2199ku.java:152`) прогоняет его через интерцептор (`access_token`, `cseq`, `cs`) и забирает строку URL.
3. `IvPlayer.nativeReset` → `nativeSetMedia(handle, url, …)` → `nativeStart` (`p000/kr2.java:84-102`, `p000/t75.java`).

<!-- figure: video-pipeline | Путь видео от URL до экрана -->

Java не передаёт плееру ни заголовков, ни User-Agent — **вся авторизация в query-строке URL**. В `.so` есть литерал `Boost.Beast/359` рядом с именем заголовка `User-Agent` — вероятно, это и уходит на сервер **[вывод]**.

### Аргументы `nativeSetMedia`

Сигнатура `(JLjava/lang/String;ZZZIIII)V`:

| режим | вызов |
|---|---|
| live (в пути URL нет `archive`) | `nativeSetMedia(h, url, true, false, false, 15, 5, 1000, 5)` |
| архив | `nativeSetMedia(h, url, false, false, false, 15, 5, 0, 0)` |

Смысл семи последних аргументов из Java не определить (имён нет, `.so` без символов). **[гипотеза]**: первый `boolean` — «это live», `1000, 5` — целевые задержка/буфер для live.

## 7.3. Формат потока (по строкам `libivplayerjni.so`)

* Схемы URL: только `http` и `https` (`expected URL scheme 'http' or 'https' but was '`).
* HTTP-клиент — Boost.Asio/Beast/URL со статически слинкованным BoringSSL; сам следует редиректам с ограничением (`too many redirects:`, `abort redirect from 'https' to '`). Сертификаты — системные (`/apex/com.android.conscrypt/cacerts`), пиннинга в плеере по строкам не видно.
* Демуксер — свой: классы `FlvHandler`, `flv::Packet`, `flv::VideoPacket`, `flv::AudioPacket`, `flv::Observer`; сообщения `flv parser error:`, `flv_tag_video: invalid video codec`, `nalu size not valid:`, `ERROR: no aac config in packet or in metadata`, `codec in metadata is not equal to codec of packet`.
* Вероятные ключи метаданных потока: `width`, `height`, `framerate`, `frameDuration`, `speed`, `syncTime`, `fragmentPosition`, `videocodecid`, `audiocodecid`, `audiosamplerate`, `audiochannels`. Строки `onMetaData` в `.so` нет — как именно передаются метаданные, не установлено.
* **Нестандартные ключи `syncTime`, `fragmentPosition`, `speed`** — видимо, источник абсолютного времени кадра и позиции в архиве (см. события 7 и 8 ниже). Стандартный FLV-плеер их проигнорирует: видео покажет, а привязку к реальному времени — нет.
* Как сигнализируется HEVC внутри FLV (старый «китайский» codec id 12 или Enhanced RTMP/extended header) — **не установлено**; FourCC `hvc1`/`hev1` в строках нет. От этого зависит, откроет ли поток H.265 обычный ffmpeg/VLC.
* Декодирование: аппаратное через MediaCodec с откатом на программное (`no hw decoders found or configured, fallback to sw decoder`). Вывод — EGL/GLES, звук — Oboe.

### FFmpeg в приложении

Версия 8.1 (`Lavf62.12.100`), строка конфигурации зашита в библиотеки:

```text
--disable-all --disable-network --enable-avutil --enable-avcodec --enable-avformat
--enable-swscale --enable-swresample --enable-decoder='h264,hevc'
--enable-decoder='aac,mp3,pcm_alaw,pcm_mulaw' --enable-jni --enable-mediacodec
--enable-decoder='h264_mediacodec,hevc_mediacodec'
```

Ноль демуксеров, ноль протоколов. Это уточняет первоначальный вывод («URL открывает FFmpeg»): URL открывает **плеер Ivideon**, FFmpeg только декодирует.

### Нативные библиотеки (`config.arm64_v8a.apk`, `lib/arm64-v8a`)

| библиотека | байт | назначение |
|---|---|---|
| `libivplayerjni.so` | 4 021 112 | плеер Ivideon (исходный путь в строках: `/src/android-iv-player/`) |
| `libavcodec.so` | 2 730 544 | FFmpeg 8.1, декодеры |
| `libavformat.so` | 247 424 | FFmpeg, фактически пустая |
| `libavutil.so`, `libswscale.so`, `libswresample.so` | 738 352 / 1 064 648 / 99 704 | FFmpeg |
| `libopusjni.so` | 514 416 | кодер libopus 1.5.2 для передачи голоса |
| `libbarhopper_v3.so` | 4 946 720 | ML Kit, сканер штрих-кодов (мастер привязки) |
| `libcrashlytics*.so`, CameraX, `androidx.graphics.path`, `datastore_shared_counter` | — | инфраструктура |

## 7.4. JNI-интерфейс `IvPlayer`

`com/ivideon/sdk/player/p014iv/core/IvPlayer.java`. Полезен как спецификация «что должен уметь плеер».

| метод | назначение |
|---|---|
| `nativeInit()`, `long nativeSetup(WeakReference)` | инициализация; возвращает дескриптор, `0` = освобождён |
| `nativeSetMedia(long, String url, Z, Z, Z, I, I, I, I)` | задать URL (см. 7.2) |
| `nativeSetSurface(long, Surface)` | поверхность вывода |
| `nativeStart` / `nativePause` / `nativeStop` / `nativeReset` / `nativeRelease` | управление; `Reset` вызывается перед каждым `SetMedia` |
| `boolean nativeIsPlaying`, `long nativeGetCurrentPosition` | позиция — мс от начала потока **[вывод]** |
| `nativeGetVideoWidth/Height` | размер кадра |
| `nativeSetVideoScaleType(int)` | приложение всегда ставит `1`; смысл значений неизвестен |
| `nativeSetVideoTransform(int)` | `0` identity, `1` mirror-H, `2` mirror-V, `3` rot90, `4` rot180, `5` rot270, `6` transpose, `7` anti-transpose (`p000/p75.java`). Приложение шлёт только rot180 — когда у камеры задан поворот 180° |
| `nativeSetCrop(x, y, w, h)` | цифровой зум |
| `nativeSetVolume(float)` | приложение использует только 0.0/1.0 |
| `boolean nativeTakeSnapshot(Bitmap)` | снимок текущего кадра в ARGB_8888 |

**Метода перемотки нет**: перемотка архива, смена качества и скорости — это всегда **новый URL** и пересоздание потока.

### События из нативного кода

`postEventFromNative(ref, what, a, b)` (`IvPlayer.java:106-141`):

| what | событие | данные |
|---|---|---|
| 1 | Started | — |
| 2 | Paused | — |
| 3 | Stopped | — |
| 4 | EndReached | — |
| 5 | Error | `a` — код; Java его **не читает**, значения неизвестны |
| 6 | VideoSizeChanged | `a` = ширина, `b` = высота |
| 7 | AbsoluteTimeChanged | `a` = абсолютное время кадра, Unix мс (live) |
| 8 | ArchiveTimeChanged | `a` = `fragmentPosition` (Unix мс), младшие 32 бита `b` = `fragmentDuration`, старшие = фактическая `speed` |

Текущее время на шкале приложение считает само, опрашивая позицию каждые `500 мс / speed` (`p000/e97.java:41-73`):

* live: `absoluteTime + (pos − posНаМоментСобытия)`; до первого события 7 — `времяЗапроса + pos`;
* архив: `min(fragmentPosition + (pos − posНаМоментСобытия) × speed, fragmentPosition + fragmentDuration)`.

## 7.5. Логика воспроизведения (для своего плеера)

**Архив.** Запрашивается окно не более часа × скорость. По `EndReached` приложение ищет на таймлайне следующую запись и запрашивает новый URL с её начала (`p000/d97.java:308-354`). Таймлайн — `POST /cameras/{id}/archive_timeline?op=GET {"start_time": <мс>, "end_time": <мс>}`, календарь — `archive_calendar?op=GET`; см. [06-api-reference.md](06-api-reference.md). Ускорение доступно, только если у камеры есть возможность `speed_play` (`p000/C2363p8.java:902-941`).

<!-- figure: archive-windows | Архив воспроизводится окнами; перемотка и конец окна — новый URL -->

**Переподключение:**

| ситуация | реакция |
|---|---|
| событие Error, камера онлайн, режим live | немедленный новый URL (`p000/fr2.java:350-361`) |
| EndReached в live | новый URL, пока счётчик попыток < 3; затем состояние ошибки (`d97.java:355-374`) |
| ожидание старта | проверка каждые 500 мс; после 3 неудач или если камера офлайн — состояние OFFLINE |
| камера в списке стала online; возврат в приложение (`onStart`) | новый URL |
| сменился токен во время воспроизведения | лог `ANTIEXPIRED…`, новый URL (`PlayerController.java:2276-2293`) |
| нет сети | состояние ошибки |

Специальной обработки 401/403 посреди потока нет — такой случай попадает в общие ветки Error/EndReached. Срок жизни URL **[вывод]** равен сроку жизни `access_token`.

Состояния UI (`p000/d97.java`): `PROGRESS`, `PLAY`, `PAUSED`, `BUFFERING`, `COMPLETED`, `ERR`, `OFFLINE`, `PAUSED_TO_SHOW_ARCHIVE_EXPORT_UI`. Процент буферизации нативный плеер не сообщает — Java рисует 0 при старте и 100 по Started.

## 7.6. Превью

### Одиночный кадр

`GET /cameras/{id}/live_preview?q=0` — подписанный URL, в ответе байты изображения, которые приложение отдаёт в `BitmapFactory` (при неудаче лог `decode jpeg failed`, `p000/ca1.java:84,188`) → формат **JPEG [вывод]**. Дополнительных заголовков нет: набор `Cache-Control: no-cache` в `C2199ku.java:44` объявлен, но ни к чему не прикреплён — в вызов передаётся пустой набор (`f26454i`). Это самый простой способ получить картинку с камеры — на нём строится `zig-client`.

### Поток кадров (сетка камер)

```http
POST /cameras/{id}/live_preview?op=STREAM&fps=1.0&q=0
→ {"url": "wss://…"}
```

Это **не** `multipart/x-mixed-replace`. Клиент открывает **WebSocket** по полученному URL (`p000/et5.java:40-60`): схема `ws(s)` переписывается в `http(s)`, заголовки апгрейда добавляются вручную, включая `Sec-WebSocket-Extensions: x-webkit-deflate-frame` и фиксированный User-Agent Chrome 27. Заголовка авторизации нет — значит, авторизация зашита в выданном URL **[вывод]**.

Каждое бинарное сообщение — protobuf (`p000/k06.java:117-131`):

```protobuf
message Envelope { google.protobuf.Any payload = 1; }   // p000/r66.java
message Frame    { bytes image = 1; }                   // p000/mg7.java — разбирается из Any.value
```

<!-- figure: ws-preview | Поток превью: WebSocket, protobuf и JPEG внутри -->

`image` — JPEG; `Any.type_url` клиент игнорирует. Один сокет на камеру; новый закрывает предыдущий (`p000/dt5.java`, `p000/b28.java:205-211`).

### Клипы событий

Проигрываются штатным `android.media.MediaPlayer` по URL из API с заголовком `Authorization: Bearer <access_token>` (`p000/yu8.java:166-173`, `p000/ip3.java:944-955`). Формат клипа из кода не виден (раз его открывает `MediaPlayer` — вероятно, MP4 **[гипотеза]**).

## 7.7. Передача голоса на камеру

```http
POST /cameras/{cameraId}/voice_message?op=START
{"mode": "message" | "realtime", "codec": "opus", "frame_size": 480}
→ {"url": "…"}
```

<!-- figure: voice-pipeline | Передача голоса на камеру -->

* `mode`: `realtime`, если у камеры есть возможность `push_to_talk_2`, иначе `message` (`p000/du3.java:196-203`, enum `p000/lo7.java`). Лимит записи: 15 с для `message`, без лимита для `realtime` (`p000/bpa.java:65-75`).
* Захват: `AudioRecord`, **8000 Гц, моно, PCM16** (`p000/to7.java:69-86`).
* Кодер: libopus 1.5.2, `OPUS_APPLICATION_VOIP` (2048), `OPUS_SET_SIGNAL = OPUS_SIGNAL_VOICE`; кадр **480 сэмплов = 60 мс**, выход ≤ 1276 байт.
* Транспорт: **один HTTP `POST <url>` с потоковым телом** без `Content-Type` (`p000/zoa.java:73-86`). Каждый Opus-пакет — отдельный `write` + `flush`. Никакого контейнера и префиксов длины приложение не добавляет. **[вывод]**: поверх HTTP/1.1 это chunked-кодирование, «один чанк = один Opus-пакет», и сервер, возможно, полагается на границы чанков. Не-2xx → ошибка `Unsuccessful response`.
* Операции STOP нет: сообщение заканчивается, когда закрывается тело запроса.

Часть этой логики восстановлена из fallback-дампа jadx (классы `apa`, `fm8` обычным режимом не декомпилируются).

## 7.8. Не установлено

* смысл аргументов `nativeSetMedia`, коды `Error(what)`, значения scale type;
* сигнализация HEVC в FLV и способ передачи метаданных (`syncTime`, `fragmentPosition`);
* размеры буферов, политика задержки и таймауты нативного клиента;
* вид URL для WebSocket-превью и голосового канала (хост, авторизация);
* **откроет ли подписанный `live_stream` обычный ffplay/VLC/mpv** — первая практическая проверка. Ожидание: H.264 + AAC — да; H.265 — зависит от способа сигнализации.
