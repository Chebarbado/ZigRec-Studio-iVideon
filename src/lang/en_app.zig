//! Английский для окон программы: главное окно, настройки, трей, пульт,
//! уголок MCP, «Разгон», сообщения об ошибках — `src/app/`, `src/errors.zig`,
//! `src/capture/`.
//!
//! Ключ — русская строка ровно как в коде, с теми же подстановками `{…}`
//! в том же порядке. Порядок пар — по файлам, в которых строки встречаются.
const Pair = @import("pair.zig").Pair;

pub const pairs = [_]Pair{
    // src/app/ui.zig — окно настроек
    .{ "Настройки", "Settings" },
    .{ "Сохранить", "Save" },
    .{ "Отмена", "Cancel" },
    .{ "Обзор…", "Browse…" },
    .{ "Папка для записей", "Folder for recordings" },
    .{ "Имя файла: %d — дата, %t — время, %n — номер", "File name: %d — date, %t — time, %n — number" },
    .{ "Обвести область", "Select area" },
    .{ "MCP: адрес и порт", "MCP: address and port" },
    .{ "Поднимать сервер при запуске", "Start the server at launch" },
    .{ "Разгон: включить все ускорения (ultra-speed)", "Boost: turn on all speed-ups (ultra-speed)" },
    .{ "Portable: хранить своё рядом с программой", "Portable: keep data next to the program" },
    .{ "Область записи едет за курсором", "Recording area follows the cursor" },
    .{ "Язык (Language)", "Language" },
    .{ "настройки сохранены", "settings saved" },
    .{ "настройки сохранены; язык сменится после перезапуска программы", "settings saved; the language changes after the program restarts" },
    // src/app/ui.zig — главное окно: кнопки и подписи
    .{ "Весь экран", "Whole screen" },
    .{ "Выбрать область…", "Select area…" },
    .{ "Выбрать окно…", "Select window…" },
    .{ "Записать область", "Record area" },
    .{ "Записать экран", "Record screen" },
    .{ "Звук из колонок", "Speaker sound" },
    .{ "Звук", "Sound" },
    .{ "Кадров/с", "Frames/s" },
    .{ "Качество", "Quality" },
    .{ "Курсор и клики", "Cursor and clicks" },
    .{ "Микрофон", "Microphone" },
    .{ "Открыть запись", "Open recording" },
    .{ "Пауза", "Pause" },
    .{ "Проба 5 с", "Test 5 s" },
    .{ "Редактор дорожек…", "Track editor…" },
    .{ "Усиление", "Gain" },
    .{ "врозь", "separate" },
    .{ "с галочкой звук идёт и в индикатор, и в файл", "when checked, sound goes both to the meter and to the file" },
};
