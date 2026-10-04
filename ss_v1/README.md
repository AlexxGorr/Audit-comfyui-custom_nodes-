# ComfyUI Custom Nodes Security Scanner

Скрипт для проверки кастомных нод ComfyUI на вредоносный код.
Работает через `docker exec` внутри контейнера `comfyui-megapak`.

**Ничего не удаляет и не изменяет.** Только находит и классифицирует.
Решение — за пользователем.

---

## Быстрый старт

```bash
cd /mnt/c/Users/aiott/Downloads/comfy_docker_pack_app/comfyui-megapak-offline/scripts/scan_nodes

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
scripts/scan_nodes/
├── scan.sh                     # Основной скрипт
├── scan_inner.sh               # Inner script (выполняется в контейнере)
├── install_scan_toolkit.sh     # Установщик на новом ПК
├── README.md                   # Эта документация
├── INSTALL.md                  # Инструкция по переносу
├── CRITICAL_CHECKLIST.md       # Чек-лист при CRITICAL
├── whitelist.txt               # (опционально) ноды для пропуска
├── scan_toolkit.tar.gz         # Архив для переноса
└── reports/
    ├── scan_*.log              # Полные отчёты
    └── suspects_*.log          # Только CRITICAL
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

### `--analyze <path>:<line>`

Анализ конкретной строки с **вердиктом**.

```bash
bash scan.sh --analyze ComfyUI-Easy-Use/py/libs/api/bizyair.py:268
```

**Что выводит:**

1. **Контекст** — ±10 строк вокруг указанной с маркером `▶`.
2. **Вердикт:**
   - [!!] **ОПАСНО** — обфускация (`exec(base64)`, `__import__('os').system`).
   - [!] **ОСОЗНАННЫЙ РИСК** — `pickle.loads`, `exec(var)` в корневом файле.
   - [ok] **НОРМА** — `libc`, `pip install`, `exec(f"...")`.
   - [ok] **ЛОЖНОЕ** — файл в `extern/`, `tools/`, `tests/`, `.disabled`.
3. **Причину** вердикта.
4. **Рекомендацию** — что делать.
5. **Готовые команды** — проверить / отключить.

**Пример:**

```bash
bash scan.sh --analyze comfy_mtb/extern/GFPGAN/cog_predict.py:9
# 📊 Вердикт: [ok] ЛОЖНОЕ
```

### `--help` / `-h`

Справка.

```bash
bash scan.sh --help
```

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

Только CRITICAL. Включает **сводку по нодам в конце** — список нод с hits.

Для быстрого просмотра:

```bash
cat $(ls -t reports/suspects_*.log | head -1)
```

### Секция «ПОДОЗРИТЕЛЬНЫЕ НОДЫ»

В конце вывода сканера и в `suspects_*.log` — **список нод с CRITICAL**:

```
╔══════════════════════════════════════════════════════════════╗
║              [!]  ПОДОЗРИТЕЛЬНЫЕ НОДЫ (CRITICAL)              ║
╚══════════════════════════════════════════════════════════════╝

  [!]  zzz_evil_test_node (7 CRITICAL)
      file: nodes.py

      analyze: Быстрый анализ с вердиктом:
         bash scan.sh --analyze nodes.py:1

      check: Проверить (запускать в WSL!):
         docker exec comfyui-megapak sed -n '1,30p' /root/ComfyUI/custom_nodes/nodes.py

      off: Отключить (запускать в WSL!):
         docker exec comfyui-megapak mv /root/ComfyUI/custom_nodes/zzz_evil_test_node /root/ComfyUI/custom_nodes/zzz_evil_test_node.disabled
```

Если CRITICAL нет:

```
[ok] ПОДОЗРИТЕЛЬНЫХ НОД (CRITICAL): НЕТ
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

---

## Что делать при CRITICAL

См. **`CRITICAL_CHECKLIST.md`** — пошаговая инструкция.

**Краткая версия:**

1. Открыть suspects-файл:

   ```bash
   cat $(ls -t reports/suspects_*.log | head -1)
   ```

2. **Быстрый анализ** — команда `--analyze`:

   ```bash
   bash scan.sh --analyze <node>/<file>:<line>
   ```

   Выводит вердикт: [!!] ОПАСНО / [!] ОСОЗНАННЫЙ РИСК / [ok] НОРМА / [ok] ЛОЖНОЕ.

3. **Классифицировать по пути файла:**
   - `extern/`, `tools/`, `tests/`, `.disabled` → [ok] **ложное, пропустить**.
   - **Корневой `.py`** → [!!] **проверить руками**.

4. **Проверить контекст:**

   ```bash
   docker exec comfyui-megapak sed -n '<line-15>,<line+15>p' /root/ComfyUI/custom_nodes/<path>
   ```

5. Если подтвердилось — **отключить**:

   ```bash
   docker exec comfyui-megapak mv \
       /root/ComfyUI/custom_nodes/<node> \
       /root/ComfyUI/custom_nodes/<node>.disabled
   docker restart comfyui-megapak
   ```

**Полная инструкция — в `CRITICAL_CHECKLIST.md`.**

---

## Whitelist

Файл `whitelist.txt` рядом со скриптом. Одно имя ноды на строку.

```
ComfyUI-Manager
ComfyUI-Impact-Pack
```

[!] **Whitelist = полный пропуск.** Если файлы ноды изменят — ты этого не увидишь.

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
    scan.sh scan_inner.sh install_scan_toolkit.sh README.md INSTALL.md CRITICAL_CHECKLIST.md

# На новом ПК — распаковать и установить
tar -xzf scan_toolkit.tar.gz
bash install_scan_toolkit.sh
bash scan.sh --list
```

---

## История версий

- **v2.6** (текущая) — `--analyze` с вердиктом ([!!]/[!]/[ok]).
- **v2.5** — секция «ПОДОЗРИТЕЛЬНЫЕ НОДЫ» с готовыми командами.
- **v2.4** — проверки существования ноды, обработка ошибок аргументов.
- **v2.3** — прогресс-бары с `#`/`.` историей.
- **v2.2** — двухфазный скан (precount).
- **v2.1** — фильтры localhost/ADMIN/install.
- **v2.0** — базовый скан через `docker exec`.
- **v1** — первоначальный (bind mount).

---

## Автор

Разработано в рамках интерактивной сессии промпт-инжиниринга.

**Дата финализации:** 2026-10-03

---

## Известные ложные срабатывания (v2.6)

Все 25 CRITICAL в мегапаке — ложные:

| Файл | Причина | Вердикт `--analyze` |
|---|---|---|
| `VideoX-Fun/.../midas/backbones/utils.py` | Динамическая регистрация слоёв MiDaS | [ok] НОРМА |
| `comfy_mtb/extern/GFPGAN/cog_predict.py` | Установочный скрипт GFPGAN (внешний) | [ok] ЛОЖНОЕ |
| `comfyui_controlnet_aux/.../run_*.py` | CLI-утилиты Mesh Graphormer | [ok] ЛОЖНОЕ (CLI) |
| `ComfyUI-RMBG/py/AILab_RMBG.py` | Динамическая загрузка модуля BiRefNet | [!] ПОДОЗРИТЕЛЬНО |
| `ComfyUI-UtilsCollection/scripts/manage_*.py` | Внутренняя утилита разработчика | [ok] ЛОЖНОЕ (CLI) |
| `ComfyUI-ReActor.disabled/...` | Отключённая нода | [ok] ЛОЖНОЕ (.disabled) |
| `ComfyUI-Easy-Use/.../bizyair.py` | `pickle.loads` от API BizyAir | [!] ОСОЗНАННЫЙ РИСК |

**Реальных угроз — 0.**

