# 11. Карта кода

**Теги:** #карта_кода #p000 #обфускация #jadx

Где что лежит в `decompiled-ivideon-3.7.1/sources/`. Имена вида `C2199ku` стабильны для **jadx 1.5.6 с `--deobf`**; в скобках — настоящее имя класса в DEX (из комментария `renamed from`), оно не зависит от версии jadx. Если у класса есть «говорящий» `toString()`, оттуда взято исходное имя.

Как читать такие классы — [01-methodology.md](01-methodology.md), раздел 1.5.

## 11.1. Сервисные интерфейсы (точки входа)

| файл | содержимое |
|---|---|
| `p000/InterfaceC2236lu.java` (`lu`) | **основной сервис API5**, ~75 методов |
| `p000/InterfaceC2345or.java` (`or`) | картинки: `live_preview`, миниатюры, загрузка по URL |
| `p000/jc0.java` | `POST /auth/oauth/token` |
| `p000/tl7.java` | публичные: шаги 2FA (динамический URL), регистрация, сброс пароля, конфиг формы |
| `p000/qm2.java` | `/customer_clouds?op=FIND` |
| `p000/cv4.java` | `/idam?op=SHARE` — доступ к камере по номеру телефона |
| `p000/pp0.java`, `p000/vx8.java`, `p000/e26.java` | баннеры, site security, маркетинг |

## 11.2. Ядро сети и сессии

| файл | роль |
|---|---|
| `p000/i85.java` | ядро SDK: OkHttpClient (76–92), Gson и адаптеры (91–120), токен, проверка срока (218–240), блокировка обновления (243–295) |
| `p000/k85.java` | сборка `i85`, выбор хостов по режиму (47–151) |
| `p000/l21.java` | константы: хосты, бренды, права для шаринга, email поддержки |
| `p000/yl6.java` | набор сервисов на токен; создаёт `C2199ku` с `api_host` (28) |
| `p000/or7.java` | нормализация `api_host` → `https://…` (167–171) |
| `p000/C2199ku.java` (`ku`) | «сессия API»: base URL, сервисы, интерцептор; `m14125h` (152) — получение подписанного URL без выполнения запроса |
| `p000/zn3.java` | фабрика Retrofit-сервисов |
| `p000/ek6.java` | `NetworkCall<T>` — обёртка вызова |
| `p000/e21.java` | выполнение: повторы (81–143), 401 → refresh (86–103), разбор ошибок (385–482) |
| `p000/g58.java` → `mo7583n` (396–467) | **интерцептор авторизации и подписи** |
| `p000/zbc.java` → `m22152b` (40–43) | путь для подписи: `"/" + join(pathSegments)` |
| `p000/C2504t.java` → `case 1` (119–138) | `signWithSecret`: HMAC-SHA1 |
| `p000/kr6.java` → `kr6(C2504t)` (626–647) | генерация 8-символьного id сессии |
| `p000/ps4.java`, `e82.java`, `g08.java`, `a40.java`, `fo4.java`, `v28.java` | OkHttp: `HttpUrl`, `HttpUrl.Builder`, `Request`, `Request.Builder`, `Headers`, `ResponseBody` |
| `p000/qs6.java`, `p000/ns7.java` | OkHttp: `OkHttpClient.Builder`, `BridgeInterceptor` (User-Agent `okhttp/5.3.2`) |

## 11.3. Авторизация

| файл | роль |
|---|---|
| `p000/qv5.java` → `qv5(i85, ry1)` (697–701), `m17621g` (358–366) | форма OAuth: поля клиента/устройства, `grant_type`, `trusted_device` |
| `p000/C2552ua.java` (63–81) | `Authorization: Basic base64("android-client:")` |
| `p000/fr7.java`, `p000/C2470s2.java` (`s2`) | модель токена; `C2470s2` добавляет флаг наличия `hmac_secret` и подписчик |
| `p000/h85.java` | конечный автомат обновления токена (лог-строки `Update token: …`) |
| `p000/ob0.java` | хранение токена в SharedPreferences, состояние входа |
| `p000/ic0.java` | вход, 2FA (`SELECT` 645, `RESEND` 581, `SUBMIT` 715), выход, отзыв (180–183, 345–348) |
| `p000/sl7.java` (23–34) | сборка динамических URL 2FA |
| `p000/j5a.java`, `bb0.java`, `eb0.java`, `b18.java`, `j99.java`, `ta0.java` | DTO 2FA: вызов, метод, состояние, тела запросов |
| `p000/ua0.java`, `p000/va0.java` | тело и классификация ошибок OAuth |
| `p000/C2270mr.java` | адаптер ответа токена / вызова 2FA (**не декомпилируется**, нужен fallback-режим) |
| `p000/ry1.java`, `p52.java`, `q10.java` | идентификаторы устройства: `device_type`, `device_name`, Firebase Installation ID |
| `p000/xt8.java` | тело регистрации |
| `p000/C2582v2.java` | десериализатор ресурса access-token |

## 11.4. Формат данных и ошибки

| файл | роль |
|---|---|
| `p000/C2619w2.java` | адаптеры: конверт успеха (64–114), распаковка `items` (131–143), словарь-по-id (144–165) |
| `p000/ld3.java` (364–380) | фабрика конвертеров; обработка `@kr7` |
| `p000/nr7.java` | «сырой» JSON-результат для `@kr7` |
| `p000/nq2.java`, `p000/C2647wu.java` | даты: чтение (секунды/мс), запись (секунды с дробью) |
| `p000/un6.java`, `p000/sn6.java` | пустой результат |
| `p000/ud7.java` | `turned_off_until` |
| `p000/z10.java` | дата `yyyy-MM-dd` |
| `p000/C0334eu.java`, `p000/C2382pr.java` | разбор и модель `Api5Error` |
| `p000/C0297du.java` (19, 38–73) | **таблица `code` → класс ошибки**, правило 401 |
| `p000/xw8.java` | таблица ошибок site security |
| `p000/wm3.java` | ошибки для не-JSON ответов |
| `com/ivideon/sdk/network/data/error/` | иерархия ошибок (имена сохранены), базовый `NetworkError` |
| `p000/C2233lr.java`, `C0258cr.java`, `C2196kr.java`; `com/ivideon/sdk/network/service/p013v4/` | наследие API4 |

Аннотации: `wy6` POST, `mg4` GET, `g47` Path, `fp7` Query, `ey0` Body, `iba` Url, `xa4` FormUrlEncoded, `zz3` FieldMap, `bo4` HeaderMap, `ok8` SerializedName, `ka5` JsonAdapter, `mn6` без токена, `zc0` Bearer, `l85` подпись, `kr7` сырой результат.

Gson: `jm4` Gson, `km4` GsonBuilder, `o5a` TypeAdapter, `p5a` TypeAdapterFactory, `x6a` TypeToken, `jc5`/`bd5` JsonReader/Writer, `zb5` JsonObject, `pa5` JsonArray, `fb5` JsonElement.

## 11.5. DTO по областям

| область | файлы (`p000/`) |
|---|---|
| серверы и камеры | `vk8` ServerSlice, `tm1` CameraSlice, `r23` репозиторий + проекция (64–99), `p14` тело FIND, `kj7` тело с проекцией, `ug1` права, `xzb` разбор `services`, `com/ivideon/sdk/network/data/p012v5/DeviceType` |
| привязка | `gl2` тело `servers CREATE`, `ja0` токен привязки, `ka0` статус, `u13` тип id, `zh4` тело QR, `rw2` тело DELETE, `vs7`/`w13`/`w96`/`v13` RECOGNIZE, `ia0` способы, `hl5` цвет LED, `es0` правило `&` для Cute 2 |
| привязка — логика | `w03`, `q91`, `p91`, `l91`, `C2138j7`, `C2175k7`, `js8`, `ls8`, `a5a`, `nb8`, `m13`, `C2711yj` (**не декомпилируется**) |
| Wi-Fi | `lqa`/`kqa`/`tqa` скан, `wb2` CONNECT, `io1`, `ui1`, `ti1`, `vqa`, `fx1` (WifiManager телефона) |
| управление | `ql7`/`pl7`/`ol7` PTZ, `db7`/`cb7`/`y65`/`za6` плагины, `ab6`/`va6`/`bb6` движение, `m19`/`l19`/`n19` звук, `il5`/`gl5` LED, `x65`/`w65` ИК, `k86` микрофон, `zaa` config, `qz1` режим архива, `ku7` расписание, `bg8`/`cg8`/`zf8` SD-карта, `cba`, `bba` |
| видео | `sw4` качество, `ct5` LivePreviewChannel, `mo7`/`lo7` голос |
| архив | `fo9`/`g50`/`o50`/`n30` таймлайн, `yh4`/`xh4`/`d20`/`a20`/`e20`/`c20` календарь, `t20`/`yu3`/`cv3`/`bv3` экспорт |
| таймлапсы | `to9`, `np9`, `sr9`, `kt9`, `ot9` |
| события | `tp3` фильтр, `en3` Event, `ho3` источник, `qo3`/`oo3` типы, `gp6`/`hp6`/`nd1`/`o14` настройки уведомлений |
| пользователь, доступ | `ada` User, `gda`, `hi4`, `vw2`, `r65`, `ro8` SHARE, `ci4`, `dl2`/`la2` 2FA-методы, `qo8` IDAM |
| пакеты | `fv0`, `gv0`, `yb7`, `cv0` сборщик, `zb7` интервал, `b77`, `C2340on` цикл (**не декомпилируется**) |
| облака | `xz1` CustomerCloud, `i86`/`te2` microcloud |
| push | `ho7` тело подписки, `bo7` провайдеры, `xn7`, `pc7`, `nc1`, `jrc`; `com/ivideon/client/notifications/push/` |

## 11.6. Плеер и медиа

| файл | роль |
|---|---|
| `com/ivideon/sdk/player/p014iv/core/IvPlayer.java` | JNI-обёртка: native-методы, события (106–141) |
| `com/ivideon/client/p009ui/player/PlayerController.java` | экран плеера (190 КБ): сборка URL (785–837), перемотка (1873–1900), скорости (2710), токен-обсервер (2276–2293) |
| `p000/kr2.java` (84–102) | `nativeSetMedia`: live / архив |
| `p000/t75.java`, `r75.java`, `q75.java`, `p75.java` | управление плеером, поверхность, трансформации |
| `p000/g75…n75.java` | классы событий плеера |
| `p000/fr2.java` (323–400) | обработка событий, переподключение |
| `p000/d97.java` | конечный автомат UI плеера |
| `p000/e97.java` (41–73) | расчёт текущего времени на шкале |
| `p000/C2363p8.java`, `C2210l4.java` | скорость воспроизведения |
| `p000/ca1.java`, `yh1.java` | загрузка кадра-превью |
| `p000/vd1.java`, `wd1.java`, `et5.java`, `dt5.java`, `k06.java`, `r66.java`, `mg7.java` | WebSocket-превью: запрос, сокет, protobuf |
| `p000/yu8.java`, `ip3.java` | клипы событий через `MediaPlayer` |
| `p000/du3.java`, `to7.java`, `lw6.java`, `zoa.java`, `yoa.java`, `bpa.java`; `com/ivideon/tools/opus/internal/LibOpus.java` | голос: режим, захват, Opus, потоковый POST, лимиты; `apa`, `fm8` — **не декомпилируются** |

Нативные библиотеки — в `apk/xapk/config.arm64_v8a.apk`, `lib/arm64-v8a/` (в `decompiled-…/resources` их нет: это отдельный сплит).

## 11.7. UI, не переименованный R8

| путь | содержимое |
|---|---|
| `com/ivideon/client/p009ui/wizard/` | мастер подключения: `methods/p010qr`, `methods/wired`, `methods/wifi`, `methods/desktop` |
| `com/ivideon/client/p009ui/player/` | плеер |
| `com/ivideon/client/p009ui/cameralayout/` | сетка камер |
| `com/ivideon/client/p009ui/signin/` | вход, 2FA |
| `com/ivideon/client/notifications/push/` | приём push, `CloudSubscriptionWorker` |
| `resources/res/navigation/*.xml` | графы навигации — удобная «карта сценариев» |
| `resources/res/values/strings.xml` | тексты; имена ресурсов часто раскрывают назначение кода |
| `resources/res/xml/network_security_config.xml` | политика TLS |
| `resources/AndroidManifest.xml` | компоненты, разрешения, deep links |

## 11.8. Методы, которые jadx не декомпилировал

Для них нужен `jadx --single-class <имя> -m fallback` (вывод ближе к байткоду, но полный) либо jadx-gui / smali:

| класс | что в нём |
|---|---|
| `C2199ku.m14118a` | составной запрос (по сигнатуре — выборка по набору id за интервал) |
| `C2711yj` (case 11) | запрос QR-кода привязки |
| `C2270mr` | адаптер токена / вызова 2FA, адаптер API4 |
| `C2340on` | цикл опроса пакетного запроса |
| `apa`, `fm8` | цикл кодирования Opus и запись чанков |
| `go1` | чтение сетевой информации камеры |
| `ui1` (частично) | цикл переподключения Wi-Fi |

Fallback-дампы, сделанные при подготовке этой документации, **в проект не сохранены** (лежали во временном каталоге сессии). При необходимости повторите команду.
