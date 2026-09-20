# 10. Ошибки

**Теги:** #ошибки #коды_ошибок #HTTP401 #диагностика

Как API сообщает об ошибках и как их классифицирует приложение. Формат тела и коды — **[код]**. **Какой HTTP-статус сервер шлёт с каким кодом — из клиента не определить**: ни один класс ошибки не привязан к статусу (кроме 401), статус просто сохраняется.

## 10.1. Формат ошибки API5

Ошибкой считается **любой не-2xx ответ**. Тело разбирается как ошибка, только если `Content-Type: application/json` (`p000/e21.java:385-412`, `p000/wm3.java:20-21`). Разбор — `p000/C0334eu.java:19-105`, модель `Api5Error` — `p000/C2382pr.java`.

```json
{"success": false, "code": "CAMERA_OFFLINE", "message": "…", "details": {…}}
```

| поле | тип | обязательность |
|---|---|---|
| `success` | boolean, строго `false` | да |
| `code` | string | да |
| `message` | string | да |
| `details` | object | нет. Единственный ключ, который читает клиент, — `retry_at` (Unix-секунды, дробное) при `TOO_MANY_LOGIN_ATTEMPTS` |

Ответ 2xx с `"success": false` клиент считает сбоем протокола (`Unexpected unsuccessful API5 response`).

## 10.2. Алгоритм классификации

`p000/C0297du.java:38-73`:

1. **HTTP 401 → `AuthError`**, независимо от `code`. Это сигнал «токен недействителен» — запускает обновление токена (см. [03-auth.md](03-auth.md)). У `AuthError` есть признаки по тексту `message`: `"Session's subject doesn't exist."` и `"Incorrect login or password"`.
2. `TOO_MANY_LOGIN_ATTEMPTS` → отдельный класс с `details.retry_at`.
3. Поиск `code` в статической таблице (10.3).
4. Поиск в таблице расширений (`p000/xw8.java`, только сервис site-security).
5. Иначе — `GenericError(httpStatus, code)`.

<!-- figure: error-flow | Классификация ответа сервера -->

Рекомендация для своего клиента: ветвиться по **`code`**, статус использовать только для 401 и как запасной признак.

## 10.3. Коды ошибок сервера

Классы — в `com/ivideon/sdk/network/data/error/`. Смысл выведен из имён — **[вывод]**, если не указано иное.

### Общие

| `code` | класс | смысл |
|---|---|---|
| `BAD_REQUEST` | `BadRequestError` | некорректный запрос |
| `OPERATION_RESTRICTED` | `OperationRestrictedError` | операция запрещена для аккаунта/тарифа |
| `FEATURE_NOT_SUPPORTED` | `FeatureNotSupportedError` | устройство/тариф не поддерживает функцию |
| `INACTIVE_SERVICE` | `InactiveServiceError` | платная услуга не активна |
| `LIMIT_EXCEEDED` | `LimitExceededError` | превышен лимит |

### Устройства

| `code` | класс | смысл |
|---|---|---|
| `SERVER_NOT_FOUND` / `SERVER_OFFLINE` | `ServerNotFoundError` / `ServerOfflineError` | устройство не найдено / не на связи |
| `CAMERA_NOT_FOUND` / `CAMERA_OFFLINE` | `CameraNotFoundError` / `CameraOfflineError` | камера не найдена / не на связи |
| `DEVICE_TIMED_OUT` | `DeviceTimedOutError` | устройство не ответило на команду |
| `BAD_DEVICE_CREDENTIALS` | `BadDeviceCredentialsError` | неверные логин/пароль самого устройства |
| `DEVICE_NOT_ALLOWED` | `DeviceNotAllowedError` | |
| `VENDOR_NOT_FOUND` | `VendorNotFoundError` | |
| `UNRECOGNIZED_FORMAT` / `UNSUPPORTED_DEVICE` | `DeviceModelsError.*` | ответы `/device_models?op=RECOGNIZE` |
| `ATTACHMENT_TOKEN_NOT_FOUND` / `TOKEN_FINISHED` | `AttachmentToken…Error` | привязка камеры |
| `MALFORMED_SCHEDULE` | `MalformedScheduleError` | некорректное расписание |

### Права доступа

`SUBJECT_RIGHT_MISSING_FOR_<X>` / `SUBJECT_RIGHT_REVOKED_FOR_<X>`, где `<X>` ∈ `USER`, `SERVER`, `CAMERA`, `ATTACHMENT_TOKEN`, `TIMELAPSE`, `TIMELAPSE_TEMPLATE`, `EXPORTED_RECORD` (для последнего — только `MISSING`). Классы `SubjectRightMissingFor…Error` / `SubjectRightRevokedFor…Error`.

Совместный доступ: `GRANTEE_NOT_FOUND`, `GRANTEE_LIMIT_EXCEEDED`, `GRANTEE_DEMO_RESTRICTION`, `SAME_ACCOUNT` (доступ самому себе), `IMPLICITLY_SHARED`, `PERMISSION_NOT_FOUND`, `PERMISSION_GRANT_NOT_FOUND`.

### Архив, экспорт, таймлапсы

`EMPTY_INTERVAL` (в интервале нет архива), `RECORD_ALREADY_EXISTS`, `RECORD_QUOTA_EXHAUSTED`, `EXPORTED_RECORD_NOT_FOUND`, `EXPORTED_RECORD_NOT_READY`, `TIMELAPSE_NOT_FOUND`, `TIMELAPSE_TEMPLATE_NOT_FOUND`.

### Вход, регистрация, 2FA

| `code` | класс |
|---|---|
| `TOO_MANY_LOGIN_ATTEMPTS` | `TooManyLoginAttemptsError` (+ `details.retry_at`) |
| `USER_NOT_FOUND`, `USER_EXISTS` | `UserNotFoundError`, `UsersExistsError` |
| `PASSWORD_MISMATCH`, `VULNERABLE_PASSWORD` | `PasswordMismatch`, `PasswordVulnerabilityError` |
| `SIGN_UP_REQUIRED` / `SIGNUP_REQUIRED`, `OTP_MISMATCH`, `OTP_LOCKED`, `PROVIDER_ERROR` | семейство `OtpError` (вход по одноразовому коду) |
| `PHONE_NUMBER_USAGE_LIMIT_REACHED` | `PhoneNumberUsageLimitReached` |
| `CHALLENGE_NOT_FOUND`, `CHALLENGE_EXPIRED`, `TWO_FACTOR_METHOD_NOT_FOUND`, `TWO_FACTOR_METHOD_NOT_SELECTED`, `TOO_FREQUENT`, `INVALID_CODE`, `NO_ATTEMPTS_LEFT` | `TwoFaError.*` |
| `BAD_CODE` | `BadCodeError` |
| `EXT_AUTH_ERROR` | `ExternalAuthError` |

## 10.4. Ошибки OAuth-эндпоинта

`/auth/oauth/token` отвечает **не** конвертом API5, а в стиле OAuth2 (`p000/ua0.java`):

```json
{"error": "invalid_grant", "error_description": "…", "reason": "…", "retry_in": 30}
```

| условие | результат (`p000/va0.java`) |
|---|---|
| `error=invalid_request`, `reason=TOO_MANY_LOG_IN_ATTEMPTS` | `TwoFaError.TooManyLoginAttemptsError` с `retry_in` |
| `error=invalid_grant`, `reason=2FA_IS_MANDATORY` | `TwoFaError.TfaIsMandatory` |
| всё прочее | `AuthError` |

Требование второго фактора — **не ошибка**: это ответ 200 с `"proceed_with_2fa": true`, см. [03-auth.md](03-auth.md).

## 10.5. Ошибки, которые клиент порождает сам

| ситуация | ошибка | источник |
|---|---|---|
| не-JSON тело, HTTP 403 | `AccessDeniedError(status, "ACCESS_DENIED")` | `e21.java:423-436` |
| не-JSON тело, HTTP 404 | `NotFoundError(status, "NOT_FOUND")` | там же |
| прочее не-JSON тело или JSON, не прошедший проверку типов | `GenericError(status, "UNEXPECTED_ERROR_" + hex(hash тела))` | `wm3.java:31-33` |
| битый JSON в ошибке / в ответе 200 | `JsonMalformedError` | `e21.java:412-418, 470-475` |
| любое исключение (сеть, TLS, таймаут) | `ExceptionError`, статус 0 | `e21.java:476-482` |
| вызов отменён | `networkcall/CallCanceledError`, статус 0 | |

В строках 423–436 jadx вывел условия `if (i != 403)` инвертированными (метод помечен `Code duplicated`); таблица даёт очевидно задуманное прочтение.

## 10.6. Устаревший API4

Основной сервис его не использует, но адаптер в приложении остался. Конверт: `{"success": bool, "response": …}`; при ошибке `response = {code: int, code_alias: string, message, details}` (`p000/C2233lr.java`, `p000/C0258cr.java`). Числовые коды (`p000/C2196kr.java:17`): `10002` → `AuthError`, `10004` → `NotFoundError`, `10005` → `AlreadyExistsError`, `10008` → `RecursiveGrantingError`, `10020` → `InactiveServiceError`, `20001` → `OperationRestrictedError`, `20003` → `LimitExceededError`.

## 10.7. Рекомендации для своего клиента

* Сначала смотрите HTTP-статус: 2xx → конверт успеха; иначе пробуйте разобрать `{success, code, message}`; не получилось — сохраняйте статус и кусок тела.
* `401` → один раз обновить токен и повторить запрос; повторный 401 → требовать новый вход.
* `CAMERA_OFFLINE` / `SERVER_OFFLINE` — штатная ситуация, а не сбой: показывайте «камера не в сети».
* `TOO_MANY_LOGIN_ATTEMPTS` / `retry_at`, `retry_in`, `TOO_FREQUENT` — **уважайте паузу**, не повторяйте вход в цикле.
* Неизвестные `code` обрабатывайте обобщённо — таблица отражает только то, что знала версия 3.7.1.
