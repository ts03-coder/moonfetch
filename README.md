<div align="center">

# 🌙 moonfetch

**Неблокирующие HTTP/HTTPS-запросы для [MoonLoader](https://www.blast.hk/moonloader/) — без фризов игры.**

![Platform](https://img.shields.io/badge/platform-Windows%20x86-blue)
![LuaJIT](https://img.shields.io/badge/LuaJIT-2.1-2C2D72?logo=lua)
![Rust](https://img.shields.io/badge/written%20in-Rust-orange?logo=rust)
![Tests](https://img.shields.io/badge/tests-16%2F16-brightgreen)
![License](https://img.shields.io/badge/license-MIT-green)

</div>

```lua
local fetch = require 'moonfetch'

local r = fetch.get('https://api.github.com/repos/rust-lang/rust')
print(r.status, r:json().stargazers_count)
```

---

## Зачем

Обычные HTTP-решения для MoonLoader (`copas.http`, `requests`, `socket.http`) работают **в потоке игры**:
DNS-запросы, TLS-рукопожатие и обработка больших ответов на время останавливают кадр. Кроме того,
`copas.http` из стандартной поставки не отправляет SNI — большинство сайтов за Cloudflare/CDN по HTTPS
с ним просто не открываются.

**moonfetch** выполняет каждый запрос в отдельном системном потоке внутри DLL на Rust. Lua-скрипт только
раз в кадр проверяет, готов ли ответ (`wait(0)`), — игра не замечает, что идёт сетевой запрос.

## Возможности

- ⚡ **Без фризов**: сеть, DNS, TLS и распаковка — вне потока игры
- 🔒 **HTTPS** через SChannel: системные сертификаты Windows, SNI, проверка цепочки
- 📦 **gzip**, редиректы, keep-alive, таймауты
- 🧩 **JSON из коробки**: `opts.json = {...}` и `response:json()`
- 🔀 **Параллельные запросы** — сколько угодно одновременно
- 🛡 **Безопасная перезагрузка скриптов**: DLL закреплена в памяти, перезагрузка во время запроса не крашит игру
- 🪶 **Без зависимостей**: одна DLL (~600 КБ) + один Lua-файл, без `lua51.dll`-модулей, vcruntime и OpenSSL

## Установка

1. Скачайте `moonfetch.dll` и `moonfetch.lua` из раздела **Releases**.
2. Положите оба файла в `moonloader/lib/`.

Готово — `require 'moonfetch'` доступен во всех скриптах.

## Использование

### Внутри `main()` или `lua_thread`

Вызов выглядит синхронным, но поток скрипта ждёт через `wait(0)` — игра продолжает работать.

```lua
local fetch = require 'moonfetch'

function main()
    -- GET с параметрами
    local r, err = fetch.get('https://httpbin.org/get', { query = { nick = 'Test_Name' } })
    if not r then return print('сетевая ошибка: ' .. err) end
    print(r.status, r.ok, r.headers['content-type'])
    print(r:json().args.nick)

    -- POST JSON: таблица в качестве тела = JSON
    local r = fetch.post('https://httpbin.org/post', { score = 100 }, {
        headers = { Authorization = 'Bearer TOKEN' },
        timeout = 10000,
    })

    -- POST формы
    fetch.request('POST', 'https://httpbin.org/post', { form = { login = 'x', pass = 'y' } })

    wait(-1)
end
```

### Из колбэков (команды, события SAMP)

В колбэках `wait()` недоступен — используйте `fetch.async`, он сам создаст `lua_thread`:

```lua
sampRegisterChatCommand('ip', function()
    fetch.async('GET', 'https://api.ipify.org?format=json', function(r, err)
        sampAddChatMessage(r and r:json().ip or err, -1)
    end)
end)
```

## API

| Функция | Результат |
|---|---|
| `fetch.request(method, url, [opts])` | `response` или `nil, err` |
| `fetch.get(url, [opts])` / `head` / `delete` | |
| `fetch.post(url, body, [opts])` / `put` / `patch` | `body` — строка (сырое тело) или таблица (JSON) |
| `fetch.async(method, url, [opts], callback)` | `callback(response, err)` в новом `lua_thread` |
| `fetch.urlencode(str)` | |
| `fetch.encode_query(table)` | `a=1&b=2` |
| `fetch.version` | версия DLL |
| `fetch.default_timeout` | таймаут по умолчанию, мс (`30000`) |

### `opts`

| Поле | Тип | Описание |
|---|---|---|
| `headers` | `table` | `{ ['X-Key'] = 'value' }` |
| `body` | `string` | сырое тело (бинарные данные допустимы) |
| `json` | `table` | тело в JSON + `Content-Type: application/json` |
| `form` | `table` | тело `x-www-form-urlencoded` |
| `query` | `table` | параметры, добавляются к URL |
| `timeout` | `number` | мс на весь запрос; `0` — без ограничения |
| `block` | `boolean` | ждать, блокируя поток игры, вместо `wait(0)` |

### `response`

| Поле | Описание |
|---|---|
| `status` | HTTP-код |
| `ok` | `true` для 2xx |
| `body` | тело ответа (байты как есть) |
| `headers` | заголовки, имена в нижнем регистре |
| `url` | итоговый URL после редиректов |
| `:json()` | разобрать тело как JSON |

> [!NOTE]
> Ответы 4xx/5xx — это обычные ответы (проверяйте `r.ok`). `nil, err` возвращается только при сетевой
> ошибке: нет соединения, DNS, TLS, таймаут.

> [!TIP]
> Тело ответа не перекодируется. Сайты обычно отдают UTF-8, а чат SAMP работает в CP1251 —
> перед выводом используйте `u8:decode(r.body)` (`encoding` из стандартной поставки MoonLoader).
> Сообщения об ошибках тоже приходят в UTF-8.

## Сравнение с copas.http

Один и тот же набор тестов для moonfetch и для распространённой обёртки `httpRequest` поверх `copas.http`
(Copas 2.0.2, LuaSocket 3.0-rc1, LuaSec 0.6) на игровом LuaJIT 2.1.0-beta3, 60 FPS.
**Фриз** — кадр дольше 50 мс.

| | moonfetch | copas.http |
|---|---|---|
| Корректность (16 проверок) | ✅ **16/16** | ⚠️ 14/16 |
| HTTPS на сайтах с SNI (Cloudflare, CDN) | ✅ | ❌ `handshake failure` |
| Проверка сертификатов | ✅ | ❌ отключена (`verify = none`) |
| gzip | ✅ распаковывается | ❌ сырые байты |
| Последовательные GET, локальный сервер | **17 мс/запрос** | 36 мс/запрос |
| Скачивание 20 МБ | **166–286 МБ/с**, без фризов | 67–107 МБ/с, фриз до 233 мс |
| Загрузка 5 МБ | **76–100 МБ/с** | 1 МБ/с (4–7 с) |
| 50 параллельных запросов | 322 мс | 348–382 мс |
| Сервер недоступен (порт закрыт) | 2 с | **60 с** + фриз |
| Ошибка DNS | без фриза | фриз до 91 мс |
| Самый долгий кадр за все тесты | на уровне фона | до 233 мс |

Повторить замер можно у себя — см. [Тесты](#тесты).

## Сборка из исходников

Нужны [Rust](https://rustup.rs) и MSVC Build Tools (компонент «Разработка классических приложений на C++»).

```bash
rustup target add i686-pc-windows-msvc
```

```bash
./install.sh
```

`install.sh` собирает `moonfetch.dll` (цель `i686-pc-windows-msvc` и статический CRT заданы в
`.cargo/config.toml`) и копирует DLL и `lua/moonfetch.lua` в `moonloader/lib`. По умолчанию считается,
что репозиторий лежит внутри `moonloader/`; иначе укажите путь: `ML_DIR="C:/GTA/moonloader" ./install.sh`.

## Тесты

`tests/moonfetch_vs_copas.lua` проверяет корректность, скорость и фризы кадров для moonfetch и copas.
Нужен Python 3 для локального тестового сервера `tests/server.py`.

**Без запуска игры** — на игровом `lua51.dll`, MoonLoader эмулируется `tests/harness.lua`:

```bash
./tests/run.sh
```

**В игре**: скопируйте `tests/moonfetch_vs_copas.lua` в `moonloader/`, запустите `python tests/server.py`
и введите в чате `/httptest` (`/httptest noremote` — без тестов, требующих интернет).

Отчёт сохраняется в `moonloader/moonfetch_vs_copas.txt`.

## Как это устроено

```
Lua (moonfetch.lua)                    moonfetch.dll (Rust)
───────────────────                    ────────────────────
fetch.get(url) ──► moonfetch_request ──► новый поток: ureq + SChannel
                   ◄── id                  │
wait(0) ──► moonfetch_poll(id) = 0         │ DNS, TLS, запрос, gzip
wait(0) ──► moonfetch_poll(id) = 1    ◄────┘ результат в таблице по id
            moonfetch_status/headers/body ──► копия в Lua-строки
            moonfetch_free(id)
```

Lua подключает DLL через LuaJIT FFI, поэтому она не зависит от `lua51.dll` и работает с любой сборкой
MoonLoader. Экспортируемый C ABI можно использовать и из других языков (C++/ASI-плагины):

| Функция | Описание |
|---|---|
| `uint32_t moonfetch_request(method, url, headers, body, body_len, timeout_ms)` | старт запроса, возвращает id (`0` — ошибка аргументов); `headers` — строки `"Name: value\n"` |
| `int moonfetch_poll(id)` | `1` готово, `0` в процессе, `-1` неизвестный id |
| `int moonfetch_wait(id, timeout_ms)` | блокирующее ожидание (`0` — без лимита) |
| `int moonfetch_status(id)` | HTTP-код, `0` при сетевой ошибке |
| `const char *moonfetch_error(id)` | текст ошибки или `NULL` |
| `const char *moonfetch_headers(id)` | заголовки ответа `"name: value\n"` |
| `const char *moonfetch_url(id)` | итоговый URL |
| `const char *moonfetch_body(id, size_t *len)` | тело ответа |
| `void moonfetch_free(id)` | освободить результат (можно и для незавершённого запроса) |
| `const char *moonfetch_version(void)` | версия |

Указатели действительны до вызова `moonfetch_free`. Тело ответа ограничено 64 МБ.

## Структура репозитория

```
moonfetch/
├── src/lib.rs              DLL: потоки, HTTP-клиент, C ABI
├── lua/moonfetch.lua       Lua-обёртка (кладётся в moonloader/lib)
├── tests/
│   ├── moonfetch_vs_copas.lua   тесты и бенчмарк (скрипт MoonLoader)
│   ├── server.py               локальный тестовый сервер
│   ├── harness.lua             эмуляция MoonLoader для запуска вне игры
│   ├── luahost.rs              32-битный хост для игрового lua51.dll
│   └── run.sh
├── install.sh
└── Cargo.toml
```

## Лицензия

[MIT](LICENSE) © 2026 Tymchenko Serhii
