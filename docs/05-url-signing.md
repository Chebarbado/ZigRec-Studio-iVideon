# 5. Подпись стримовых URL (`cseq` + `cs`)

**Теги:** #подпись_URL #HMAC #SHA1 #cseq #OkHttp #тестовые_векторы

Запросы к видео и превью (`live_stream`, `archive_stream`, `live_preview`) приложение отправляет не через свой HTTP-клиент, а **строит URL и отдаёт его плееру/загрузчику картинок**. Чтобы такой URL нельзя было подделать или переиспользовать, он подписывается секретом `hmac_secret` из токена.

Достоверность: алгоритм — **[код]**; то, что сервер действительно проверяет подпись и как реагирует на ошибку, — **не проверено**.

## 5.1. Когда подпись добавляется

Источник: `p000/g58.java`, метод `mo7583n` (строки 396–467).

Подпись добавляется, только если выполнены оба условия (строка 431):

1. метод сервиса помечен `@l85`. Таких методов три:
   * `GET /cameras/{cameraId}/live_stream` — `p000/InterfaceC2236lu.java:78`
   * `GET /cameras/{cameraId}/archive_stream` — `p000/InterfaceC2236lu.java:105`
   * `GET /cameras/{cameraId}/live_preview` — `p000/InterfaceC2345or.java:12`
2. в токене есть непустой `hmac_secret` (флаг `C2470s2.f38388n`, вычисляется в `p000/C2470s2.java:21`).

Если `hmac_secret` пуст — URL уходит только с `access_token`, без `cseq` и `cs`.

> Уточнение к первоначальному выводу: `live_preview` — это `@l85` (токен в query + подпись), а **не** `@zc0` (Bearer). Bearer используется для `GET /events/{eventId}/thumbnails` и для загрузки картинок по готовому URL (`InterfaceC2345or.m16309a`, `m16312d`).

## 5.2. Алгоритм

```text
session  = 8 случайных символов из [0-9a-zA-Z]
           генерируется один раз при создании объекта токена и живёт вместе с ним
cseq     = session + ":" + counter
           counter — SystemClock.elapsedRealtime(): миллисекунды с загрузки устройства

1. К URL добавляется query-параметр access_token=<token>      (шаг общий для всех обычных запросов)
2. К URL добавляется query-параметр cseq=<cseq>
3. to_sign = METHOD + ":" + path + ":" + query + ":" + body
4. digest  = hex_lower( SHA1( utf8(to_sign) ) )                 # 40 символов
5. cs      = hex_lower( HMAC_SHA1( key = utf8(hmac_secret), msg = utf8(digest) ) )
6. К URL добавляется query-параметр cs=<cs>
```

<!-- figure: signing-pipeline | Конвейер подписи стримового URL -->

Детали, на которых легко ошибиться:

| элемент | точное значение | где в коде |
|---|---|---|
| `METHOD` | метод HTTP заглавными: `GET` | `g08Var2.f13158b`, `g58.java:442` |
| `path` | `"/" + join("/", pathSegments)` — **декодированные** сегменты пути OkHttp, с ведущим слэшем. Двоеточие в id камеры (`100-…:0`) остаётся двоеточием | `p000/zbc.java:40-43`, `ps4.f34839f` |
| `query` | **закодированная** строка запроса — подстрока URL после `?` до `#`, как она есть в итоговом URL, **уже включая** `access_token` и `cseq`, но **без** `cs` | `ps4.m17064d()`, `p000/ps4.java:89-96` |
| `body` | тело запроса как строка UTF-8; для GET — пустая строка. Итоговая строка для GET заканчивается двоеточием | `g58.java:445-452` |
| разделитель | `:` (константа `StringUtils.PROCESS_POSTFIX_DELIMITER` из AppMetrica, равна `":"`) | `g58.java:453` |
| hex | нижний регистр, без разделителей (`%02x`) | `c70.m2912D(bytes, "", …)` |
| порядок параметров | исходные параметры → `access_token` → `cseq` → `cs`. `cs` всегда последний | `g58.java:416, 440, 462` |

**Двойное хеширование — не опечатка.** HMAC считается не от `to_sign`, а от hex-строки его SHA-1 (40 ASCII-символов).

**Кодирование query.** OkHttp при добавлении параметра (`addQueryParameter`) percent-кодирует набор `QUERY_COMPONENT_ENCODE_SET`; нетронутыми остаются только `[A-Za-z0-9]` и `- . _ *`. Обратите внимание: тильда `~` **кодируется** (`%7E`), хотя большинство библиотек её не трогают. Практически важно: запятая в `video_codecs=h265,h264` превращается в `%2C`, двоеточие в `cseq` — в `%3A`, пробел — в `%20`. Подписывается именно закодированная форма, поэтому ваша реализация должна кодировать **так же, как OkHttp**, иначе `cs` не совпадёт. Реализация `zig-client/src/sign.zig` кодирует всё, кроме `[A-Za-z0-9-._*]`, в `%XX` заглавными hex-цифрами — этого достаточно для всех значений, которые реально встречаются (цифры, `h265,h264`, токен, `cseq`).

### Генерация `session`

`p000/kr6.java:626-647` — восемь раз `Random.nextInt(62)`, отображение: `0–9` → цифры, `10–35` → `a–z` (`i + 87`), `36–61` → `A–Z` (`i + 29`). Случайность не криптографическая, и от неё ничего не зависит: это просто идентификатор клиентской сессии.

### Что такое `counter` **[вывод]**

Значение монотонно растёт и уникально в пределах `session`. Вероятное назначение на сервере — защита от повторного использования URL (nonce/последовательность). В своём клиенте используйте любой монотонный счётчик миллисекунд (например, время с запуска процесса или Unix-время в мс). Принимает ли сервер значения «из прошлого» относительно уже виденных для той же `session` — **неизвестно**; безопаснее никогда не уменьшать счётчик в пределах одной `session`.

## 5.3. Эталонная реализация (Python)

```python
import hashlib, hmac, random, string, time
from urllib.parse import quote

SAFE = "-._*"                       # вместе с [A-Za-z0-9] — то, что OkHttp не кодирует в query

def enc(s: str) -> str:
    # пробел -> %20, ',' -> %2C, ':' -> %3A; quote() никогда не кодирует '~', а OkHttp кодирует
    return quote(s, safe=SAFE).replace("~", "%7E")

def new_session() -> str:
    return "".join(random.choices(string.digits + string.ascii_letters, k=8))

def signed_url(base, path, params, access_token, hmac_secret, session, counter,
               method="GET", body=""):
    pairs = list(params) + [("access_token", access_token)]
    if hmac_secret:
        pairs.append(("cseq", f"{session}:{counter}"))
    query = "&".join(f"{enc(k)}={enc(v)}" for k, v in pairs)
    url = f"{base}{path}?{query}"
    if not hmac_secret:
        return url
    to_sign = f"{method}:{path}:{query}:{body}"
    digest = hashlib.sha1(to_sign.encode()).hexdigest()
    cs = hmac.new(hmac_secret.encode(), digest.encode(), hashlib.sha1).hexdigest()
    return f"{url}&cs={cs}"

# пример
url = signed_url(
    "https://eu01-api.ivideon.com",
    "/cameras/100-0123456789abcdef0123456789abcdef:0/live_stream",
    [("q", "2"), ("video_codecs", "h265,h264"), ("audio_codecs", "pcmu,pcma,aac,mp3")],
    access_token="100-Kabcdef0123456789", hmac_secret="s3cr3tKey",
    session="AbCd1234", counter=987654321,
)
```

`path` не должен содержать символов, которые OkHttp стал бы кодировать в пути (пробелы, не-ASCII): тогда закодированный путь в URL и декодированный путь в `to_sign` разойдутся, и эту разницу надо воспроизводить отдельно. Для реальных id камер (`<цифры>-<hex>:<индекс>`) проблемы нет.

## 5.4. Тестовые векторы

Значения вымышленные (не настоящие токены). Векторы проверены двумя независимыми реализациями — Python (`hashlib`/`hmac`) и Zig (`zig-client/src/sign.zig`, `zig build test`). Это доказывает, что реализации совпадают **между собой и с восстановленным алгоритмом**, но не то, что сервер примет подпись.

**Вектор 1 — `live_stream`**

```text
hmac_secret = s3cr3tKey
session     = AbCd1234
counter     = 987654321
to_sign     = GET:/cameras/100-0123456789abcdef0123456789abcdef:0/live_stream:q=2&video_codecs=h265%2Ch264&audio_codecs=pcmu%2Cpcma%2Caac%2Cmp3&access_token=100-Kabcdef0123456789&cseq=AbCd1234%3A987654321:
SHA1 hex    = 94298070007308832ae816515d93f90d1eb54314
cs          = 555e417709d50f8ffff3ed9c6fc273b250368ebb

URL = https://eu01-api.ivideon.com/cameras/100-0123456789abcdef0123456789abcdef:0/live_stream?q=2&video_codecs=h265%2Ch264&audio_codecs=pcmu%2Cpcma%2Caac%2Cmp3&access_token=100-Kabcdef0123456789&cseq=AbCd1234%3A987654321&cs=555e417709d50f8ffff3ed9c6fc273b250368ebb
```

**Вектор 2 — «неудобные» символы в токене**

```text
hmac_secret = k,  session = zzzzzzzz,  counter = 1,  access_token = "tok+en/with=odd chars~"
URL = https://api.ivideon.com/cameras/100-ffff:3/live_preview?q=0&access_token=tok%2Ben%2Fwith%3Dodd%20chars%7E&cseq=zzzzzzzz%3A1&cs=1818ad11a4776bfee60e97456c6d1c26f20b3e91
```

**Вектор 3 — токен без `hmac_secret`**

```text
URL = https://api.ivideon.com/cameras/1:0/live_preview?access_token=t
```

## 5.5. Как приложение использует подписанный URL

`p000/C2199ku.java:152-154` (`m14125h`): берётся подготовленный Retrofit-запрос (`ek6.m6026i()` — объект `okhttp3.Request` без выполнения), прогоняется через тот же интерцептор `g58.mo7583n`, и из результата извлекается **строка URL** (`ps4.f34842i`). Эта строка и передаётся в нативный плеер (`IvPlayer.nativeSetMedia`) — см. [07-video.md](07-video.md).

Следствия для своего клиента:

* подписанный URL самодостаточен: его можно открыть любым HTTP-клиентом или плеером (ffmpeg/VLC/mpv) без дополнительных заголовков **[вывод; проверить вживую]**;
* URL содержит `access_token` — **это секрет**. Не логируйте его целиком, не передавайте в командной строке там, где её видят другие пользователи;
* на каждое новое открытие потока приложение строит новый URL с новым `counter`. Срок жизни подписанного URL на сервере **неизвестен**.
