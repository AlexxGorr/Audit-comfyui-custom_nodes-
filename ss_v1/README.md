# ComfyUI Custom Nodes Security Scanner
Ниже — **актуальный README.md** под финальную версию (`v2.4+`, с `--list`, `--clean-old`, `f-hits`/`hit-files`, `install_scan_toolkit.sh`).

И **команда PowerShell** для создания файла — если хочешь записать его **из Windows** (а не из WSL). Но с оговоркой: `README.md` — это **markdown**, CRLF ему не мешает. Так что можно смело писать из PowerShell.

---

## 📄 Актуальный `README.md`

```markdown
# ComfyUI Custom Nodes Security Scanner

Скрипт для проверки кастомных нод ComfyUI на вредоносный код.
Работает через `docker exec` внутри контейнера `comfyui-megapak`.

**Ничего не удаляет и не изменяет.** Только находит и классифицирует.
Решение — за пользователем.

---

## Быстрый старт

```bash
cd /mnt/c/Users/aiott/Downloads/comfy_docker_pack_app/comfyui-megapak-offline

# Список всех нод
bash scan.sh --list

# Сканировать всё
bash scan.sh --scan-all --stream

# Только CRITICAL
bash scan.sh --scan-all --threshold CRITICAL

# Просмотр последнего отчёта (q — выход из less)
bash scan.sh --report
```

---

## Файлы

```
comfyui-megapak-offline/
├── scan.sh                     # Основной скрипт
├── scan_inner.sh               # Inner script (выполняется в контейнере)
├── install_scan_toolkit.sh     # Установщик на новом ПК
├── README.md                   # Эта документация
├── INSTALL.md                  # Инструкция по переносу
├── whitelist.txt               # (опционально) ноды для пропуска
├── reports/
│   ├── scan_*.log              # Полные отчёты
│   └── suspects_*.log          # Только CRITICAL
└── _backup/                    # Бэкапы старых версий
```

---

## Команды

### `--list`

Выводит список нод с размером и количеством `.py`-файлов.

```bash
bash scan.sh --list
```

### `--scan <name>`

Сканирует конкретную ноду.

```bash
bash scan.sh --scan ComfyUI-Impact-Pack --stream
```

Имя ноды — из `--list`.

### `--scan-all`

Сканирует все ноды.

```bash
bash scan.sh --scan-all --stream
```

### `--threshold LEVEL`

Показывает только hits указанного уровня и выше.

```bash
bash scan.sh --scan-all --threshold WARNING    # WARNING + CRITICAL
bash scan.sh --scan-all --threshold CRITICAL   # только CRITICAL
```

Уровни (по возрастанию): `INFO < ADMIN < WARNING < CRITICAL`.

### `--stream` / `--live`

- `--stream` — построчный режим (для CMD/PowerShell).
- `--live` — обновление на месте (для WSL).

По умолчанию — auto-детект.

### `--include-js`

Включает `.js`-файлы в скан. По умолчанию игнорируются (минифицированные бандлы дают шум).

```bash
bash scan.sh --scan-all --include-js --stream
```

### `--no-files`

Компактный режим — без счётчика файлов.

```bash
bash scan.sh --scan-all --no-files
```

### `--quiet`

Только финальная сводка.

```bash
bash scan.sh --scan-all --quiet
```

### `--report` / `-r`

Открывает последний отчёт. Выход из `less` — **`q`**.

```bash
bash scan.sh --report
```

### `--clean-old [N]`

Удаляет старые отчёты, оставляет N последних (по умолчанию 5).

```bash
bash scan.sh --clean-old       # оставить 5
bash scan.sh --clean-old 10    # оставить 10
```

### `--help` / `-h`

Справка.

---

## Уровни риска

| Уровень | Что попадает |
|---|---|
| **CRITICAL** | `exec(base64)`, `os.system` (не в install), `pickle.loads` (не recv/buffer), `ctypes.CDLL` (не libc*), `os.exec*` (не routes) |
| **WARNING** | `requests.get/post` на внешний, `urllib.urlopen`, `socket.socket`, `sys.path.insert`, длинные строки, `pickle.loads(recv)`, `ctypes.CDLL(libc*)` |
| **INFO** | `importlib.import_module`, `exec` в тестах, `sys.exit` в CLI, `exec` в установочных |
| **ADMIN** | `os.system`/`exec` в `install.py`/`setup.py`, `shutil.rmtree`, `os.kill`, `os.execv` в routes/manager |

### Игнорируются (не выводятся)

- `.eval()` — метод PyTorch.
- `literal_eval` — безопасная функция.
- `sys.path.insert` с `__file__`/`dirname`.
- `pip install` в комментариях и `.bat`.
- `requests.*` на `127.0.0.1`/`localhost`.
- `os.system('color')` — Windows-команда.

---

## Формат вывода

```
[N1/73 F2/3699 f-hits:2 hit-files:1] [.#                    ] install.py
  [ADMIN] install.py:102
    shutil.rmtree(subpack_path)
    → Административная операция.
```

Расшифровка:

- `N1/73` — нода 1 из 73.
- `F2/3699` — файл 2 из 3699.
- `f-hits:2` — hits **в текущем файле**.
- `hit-files:1` — **файлов с hits** всего (не hits!).
- `[.#...]` — история последних 40 файлов:
  - `#` — файл с hits.
  - `.` — чистый файл.
  - пробел — файлы ещё не обработаны.

### Пример чтения

```
[N62/73 F57/3699 f-hits:4 hit-files:207] [.....#...............##.#................##.#] install.py
```

> «Нода 62 из 73. Файл 57 из 3699. В файле `install.py` — 4 hits. До него
> 207 файлов уже имели hits. Последние 40 файлов: 5 с hits, 30 чистых,
> 5 с hits.»

---

## Отчёты

### `reports/scan_*.log`

Полный отчёт со всеми hits. Открывается через `bash scan.sh --report`.

### `reports/suspects_*.log`

Только CRITICAL. Для быстрого просмотра:

```bash
cat $(ls -t reports/suspects_*.log | head -1)
```

---

## Ожидаемые результаты

На мегапаке (73 ноды, 3699 `.py`-файлов):

| Уровень | Ожидаемое |
|---|---|
| CRITICAL | 20-30 (почти все ложные) |
| WARNING | 80-100 |
| INFO | 100-130 |
| ADMIN | 120-150 |

**При CRITICAL > 50** — пришли вывод, разберём.

---

## Что делать при подозрении

Если видишь `exec(base64...)` или `socket.connect(<external>)` в **рабочем**
`.py` (не `tests/`, не `extern/`, не `tools/`):

```bash
# Посмотреть контекст
docker exec comfyui-megapak sed -n '<line-10>,<line+10>p' /root/ComfyUI/custom_nodes/<path>
```

**Если подтвердилось:**

1. Отключить ноду: переименовать папку в `.disabled`.
2. Перезапустить ComfyUI.
3. Удалить ноду: `docker exec comfyui-megapak rm -rf /root/ComfyUI/custom_nodes/<node>`.

---

## Whitelist

Файл `whitelist.txt` рядом со скриптом. Одно имя ноды на строку.

```
ComfyUI-Manager
ComfyUI-Impact-Pack
```

⚠️ **Whitelist = полный пропуск.** Если файлы ноды изменят — ты этого не увидишь.

**Лучше** использовать `--threshold CRITICAL` вместо whitelist.

---

## Частые вопросы

### Отчёт пустой — что делать?

- Проверь, что контейнер запущен: `docker ps | grep comfy`.
- Проверь, что `scan_inner.sh` есть рядом со `scan.sh`.
- Запусти с `--threshold INFO` (по умолчанию скрывает всё ниже).

### `less` не выходит

Нажми **`q`**.

### Скрипт долго работает

73 ноды × ~50 файлов × построчный анализ = **3-6 минут**. Это норма.

Ускорить:

- `--threshold WARNING` (меньше вывода).
- `--no-files` (меньше строк прогресса).
- Сканировать конкретные ноды через `--scan`.

### Проверять каждый раз полностью?

**Да.** Файлы нод могут изменяться (обновления, подмена).
Хеши не считаем — только полный скан.

Если нужен инкрементальный скан (`--diff` с хешами) — запросить отдельно.

### Скрипт зависает на `--scan` без имени

Исправлено в v2.4+. Если видишь зависание — проверь версию:

```bash
grep "scan.sh v" scan.sh
```

Должно быть `v2.4` или выше.

---

## Что НЕ делает скрипт

- ❌ Не удаляет ноды.
- ❌ Не блокирует загрузку.
- ❌ Не проверяет зависимости (`requirements.txt`).
- ❌ Не детектирует обфускацию в `.pyc` (только `.py`).
- ❌ Не сканирует `.so`, `.dll`, `.pyd` (бинарь).

**Только статический анализ** `.py` / `.sh` / `.bat` / `.ps1` файлов.

---

## Перенос на другой компьютер

См. `INSTALL.md`.

Кратко:

```bash
# На исходной машине — создать архив
tar -czf scan_toolkit.tar.gz \
    scan.sh scan_inner.sh install_scan_toolkit.sh README.md INSTALL.md

# На новом ПК — распаковать и установить
tar -xzf scan_toolkit.tar.gz
bash install_scan_toolkit.sh
bash scan.sh --list
```

---

## История версий

- **v2.4+** (текущая) — стабильная, `--list`, `--clean-old`, `f-hits`/`hit-files`.
- **v2.4** — проверки существования ноды, обработка ошибок аргументов.
- **v2.3** — прогресс-бары с `#`/`.` историей.
- **v2.2** — двухфазный скан (precount).
- **v2.1** — фильтры localhost/ADMIN/install.
- **v2.0** — базовый скан через `docker exec`.
- **v1** — первоначальный (bind mount).

---

## Автор

Разработано в рамках интерактивной сессии промпт-инжиниринга.

**Дата финализации:** 2026-09-26

---

## Известные ложные срабатывания (v2.4+)

Все 25 CRITICAL в мегапаке — ложные:

| Файл | Причина |
|---|---|
| `VideoX-Fun/.../midas/backbones/utils.py` | Динамическая регистрация слоёв MiDaS |
| `comfy_mtb/extern/GFPGAN/cog_predict.py` | Установочный скрипт GFPGAN (внешний) |
| `comfyui_controlnet_aux/.../run_*.py` | CLI-утилиты Mesh Graphormer |
| `ComfyUI-RMBG/py/AILab_RMBG.py` | Динамическая загрузка модуля BiRefNet |
| `ComfyUI-UtilsCollection/scripts/manage_*.py` | Внутренняя утилита разработчика |
| `ComfyUI-ReActor.disabled/...` | Отключённая нода |
| `ComfyUI-Easy-Use/.../bizyair.py` | `pickle.loads` от API BizyAir |

**Реальных угроз — 0.**
```

---

## 💻 Команда PowerShell для создания файла

Если хочешь **создать README.md из Windows** (не из WSL), есть 3 варианта.

### Вариант A: PowerShell с here-string

⚠️ **Проблема:** here-string `@'...'@` **не поддерживает** markdown-тройные кавычки (```` ``` ````) — они конфликтуют с терминатором. Придётся **экранировать** или использовать другой подход.

**Проще всего:**

```powershell
# Открыть папку
cd "C:\Users\aiott\Downloads\comfy_docker_pack_app\comfyui-megapak-offline"

# Создать через Notepad (вставишь содержимое вручную)
notepad README.md
```

Или **через VS Code**:

```powershell
cd "C:\Users\aiott\Downloads\comfy_docker_pack_app\comfyui-megapak-offline"
code README.md
```

### Вариант B: PowerShell + Set-Content с массивом строк

Громоздко, но работает:

```powershell
cd "C:\Users\aiott\Downloads\comfy_docker_pack_app\comfyui-megapak-offline"

$content = @(
'# ComfyUI Custom Nodes Security Scanner',
'',
'Скрипт для проверки кастомных нод ComfyUI на вредоносный код.',
'Работает через `docker exec` внутри контейнера `comfyui-megapak`.',
'',
'**Ничего не удаляет и не изменяет.**',
''
)

$content | Set-Content -Path README.md -Encoding UTF8
```

### Вариант C (рекомендую): Создать README.md **из WSL** через `cat`

Это **самый надёжный путь** — потому что:

- Markdown-синтаксис (```` ``` ````) не ломается.
- LF-переводы строк (Windows-Notepad раньше ломал, но в 11-м уже норм).
- Никаких PowerShell-эскейпов.

**Команда для WSL:**

```bash
cd /mnt/c/Users/aiott/Downloads/comfy_docker_pack_app/comfyui-megapak-offline

cat > README.md <<'README_EOF'
# ComfyUI Custom Nodes Security Scanner
... (вставить весь контент выше) ...
