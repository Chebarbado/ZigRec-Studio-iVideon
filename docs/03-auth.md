# 3. Авторизация и жизненный цикл токена

**Теги:** #OAuth2 #токен #refresh_token #двухфакторка #безопасность

OAuth2 password grant с публичным клиентом `android-client`, обновление по `refresh_token`, двухфакторный вход, отзыв токена.

Достоверность: запросы, поля и логика клиента — **[код]**. Ответы сервера известны только по моделям, в которые клиент их разбирает. **Ни один вход на живом сервере не выполнялся**.

<!-- figure: token-lifecycle | Жизненный цикл токена: три исхода входа, обновление, выход -->

## 3.1. Получение токена

Источники: `p000/jc0.java` (сервис), `p000/qv5.java:358-366, 697-701` (форма), `p000/C2552ua.java:63-81` (Basic-заголовок).

```http
POST https://api.ivideon.com/auth/oauth/token
Authorization: Basic YW5kcm9pZC1jbGllbnQ6
Content-Type: application/x-www-form-urlencoded

grant_type=password&username=<email>&password=<пароль>&client_type=android&client_version=3.7.1&device_instance_id=<id>&device_type=<строка>&device_name=<строка>&trusted_device=true
```

`YW5kcm9pZC1jbGllbnQ6` = `base64("android-client:")` — `client_id` `android-client`, **секрет пустой**. Это публичная константа приложения.

| поле формы | значение в приложении | что слать своему клиенту |
|---|---|---|
| `grant_type` | `password` | то же |
| `username`, `password` | логин (email) и пароль | то же |
| `client_type` | `android` | `android` — с другим значением поведение сервера неизвестно |
| `client_version` | `3.7.1` | `3.7.1` |
| `device_instance_id` | Firebase Installation ID — 22 символа base64url (`p000/q10.java:21-27`) | любой **стабильный** идентификатор установки: сгенерировать один раз и хранить рядом с токеном |
| `device_type` | `"<MANUFACTURER> <MODEL>, Android <RELEASE>"`, напр. `samsung SM-G991B, Android 13` (`p000/p52.java:111`) | произвольная строка-описание |
| `device_name` | имя устройства из настроек либо `Build.MODEL` | произвольная строка |
| `trusted_device` | всегда `true` | `true` |

**[гипотеза]** `device_instance_id` + `trusted_device` влияют на то, будет ли сервер запрашивать второй фактор повторно с того же устройства. Меняя идентификатор при каждом входе, вы, вероятно, будете каждый раз выглядеть как новое устройство.

Хост: в обычном режиме — `https://api.ivideon.com`; для партнёрского облака — `https://{api4_host}` этого облака (см. [02-architecture.md](02-architecture.md)).

## 3.2. Ответ: три варианта

### A. Токен

Модель `p000/fr7.java` (+ `p000/C2470s2.java`):

| поле | тип | примечание |
|---|---|---|
| `access_token` | string | он же — идентификатор токена для отзыва |
| `token_type` | string | |
| `expires_in` | int, секунды | |
| `refresh_token` | string? | если нет — обновление невозможно |
| `created_at` | дата? | если отсутствует, клиент подставляет локальное «сейчас» |
| **`api_host`** | string | **базовый хост всего дальнейшего API**; если без схемы — клиент добавляет `https://` (`p000/or7.java:167-171`) |
| `hmac_secret` | string? | ключ подписи стримовых URL; пусто → URL не подписываются ([05-url-signing.md](05-url-signing.md)) |
| `owner_id` | long | id пользователя; подставляется в `user`, `/users/{uid}` |
| `owner_type`, `scope`, `client_type`, `client_version` | string | |
| `limited_to_2fa` | bool? | `true` → токен ограничен: годится только для настройки 2FA (3.5) |

Ответ приходит **без конверта API5** — голый JSON-объект.

### B. Вызов второго фактора — HTTP 200, не ошибка

```json
{
  "proceed_with_2fa": true,
  "message": "…",
  "challenge_token": "…",
  "api5_host": "…",
  "available_methods": [
    {"id": "…", "type": "email" | "sms", "value": "…", "owner_id": 123,
     "state": {"no_resend_until": …, "resend_timeout": …, "submit_attempts": …}}
  ]
}
```

Источники: `p000/j5a.java`, `p000/bb0.java`, `p000/eb0.java`, адаптер `p000/C2270mr.java` (восстановлен из fallback-дампа). Дальше — раздел 3.4.

> Первоначально предполагалось, что признак 2FA — поле `limited_to_2fa` в токене. Это **другой** сценарий (3.5). Обычный вход с включённой 2FA даёт ответ `proceed_with_2fa`.

### C. Ошибка OAuth

`{"error", "error_description", "reason", "retry_in"}` — см. [10-errors.md](10-errors.md), раздел 10.4. Неверный пароль → `AuthError`; `reason=TOO_MANY_LOG_IN_ATTEMPTS` → ждать `retry_in`.

## 3.3. Срок жизни и обновление

| аспект | поведение приложения | источник |
|---|---|---|
| проверка срока | токен считается истёкшим при `now > created_at + expires_in − 300 с` — **запас 5 минут** | `p000/i85.java:218-240` |
| упреждающее обновление | при старте приложения и перед сборкой каждого URL потока | `App.java:293`, `PlayerController.java:803,831` |
| реактивное обновление | HTTP 401 → принудительный refresh → повтор исходного запроса | `p000/e21.java:86-103` |
| исключение | 401 с `message` = `"Session's subject doesn't exist."` → «аккаунт деактивирован или токен отозван», refresh **не** делается | `AuthError.java:20`, `e21.java:89-92` |
| конкурентность | один `AtomicBoolean`: параллельные попытки не шлют второй запрос, а подписываются на идущий | `i85.java:243-295` |
| неудача с `AuthError` | состояние `NO_FATE` → токен сбрасывается, пользователь разлогинен | `p000/h85.java:59-81` |
| прочая неудача (сеть) | `FAILED`, токен сохраняется | там же |
| запасной вход паролем | **нет** — пароль не хранится (лог: `we don't keep credentials anymore`) | `h85.java:90` |

Запрос обновления — тот же эндпоинт и тот же Basic-заголовок (`h85.java:113-118`):

```text
grant_type=refresh_token
refresh_token=<refresh_token>
access_token=<текущий access_token>          ← нестандартно для OAuth2, но приложение шлёт
client_type, client_version, device_instance_id, device_type, device_name, trusted_device=true
```

После обновления приложение **пересоздаёт все сервисы** с новым `api_host` и заново генерирует `session` для подписи URL.

## 3.4. Вход с двухфакторной авторизацией

Все шаги — публичные запросы (без `access_token`) на хост `https://{api5_host}` из ответа-вызова; авторизует их `challenge_token`. Источники: `p000/tl7.java`, `p000/sl7.java:23-34`, `p000/ic0.java:581, 645, 715`.

```mermaid
sequenceDiagram
    participant A as Клиент
    participant O as auth-хост
    participant P as api5_host
    A->>O: POST /auth/oauth/token (password)
    O-->>A: 200 {proceed_with_2fa, challenge_token, api5_host, available_methods}
    Note over A: методов несколько — выбирает пользователь
    A->>P: POST /two_factor_methods/{methodId}?op=SELECT {challenge_token}
    P-->>A: {no_resend_until, submit_attempts}
    Note over P: сервер отправляет код на email/SMS
    opt код не пришёл
        A->>P: POST /two_factor_methods/{methodId}/code?op=RESEND {challenge_token}
    end
    A->>P: POST /two_factor_methods/{methodId}/code?op=SUBMIT {challenge_token, code}
    P-->>A: полноценный токен (модель из 3.2 A)
```

| шаг | запрос | тело | ответ |
|---|---|---|---|
| выбрать метод | `POST /two_factor_methods/{id}?op=SELECT` | `{"challenge_token"}` | `{no_resend_until, submit_attempts}` |
| переслать код | `POST /two_factor_methods/{id}/code?op=RESEND` | `{"challenge_token"}` | то же |
| отправить код | `POST /two_factor_methods/{id}/code?op=SUBMIT` | `{"challenge_token", "code"}` | токен |

Ответы, предположительно, в конверте API5 **[вывод: общий конвертер]**. Ошибки: `CHALLENGE_NOT_FOUND`, `CHALLENGE_EXPIRED`, `TWO_FACTOR_METHOD_NOT_FOUND`, `TWO_FACTOR_METHOD_NOT_SELECTED`, `TOO_FREQUENT` (соблюдайте `no_resend_until`), `INVALID_CODE`, `NO_ATTEMPTS_LEFT`, `BAD_CODE`, `OTP_LOCKED`.

## 3.5. Принудительная настройка 2FA (`limited_to_2fa`)

Если сервер требует 2FA, а она не настроена: либо ошибка OAuth `invalid_grant` / `reason=2FA_IS_MANDATORY`, либо токен с `limited_to_2fa: true`. С ограниченным токеном приложение сразу ведёт на привязку телефона (`signin/C0237c.java:153-162`):

| запрос (на `api_host`, с `access_token`) | тело |
|---|---|
| `POST /two_factor_methods?op=CREATE` | `{"value": "<телефон>", "type": "sms", "password": "<пароль>"}` |
| `POST /two_factor_methods?op=CONFIRM` | `{"two_factor_method_id": "…", "code": "…"}` |

Каким вызовом ограниченный токен превращается в полный — не прослежено; **[вывод]**: приложение входит заново и проходит сценарий 3.4.

Минимальная стратегия для своего клиента: распознать `proceed_with_2fa` и `limited_to_2fa`, сообщить пользователю и не пытаться работать с таким ответом как с токеном.

## 3.6. Выход и отзыв токена

```http
POST https://{api_host}/access_tokens/{accessTokenId}?op=REVOKE
```

* публичный (`@mn6`): `access_token` в query **не** добавляется, тела нет;
* `accessTokenId` — **сама строка `access_token`** (`p000/ic0.java:180-183, 345-348`; косвенно подтверждается десериализатором `p000/C2582v2.java`, где `id` токена отображается на `access_token`);
* ошибки отзыва приложение игнорирует; затем очищает локальные данные.

## 3.7. Хранение

Приложение хранит токен **в открытом виде**: SharedPreferences `PREFSES`, ключ `ACCESS_TOKEN`, JSON модели токена (`p000/ob0.java:79-84`). Без шифрования и без AccountManager. Пароль не хранится.

Для своего клиента: `access_token`, `refresh_token` и `hmac_secret` — секреты одного уровня с паролем на время жизни. Файл — только для текущего пользователя ОС, вне репозитория (`.gitignore`), не печатать в логах. Учтите, что само приложение передаёт `access_token` в query-строке URL (включая ссылки на веб-портал `go.ivideon.com`, параметр `_go.session`) — URL с токеном нельзя публиковать.

## 3.8. Регистрация и сброс пароля (для полноты)

Публичные вызовы на public-API5-хосте (`p000/tl7.java`):

| запрос | тело |
|---|---|
| `POST /users?op=CREATE` | `login, password, language, country, device_type, device_name, device_instance_id, sign_in, marketing_data, account_type` + константы `client_id: "android-client"`, `client_type: "android"`, `client_version: "3.7.1"`, `partner_id: "ivideon"` (`p000/xt8.java`). Ответ — пользователь с встроенными полями токена |
| `POST /users?op=RESET_PASSWORD` | `{"login"}` |
| `POST /partners/ivideon/signup_form_config?op=GET` | `{"client_language", "client_type": "mobile", "ip": null}` |

Входа через соцсети/внешних провайдеров в приложении нет; демо-режима с отдельным токеном тоже нет.

## 3.9. Псевдокод клиента

```python
def login(email, password):
    r = post_form(AUTH_HOST + "/auth/oauth/token", basic("android-client", ""), {
        "grant_type": "password", "username": email, "password": password, **DEVICE_FIELDS,
        "trusted_device": "true"})
    if r.status != 200:            raise OAuthError(r.json())      # error / reason / retry_in
    j = r.json()
    if j.get("proceed_with_2fa"):  return TwoFactorChallenge(j)    # раздел 3.4
    if j.get("limited_to_2fa"):    raise TwoFactorSetupRequired()  # раздел 3.5
    j.setdefault("created_at", time.time())
    return Token(j)                # base_url = ensure_https(j["api_host"])

def call(token, method, path, **kw):
    if token.expires_within(300):  token = refresh(token)
    r = send(token, method, path, **kw)
    if r.status == 401 and r.message != "Session's subject doesn't exist.":
        token = refresh(token)     # AuthError при refresh -> требовать новый вход
        r = send(token, method, path, **kw)
    return r
```
