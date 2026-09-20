# 8. Управление камерой

**Теги:** #управление_камерой #PTZ #плагины #детектор_движения #ИК_подсветка #SD_карта

PTZ, «плагины» (детекторы, светодиод, ИК-подсветка), свойства камеры, SD-карта. Всё в этом разделе — **[код]**: пути из `p000/InterfaceC2236lu.java`, поля — из аннотаций `@ok8` соответствующих DTO. На живой камере ничего не проверялось; какие функции поддерживает именно Cute 2, покажет только ответ API (у объекта камеры есть список поддерживаемых возможностей — приложение проверяет, например, `contains("mic_sensitivity")`, `p000/r86.java:150`).

Общие правила запросов (авторизация, конверт ответа) — в [04-request-conventions.md](04-request-conventions.md).

<!-- figure: control-map | Карта управления камерой -->

## 8.1. PTZ

```http
POST /cameras/{cameraId}/ptz?op=INVOKE
Content-Type: application/json

{"options": {"move": "left"}}
```

| поле | тип | значения | источник |
|---|---|---|---|
| `options.move` | string, опц. | `up`, `down`, `left`, `right`, `home` | enum `p000/ol7.java` |
| `options.rzoom` | int, опц. | относительный зум (знак — направление) **[вывод по имени]** | `p000/pl7.java` |

В одном запросе приложение передаёт либо `move`, либо `rzoom` (второе поле `null` и в JSON не попадает). Вызов: `p000/ml7.java:83`. Ответ — пустой результат. Право на PTZ — отдельное разрешение `ptz` (см. список прав в `p000/l21.java:39`).

Cute 2 — неповоротная камера, PTZ для неё, скорее всего, неприменим **[гипотеза]**.

## 8.2. Плагины камеры

Единая точка входа; тело описывает плагин, «метод» и параметры (`p000/db7.java`):

```http
POST /cameras/{cameraId}/plugins?op=INVOKE

{"plugin": "<имя>", "method": "GET" | "POST" | "DELETE", "options": <объект или null>}
```

`method` здесь — не HTTP-метод, а строка в теле: `GET` — прочитать настройки плагина, `POST` — записать, `DELETE` — сбросить/удалить.

| плагин | GET → ответ | POST → `options` | DELETE | источники |
|---|---|---|---|---|
| `motion_detector` | `{enabled: bool, x, y, width, height: int, sensitivity: "low"\|"medium"\|"high"}` | тот же объект | есть | `ab6`, `va6`, `bb6`, `za6`, вызовы в `lb6.java` |
| `sound_detector` | `{enabled: bool, sensitivity: 0..4}` — 0 = 0 %, 1 = 25 %, 2 = 50 %, 3 = 75 %, 4 = 100 % | тот же объект | есть | `m19`, `l19`, `n19`, `za6`, вызовы в `t19.java` |
| `led_switch` | `"on"` \| `"off"` | `{"state": "on"\|"off"}` | — | `il5`, `gl5`, вызовы в `ml5.java:261` |
| `ir_led` | `"on"` \| `"off"` \| `"auto"` | `{"state": "on"\|"off"\|"auto"}` | — | `x65`, `w65`, вызовы в `zm6.java:305` |
| `mic_sensitivity` | целое число | запись в коде не найдена | — | `k86`, `InterfaceC2236lu.m14752s` |

`x, y, width, height` у детектора движения — прямоугольник зоны детекции; единицы (пиксели, проценты или ячейки сетки) из DTO не видны — **проверить на живом ответе**.

Пример — включить детектор звука на 50 %:

```json
{"plugin": "sound_detector", "method": "POST", "options": {"enabled": true, "sensitivity": 2}}
```

## 8.3. Свойства камеры

Два родственных вызова с произвольным JSON-объектом в теле:

```http
POST /cameras/{cameraId}/{property}?op=SET         # простое значение
POST /cameras/{cameraId}/{property}?op=CONFIGURE   # составная настройка
```

Свойства, которые реально использует приложение:

| `property` | op | тело | смысл | где вызывается |
|---|---|---|---|---|
| `name` | SET | `{"value": "<строка>"}` | переименовать камеру | `p000/r23.java:434` |
| `sound_enabled` | SET | `{"value": true\|false}` | звук в потоке | `p000/d95.java:983` |
| `upside_down` | SET | `{"value": true\|false}` | перевернуть изображение | `p000/v58.java:177` |
| `turned_off_until` | SET | `{"value": <число>}` | выключить камеру: `0` — включена, `-1` — выключена бессрочно, иначе Unix-время (секунды), до которого выключена | `p000/v96.java:283`, `r23.java:520`, адаптер `p000/ud7.java` |
| `cloud_archive_mode` | SET | `{"mode": "<режим>"}` | режим записи в облако | `p000/x30.java:128` |
| `recording_schedule` | CONFIGURE | `{"schedule": {…}}` | расписание записи: часовой пояс, расписание по дням недели, режим по умолчанию (`RecordingSchedule(timezone, daySchedules, defaultMode)`) | `p000/x50.java:542`, `p000/ku7.java` |

Значения `cloud_archive_mode` (`p000/qz1.java`): `off`, `detection`, `continuous`, `sync_local`, `manual_only`, `on_schedule`.

Точная JSON-форма `schedule` собирается кастомным сериализатором и в этом документе не разобрана.

### Прочая конфигурация

| запрос | тело | примечание |
|---|---|---|
| `POST /cameras/{cameraId}/config?op=UPDATE` | `{"patch": {…}}` | частичное обновление конфигурации произвольным объектом (`p000/zaa.java`) |
| `POST /cameras/{cameraId}?op=SHARE` | `{"grantee_type": "user", "grantee_id": "<…>", "permission": "<…>"}` | выдать доступ другому пользователю (`p000/ro8.java`) |
| `POST /cameras/{cameraId}?op=DELETE` | — | удалить камеру из аккаунта |
| `POST /cameras/{cameraId}/notifications?op=TEST` | карта строк | тестовое уведомление |

## 8.4. SD-карта

```http
POST /cameras/{cameraId}/sd_card?op=CHECK
POST /cameras/{cameraId}/sd_card?op=FORMAT
```

Ответ `CHECK` разбирается кастомным десериализатором (`p000/cg8.java`): если `"available"` ложно — карты нет; иначе объект `{status: <enum>, capacity: <байты>, free: <байты>}` (`p000/zf8.java`).

## 8.5. Сервер (устройство)

В модели Ivideon **сервер** — это устройство/процесс, подключённый к облаку (сама камера с прошивкой Ivideon либо ПК с Ivideon Server), а **камера** — видеоканал на нём. У автономной камеры вроде Cute 2 — один сервер с одной камерой **[вывод]**.

| запрос | тело | смысл |
|---|---|---|
| `POST /servers/{serverId}?op=GET` | `{"projection": {…}}` | данные сервера |
| `POST /servers/{serverId}?op=DELETE` | — | отвязать устройство от аккаунта |
| `POST /servers/{serverId}/software_version?op=UPDATE` | `{"version": "<строка>"}` | запустить обновление прошивки до версии |
| `POST /servers/{serverId}/auth_credentials?op=UPDATE` | `{"username": "…", "password": "…"}` | сменить учётные данные устройства |
| `POST /servers/{serverId}/wifi?op=SCAN` / `?op=CONNECT` | см. [09-camera-attachment.md](09-camera-attachment.md) | Wi-Fi устройства |

> **Осторожно с записью.** `DELETE`, `FORMAT`, `software_version?op=UPDATE`, `auth_credentials?op=UPDATE`, `wifi?op=CONNECT` необратимы или могут оставить камеру без связи. При живых проверках начинайте только с читающих вызовов (`GET`/`FIND`/`CHECK`, плагины с `"method": "GET"`).
