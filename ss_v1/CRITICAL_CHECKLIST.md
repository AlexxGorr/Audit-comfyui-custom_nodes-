# Чек-лист при CRITICAL находках

## [!] ВАЖНО ПЕРЕД НАЧАЛОМ

Все команды запускать **в WSL (Ubuntu)**, а **НЕ в CMD или PowerShell**.

**Как открыть WSL:**
- Из CMD: набери `wsl` + Enter
- Из PowerShell: набери `wsl` + Enter
- Из меню Пуск: приложение Ubuntu

**Проверка:** приглашение должно быть `user@LAPTOP-...:~$` — а не `C:\Users\...>`.

Если запустить `docker exec ... sed` из CMD — получишь `sed: unknown command: '`.

**Правило:** 99% CRITICAL на мегапаке — ложные. Паниковать не нужно.
Но **проверять нужно** — особенно если находка в корневом `.py`.

---

## 1. Быстрая оценка (30 секунд)

Открыть suspects-файл:

```bash
cat $(ls -t reports/suspects_*.log | head -1)
```

Посмотреть **список нод в конце файла** (секция «СВОДКА ПО НОДАМ»).

Открыть **подробный список CRITICAL hits** в начале файла.

---

## 2. Классификация по пути файла (5 секунд)

| Путь начинается с | Вердикт | Что делать |
|---|---|---|
| `extern/`, `third_party/`, `vendor/` | [ok] Ложное | Пропустить |
| `tools/`, `cli/`, `scripts/` | [ok] CLI-скрипт | Пропустить |
| `tests/`, `examples/`, `docs/` | [ok] Тест | Пропустить |
| `*.disabled/` | [ok] Отключено | Пропустить |
| **Корень `.py`** (`__init__.py`, `nodes.py`) | [!!] **Проверить** | Шаг 3 |

**Если файл в `extern/`, `tools/`, `tests/`, `.disabled/` — можно пропустить.**

---

## 3. Быстрый анализ с вердиктом (5 секунд)

Перед ручной проверкой — запусти `--analyze`:

```bash
bash scan.sh --analyze <node>/<file>:<line>
```

Пример:

```bash
bash scan.sh --analyze ComfyUI-Easy-Use/py/libs/api/bizyair.py:268
```

**Что выводит:**
- **Вердикт** — [!!] ОПАСНО / [!] ОСОЗНАННЫЙ РИСК / [ok] НОРМА / [ok] ЛОЖНОЕ.
- **Причину** — почему такой вердикт.
- **Рекомендацию** — что делать.

**Экономит время** — не надо вручную анализировать паттерн.

**Примеры вердиктов:**

| Паттерн | Вердикт |
|---|---|
| `exec(base64...)` | [!!] ОПАСНО |
| `__import__('os').system` | [!!] ОПАСНО |
| `pickle.loads` от API | [!] ОСОЗНАННЫЙ РИСК |
| `exec(var)` в корневом `.py` | [!] ПОДОЗРИТЕЛЬНО |
| `exec(f"...")` | [ok] НОРМА (шаблон) |
| `os.system("pip install ...")` | [ok] НОРМА (установка) |
| `ctypes.CDLL("libc.so.6")` | [ok] НОРМА (libc) |
| `extern/`, `tools/`, `tests/`, `.disabled` | [ok] ЛОЖНОЕ |

---

## 4. Проверка одной находки (вручную)

### 4.1. Открыть контекст

```bash
docker exec comfyui-megapak sed -n '<line-15>,<line+15>p' /root/ComfyUI/custom_nodes/<path>
```

Замени `<line>` на номер строки из отчёта, `<path>` на путь файла.

### 4.2. Понять, откуда данные

**[!!] Опасно:**
- `exec(base64...)` — обфускация
- `exec(input(...))` — пользовательский ввод
- `eval(sys.argv[1])` — аргументы CLI
- `exec(requests.get(...).content)` — сеть
- `pickle.loads(<сеть>)` — сеть
- `__import__('os').system(...)` — обфускация
- `exec(<длинная hex-строка>)` — обфускация

**[ok] Безопасно:**
- `exec("const_string")` — константа
- `exec(f"fixed_template{var}")` — динамическая регистрация
- `exec(open('local_config.py').read())` — локальный файл
- `os.system('pip install package')` — установка
- `pickle.loads(local_file)` — локальный файл
- `ctypes.CDLL("libc.so.6")` — системная библиотека

### 4.3. Где вызывается

```bash
docker exec comfyui-megapak grep -B2 -A2 "exec\|os.system\|pickle\|ctypes" /root/ComfyUI/custom_nodes/<path> | head -30
```

- **Внутри `if __name__ == "__main__"`** → [ok] CLI-скрипт, не исполняется при импорте
- **Внутри класса ноды** → [!] Исполняется при вызове ноды
- **На верхнем уровне модуля** → [!!] Исполняется при импорте ноды

---

## 5. Действия

### [ok] Если ложное (типичный случай)

Ничего не делаем. Просто помним, что это норма.

**Опционально:** добавить ноду в `whitelist.txt`, чтобы больше не видеть.

```bash
echo "comfy_mtb" >> whitelist.txt
```

[!] **Осторожно:** whitelist = полный пропуск сканирования. Если файл изменится — не увидишь.

### [!] Если подозрительное (нужно разобраться)

1. **Отключить ноду:**

   ```bash
   docker exec comfyui-megapak mv \
       /root/ComfyUI/custom_nodes/<node> \
       /root/ComfyUI/custom_nodes/<node>.disabled
   ```

2. **Перезапустить ComfyUI:**

   ```bash
   docker restart comfyui-megapak
   ```

3. **Проверить, что всё работает:**

   ```bash
   curl http://127.0.0.1:8188/
   ```

4. **Разобраться с кодом:**

   ```bash
   docker exec comfyui-megapak cat /root/ComfyUI/custom_nodes/<node>.disabled/<path>
   ```

5. **Удалить, если подтвердилось:**

   ```bash
   docker exec comfyui-megapak rm -rf /root/ComfyUI/custom_nodes/<node>.disabled
   ```

### [!!] Если критичное (обфускация, сеть + exec)

1. **Немедленно отключить:**

   ```bash
   docker exec comfyui-megapak mv \
       /root/ComfyUI/custom_nodes/<node> \
       /root/ComfyUI/custom_nodes/<node>.disabled
   ```

2. **Остановить контейнер:**

   ```bash
   docker stop comfyui-megapak
   ```

3. **Проверить логи на сетевую активность:**

   ```bash
   docker logs comfyui-megapak | tail -200
   docker logs comfyui-megapak | grep -i "http\|request\|post"
   ```

4. **Найти источник ноды.** Откуда скачали? Проверь, что репозиторий официальный.

5. **Удалить и пересоздать контейнер:**

   ```bash
   docker rm comfyui-megapak
   cd /mnt/c/путь/к/папке/с/docker-compose.yml
   docker compose up -d
   ```

---

## 6. Быстрая проверка

### Только CRITICAL

```bash
cat $(ls -t reports/suspects_*.log | head -1) | grep -A3 "CRITICAL"
```

### Только CRITICAL в корневых `.py` (исключая extern/, tests/, tools/)

```bash
grep "\[CRITICAL\]" reports/scan_*.log | \
    grep -v "extern/\|tests/\|tools/\|third_party/\|vendor/"
```

### Список нод с CRITICAL

```bash
cat $(ls -t reports/suspects_*.log | head -1) | grep "[!]"
```

---

## 7. Что НЕ делать

- ❌ **Не паниковать.** 99% CRITICAL — ложные.
- ❌ **Не удалять сразу.** Сначала отключить, проверить, потом удалить.
- ❌ **Не игнорировать всё подряд.** Если `exec(base64...)` в **корневом** `.py` — это реально опасно.
- ❌ **Не использовать whitelist необдуманно.** Пропуск = слепота.

---

## 8. Типичные ложные срабатывания (на мегапаке)

| Нода | Что нашли | Вердикт `--analyze` |
|---|---|---|
| `comfy_mtb` | `os.system` в `extern/GFPGAN/cog_predict.py` | [ok] ЛОЖНОЕ |
| `comfyui_controlnet_aux` | `os.system` в `tools/run_*.py` | [ok] ЛОЖНОЕ (CLI) |
| `VideoX-Fun` | `exec(f"pretrained.{...}")` | [ok] НОРМА |
| `ComfyUI-UtilsCollection` | `exec(compile(...))` в `scripts/` | [ok] ЛОЖНОЕ (CLI) |
| `ComfyUI-RMBG` | `exec(birefnet_content)` | [!] ПОДОЗРИТЕЛЬНО |
| `ComfyUI-ReActor.disabled` | `exec(eval_str)` | [ok] ЛОЖНОЕ (.disabled) |
| `ComfyUI-SeedVR2` | `ctypes.CDLL(libc_path)` | [ok] НОРМА (libc) |
| `ComfyUI-Easy-Use` | `pickle.loads` от BizyAir API | [!] ОСОЗНАННЫЙ РИСК |

---

## 9. Что делать после разбора

- **Сохранить отчёт** для сравнения:

  ```bash
  cp $(ls -t reports/scan_*.log | head -1) ~/baseline_scan_$(date +%F).log
  ```

- **Повторить скан** через месяц или после установки новых нод:

  ```bash
  bash scan.sh --scan-all --stream
  ```

- **Очистить старые отчёты:**

  ```bash
  bash scan.sh --clean-old 5
```
