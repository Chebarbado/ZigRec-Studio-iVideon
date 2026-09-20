# 6. Справочник API

**Теги:** #API5 #эндпоинты #камеры #архив #события #batches

Все эндпоинты, которые вызывает приложение 3.7.1, с телами запросов и ответов. Общие правила (конверт, авторизация, даты, проекции) — в [04-request-conventions.md](04-request-conventions.md); здесь они подразумеваются: **в таблицах показано содержимое `result`**, а не весь ответ.

Достоверность: пути и имена полей — **[код]** (аннотации `@wy6`/`@mg4` и `@ok8`). Типы — как объявлены в клиенте; необязательность помечена там, где она видна. На живом API не проверено.

Обозначения: **дата** — число, Unix-секунды (возможна дробная часть); **мс** — целое, Unix-миллисекунды; `?` — поле может отсутствовать; «пусто» — результат без данных (`{}`, `""` или `null`).

<!-- figure: api-map | Карта ресурсов API5 -->

Сервисные интерфейсы в коде:

| интерфейс | содержимое |
|---|---|
| `p000/InterfaceC2236lu.java` | основной сервис, ~75 методов |
| `p000/InterfaceC2345or.java` | картинки |
| `p000/jc0.java`, `p000/tl7.java` | OAuth, 2FA, регистрация, сброс пароля — см. [03-auth.md](03-auth.md) |
| `p000/qm2.java`, `cv4.java`, `pp0.java`, `vx8.java`, `e26.java` | облака партнёров, IDAM, баннеры, site security, маркетинг |

---

## 6.1. Серверы и камеры

Терминология: **сервер** — устройство, подключённое к облаку (камера с прошивкой Ivideon, видеорегистратор, ПК с Ivideon Server); **камера** — видеоканал сервера. Id камеры — **`<serverId>:<индекс>`** (приложение получает `serverId` как `cameraId.split(":")[0]`, `p000/r23.java:152`).

### `POST /servers?op=FIND`

Главный вызов «что есть в аккаунте». Помечен `@kr7`: приложение получает `result` сырым JSON и разбирает позже.

Запрос (`p000/p14.java`):

| поле | тип | примечание |
|---|---|---|
| `skip`, `limit` | int? | постраничная выборка |
| `projection` | object | какие поля вернуть — см. ниже |
| `user` | string? | приложение не шлёт |
| `include_all` | bool | приложение шлёт `false` |

Вызывающий код FIND jadx не декомпилировал — какие `skip`/`limit` шлёт приложение, неизвестно.

**Проекция, которую использует приложение** (`p000/r23.java:64-99`) — готовый образец для своего клиента:

```json
{
  "projection": {
    "id": 1, "owner": 1, "connected": 1, "online": 1, "name": 1, "device_type": 1,
    "software_version": 1, "available_updates": 1, "device_model": 1, "vendor": 1,
    "needs_credentials": 1,
    "cameras": {
      "id": 1, "owner": 1, "name": 1, "plan": 1, "connected": 1, "online": 1,
      "turned_off_until": 1, "width": 1, "height": 1, "rotation": 1,
      "features": 1, "permissions": 1, "timezone": 1,
      "services": {
        "enabled": {"option": 0, "_others": 1},
        "archive": {"days": 1, "active": 1},
        "notify>motion": {"active": 1}, "notify>sound": {"active": 1}, "notify>status": {"active": 1},
        "timelapse": {"active": 1}, "public_records": {"active": 1}
      }
    }
  }
}
```

(в приложении внутри `services` есть ещё `archive_local`, `archive_export`, `rights`, `face_recognition` — все с `{"option": 0, "_others": 1}`).

**Объект сервера** (`ServerSlice`, `p000/vk8.java`):

| поле | тип | примечание |
|---|---|---|
| `id` | string | префикс id его камер |
| `owner` | string | id пользователя-владельца; приложение сравнивает с собой → «своя/расшаренная» |
| `connected`, `online` | bool | |
| `name` | string | |
| `device_type` | string | `desktop`, `camera`, `dvr`, `doorbell`, `bridge`, `cloud_bridge`, `unknown` |
| `cameras` | Camera[] | |
| `software_version` | string | **версия прошивки/ПО** |
| `available_updates` | string | |
| `device_model`, `vendor` | string | |
| `needs_credentials` | bool | устройству нужны логин/пароль |

Ключей `serial`, `mac`, `firmware_version` в этой модели нет.

**Объект камеры** (`CameraSlice`, `p000/tm1.java`):

| поле | тип | примечание |
|---|---|---|
| `id` | string | `<serverId>:<индекс>` |
| `owner`, `name` | string | |
| `plan` | string? | тариф |
| `connected`, `online` | bool | |
| `turned_off_until` | number | `0` — включена; `-1` — выключена бессрочно; иначе Unix-секунды, до которых выключена |
| `width`, `height`, `rotation` | int | |
| `timezone` | string | IANA |
| `features` | string[] | возможности: встречаются `ptz`, `push_to_talk`, `push_to_talk_2`, `speed_play`, `led_switch`, `ir_led`, `motion_detector`, `sound_detector`, `mic_sensitivity`, `sd_card`, `firmware`, `wifi_setup` |
| `permissions` | string[] | `live`, `archive`, `ptz`, `admin`, `events` (`p000/ug1.java`); для своих камер приложение список игнорирует |
| `services` | object | услуги: у каждой `active`; `enabled.active` — bool либо строка-причина `"billing"` / `"camera"`; `archive.days` — глубина архива (`p000/xzb.java:217-290`) |

Перед вызовом управляющих функций проверяйте `features` — это способ узнать, что умеет Cute 2.

### Прочие вызовы

| запрос | тело | результат |
|---|---|---|
| `POST /servers/{serverId}?op=GET` | `{"projection": {…}}` | сервер (сырой JSON) |
| `POST /cameras/{cameraId}?op=GET` | `{"projection": {…}}` | камера (сырой JSON) |
| `POST /servers?op=CREATE` | см. [09-camera-attachment.md](09-camera-attachment.md) | токен привязки |
| `POST /servers/{serverId}?op=DELETE`, `POST /cameras/{cameraId}?op=DELETE` | — | пусто |
| `POST /folders?op=FIND` | `{"projection": {…}}` | папки (сырой JSON) |
| управление камерой, PTZ, плагины, SD-карта, Wi-Fi | | см. [08-camera-control.md](08-camera-control.md) |

### Раскладки (сетки камер)

| запрос | тело | результат |
|---|---|---|
| `POST /layouts?op=FIND` | `{user?, limit?, skip?}` | `CameraLayout[]` |
| `POST /layouts?op=CREATE` | `{name, columns, rows, user?}` | `CameraLayout` |
| `POST /layouts/{layoutId}?op=UPDATE` | `{items?, name?, columns?, rows?}` | пусто |
| `POST /layouts/{layoutId}?op=DELETE` | — | пусто |

`CameraLayout` (`p000/ge1.java`): `{id, name, owner, columns: int, rows: int, items: […]}`.

---

## 6.2. Видео и изображения

Подробно — [07-video.md](07-video.md).

| запрос | параметры | результат |
|---|---|---|
| `GET /cameras/{cameraId}/live_stream` | `q`, `video_codecs`, `audio_codecs` | поток FLV; URL подписывается |
| `GET /cameras/{cameraId}/archive_stream` | `start_time` (мс), `end_time?` (мс), `speed?`, `q`, `video_codecs`, `audio_codecs` | поток FLV; URL подписывается |
| `GET /cameras/{cameraId}/live_preview` | `q` | JPEG; URL подписывается |
| `POST /cameras/{cameraId}/live_preview?op=STREAM` | query: `fps`, `q` | `{url}` — WebSocket |
| `GET /events/{eventId}/thumbnails` | `qty`, `width?`, `height?`, `columns` | картинка; `Authorization: Bearer` |
| `POST /cameras/{cameraId}/voice_message?op=START` | `{mode, codec: "opus", frame_size: 480}` | `{url}` |

---

## 6.3. Архив

### `POST /cameras/{cameraId}/archive_timeline?op=GET`

Запрос (`p000/fo9.java`): `{"start_time": <мс>, "end_time": <мс>}` — **миллисекунды**, в отличие от большинства дат API.

Результат (`ArchiveRecordsList`, `p000/g50.java`): `{"timeline": [ … ]}`, элемент:

| поле | тип | примечание |
|---|---|---|
| `start_time` | мс | |
| `duration` | мс | |
| `type` | int | `1` — только локально (SD), `2` — только облако, `3` — и там и там (`p000/n30.java`) |
| `playback_allowed` | bool | |

Приложение склеивает соседние записи одного типа с разрывом ≤ 200 мс (`p000/o50.java`).

### `POST /cameras/{cameraId}/archive_calendar?op=GET`

Два варианта тела на одном пути:

| вариант | запрос | результат |
|---|---|---|
| диапазон дат (`p000/yh4.java`) | `{"start_date": "yyyy-MM-dd", "end_date": "yyyy-MM-dd", "timezone": "<IANA>"}` — конец не включается | `{"calendar": [{"date": "yyyy-MM-dd", "coverage": <int>}]}` |
| месяц (`p000/xh4.java`) | `{"month": "<строка>", "timezone": "<IANA>"}` — формат `month` не установлен | `{"calendar": [<int>, …]}` |

### Экспорт клипов

| запрос | тело | результат |
|---|---|---|
| `POST /cameras/{cameraId}/archive?op=EXPORT` | `{"start_time": <дата>, "end_time": <дата>, "_need_notify": true}` | `ExportedRecord` |
| `POST /exported_records?op=FIND` | `{skip?, limit?, created_since?, created_until?, projection?}` | `ExportedRecord[]` |
| `POST /exported_records/{id}?op=GET` | — | `ExportedRecord` |
| `POST /exported_records/{id}?op=DELETE` | — | пусто |
| `POST /exported_records/{id}/public_access?op=SHARE` / `?op=REVOKE` | — | пусто |

`ExportedRecord` (`p000/yu3.java`): `{id, camera, created_at, start_time, end_time: дата, status, progress: int, file_size: long, has_public_access: bool, preview_url, video_url}`; `status` ∈ `in_queue`, `in_progress`, `ready`, ошибка (`p000/cv3.java`). Схема работы: EXPORT → опрашивать `GET` до `ready` → скачать `video_url`.

### Таймлапсы

| запрос | тело | результат |
|---|---|---|
| `POST /timelapses?op=FIND` | `{created_since?, created_until?, limit?, name?, cameras?, period_start?, period_end?, skip?}` | `Timelapse[]` |
| `POST /timelapses?op=CREATE` | `{name, period_start, period_end, cameras: [id], schedule, duration: float, quality, clock_position, missing_frame_policy?}` | `Timelapse` |
| `POST /timelapses/{id}?op=GET` / `?op=DELETE` | — | `Timelapse` / пусто |
| `POST /timelapse_summary?op=FIND` | `{cameras: [id], name?, statuses?, timeframe_since?, timeframe_until?, missing_frames_level_min?, missing_frames_level_max?, limit?, skip?}` | `TimelapseSummary[]` |

`Timelapse` (`p000/to9.java`): `id, name, owner_id, created_at, period_start, period_end, cameras, schedule, timezone, duration, quality, clock_position, missing_frame_policy, status, progress, preview_url, video_url, file_size, store_until, template_id, auto_generated`.

---

## 6.4. События и уведомления

### `POST /events?op=FIND`

Запрос (`EventsFilter`, `p000/tp3.java`):

| поле | тип | примечание |
|---|---|---|
| `start_time`, `end_time` | дата | Unix-секунды |
| `types` | string[] | иерархические имена, например `analytics/tampering/image_too_dark/started` |
| `sources` | `[{type: "camera"\|"server", id}]` | фильтр по источникам (`p000/ho3.java`) |
| `delivered` | bool | |
| `skip`, `limit` | int | |
| `sort_by_time` | string | по умолчанию `"desc"` |
| `user`, `lang` | string | |

Результат — `Event[]` (`p000/en3.java`): `id, type, time: дата, status, preview, clip: URL, clip_duration: int, date, value, user, delivered, chain_id, device_id, source_type, source_id, device_type, name, description`.

`preview` и `clip` — URL, которые приложение загружает с `Authorization: Bearer <access_token>`.

### Прочее

| запрос | тело | результат |
|---|---|---|
| `POST /events/{eventId}?op=GET` | `{"projection": {…}}` | событие (сырой JSON) |
| `POST /events?op=GET_TYPES` | `{platform: "android", partner_id?, user_id?, lang?}` | `[{type, feed_settings, color, name: {<lang>: …}, template: {<lang>: …}}]` — **справочник типов событий**, полезно запросить один раз |
| `POST /notification_settings?op=FIND` | `{"projection": {…}}` | сырой JSON |
| `POST /notification_settings?op=FIND_ONE` | `{camera_id}` или `{camera_id, user, projection}` | `{user_id, camera_id, event_types, channels, restrictions, mute_until}` |
| `POST /notification_settings?op=UPSERT` | `{camera_id, event_types, channels, schedule, mute_until, user}` | пусто |
| `POST /cameras/{cameraId}/notifications?op=TEST` | карта строк | пусто |
| `POST /push_subscriptions?op=CREATE` | `{user, platform: "android", device_id, tokens: {fcm?, rustore?, hms?}, app_id, language, sandbox: false}` | не типизирован |

Push-подписка привязана к экосистемам Android (FCM, RuStore, HMS); стороннему клиенту для событий остаётся **опрос `events?op=FIND`**. Канала событий в реальном времени (WebSocket/long-poll) в основном сервисе не видно.

---

## 6.5. Пользователь и доступ

| запрос | тело | результат |
|---|---|---|
| `POST /users/{uid}?op=GET` | `{"projection": {…}}` | пользователь (сырой JSON); `uid` = `owner_id` из токена |
| `POST /users?op=GET_ID` | `{login}` | `{id}` |
| `POST /users/{userId}/{property}?op=SET` | `{"value": …}` | пусто; свойства: `dnd_until`, `events_clips_enabled` |
| `POST /users/{uid}?op=DELETE` | `{complete: true, password}` | пусто — **удаление аккаунта** |
| `POST /users/{uid}/managed_accounts?op=CREATE` | `{email}` | `User` |
| `POST /permission_grants?op=FIND` | `{object_id, object_type, grantee_id, explicit_only, projection}` | сырой JSON |
| `POST /permission_grants/{permissionId}?op=DELETE` | — | пусто |
| `POST /cameras/{cameraId}?op=SHARE` | `{grantee_type: "user", grantee_id, permission}` | не типизирован |
| `POST /two_factor_methods?op=CREATE` | `{value, type, password}` | `{id, type, value, state, owner_id?}` |
| `POST /two_factor_methods?op=CONFIRM` | `{two_factor_method_id, code}` | то же |
| `POST /access_tokens/{accessTokenId}?op=REVOKE` | — | пусто; публичный (`@mn6`) |

`User` (`p000/ada.java`): `id, login, login_type, account_type, partner, root_folder, language, country, currency, timezone, created_at, last_login, deleted, dnd_until, billing_version, api_host, api4_host, api5_host, access_token, _misc, services_b4, options`.

Публичные (без токена), из `p000/tl7.java`: `POST /users?op=CREATE`, `POST /users?op=RESET_PASSWORD`, `POST /partners/{partnerId}/signup_form_config?op=GET`.

---

## 6.6. Пакетные запросы

Несколько POST-вызовов одним запросом.

```http
POST /batches?op=CREATE
[
  {"op": "GET", "path": "/cameras/100-…:0", "body": {"projection": {"online": 1}}},
  {"op": "GET", "path": "/cameras/100-…:1", "body": {"projection": {"online": 1}}}
]
→ {"id": "<batchId>"}

POST /batches/{batchId}?op=POLL
→ {"id": "…", "all_done": true, "all_ok": true, "responses": [ … ]}
```

* тело CREATE — **голый JSON-массив** элементов `{op, path, body}` (`p000/fv0.java`): `op` — значение `?op=` вложенного вызова, `path` — путь от корня API с ведущим `/`;
* лимит — **50 элементов**, только POST-вызовы (`p000/cv0.java:44-52`);
* приложение опрашивает POLL раз в 1 с до `all_done` (`p000/zb7.java:32`);
* каждый элемент `responses` — полноценный конверт API5 (`success`/`result` либо ошибка) с целым `id` = индексу запроса; приложение сортирует по нему (`p000/b77.java:32`). Цикл опроса восстановлен из fallback-дампа jadx.

---

## 6.7. Прочие сервисы

| запрос | назначение |
|---|---|
| `POST /customer_clouds?op=FIND` (`p000/qm2.java`) | список облаков партнёров; без авторизации — см. [02-architecture.md](02-architecture.md) |
| `POST /idam?op=SHARE` (`p000/cv4.java`, `p000/qo8.java`) | **выдача доступа к камере по номеру телефона**: `{"phone_number", "camera_id", "permissions": […]}`; уходит на auth-хост с `access_token`. Это не SSO, как предполагалось вначале |
| `POST /banners?op=FIND`, `?op=FIND_NO_AUTH`, `POST /banners/{bannerId}?op=MARK` (`p000/pp0.java`) | рекламные баннеры в приложении |
| `POST /site_security_integrations?op=LIST_SITES`, `?op=PRESS_ALERT_BUTTON` (`p000/vx8.java`) | интеграция с охранными объектами («тревожная кнопка»); свои коды ошибок |
| `POST /marketing_leads?op=CREATE` (`p000/e26.java`) | маркетинговые заявки |

Для драйвера камеры не нужны.

---

## 6.8. Минимальный набор для драйвера

<!-- figure: driver-path | Минимальный путь драйвера: от входа до картинки и событий -->

| шаг | вызов |
|---|---|
| 1. вход | `POST /auth/oauth/token` |
| 2. найти камеру | `POST /servers?op=FIND` с проекцией из 6.1 |
| 3. картинка | `GET /cameras/{id}/live_preview?q=…` (подписанный) |
| 4. видео | `GET /cameras/{id}/live_stream?…` (подписанный) → FLV |
| 5. события | `POST /events?op=FIND` с `sources` и `start_time`, периодически |
| 6. настройки | `POST /cameras/{id}/plugins?op=INVOKE` c `"method": "GET"` — только для возможностей из `features` |
| 7. обновление токена | `grant_type=refresh_token` при 401 или заранее по `expires_in` |
