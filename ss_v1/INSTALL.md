# Установка сканера ComfyUI-нод на новом компьютере

## Требования

На целевом компьютере должно быть установлено:

- **Windows 11**
- **Docker Desktop** с включённой WSL-интеграцией
- **WSL2** (Ubuntu или другой дистрибутив)
- **Контейнер ComfyUI** (например, `comfyui-megapak`)
- Папка с `docker-compose.yml`

## Проверка требований

Открой WSL и выполни:

    docker --version
    docker ps | grep -i comfy

Должен увидеть версию Docker и строку с именем контейнера.

Если контейнера нет — запусти:

    cd /mnt/c/путь/к/папке/с/docker-compose.yml
    docker compose up -d

---

## Быстрая установка

### Шаг 1. Скопировать toolkit на новый ПК

Скопируй `scan_toolkit.tar.gz` в папку с `docker-compose.yml`
(через проводник Windows, флешку, облако — любой способ).

### Шаг 2. Открыть WSL и перейти в папку

    wsl
    cd /mnt/c/Users/<пользователь>/Downloads/comfy_docker_pack_app/comfyui-megapak-offline

### Шаг 3. Распаковать и установить

    tar -xzf scan_toolkit.tar.gz
    bash install_scan_toolkit.sh

Установщик сам:
- Проверит Docker и контейнер.
- Сделает `chmod +x`.
- Исправит CRLF (если есть).
- Проверит синтаксис.
- Обновит имя контейнера в `scan.sh` (если отличается).
- Покажет количество найденных нод.

### Шаг 4. Проверить

    bash scan.sh --list
    bash scan.sh --scan-all --stream
    bash scan.sh --scan-all --threshold CRITICAL
    bash scan.sh --report

---

## Использование

    bash scan.sh --list                       # список нод
    bash scan.sh --scan-all --stream          # полный скан
    bash scan.sh --scan-all --threshold CRITICAL  # только CRITICAL
    bash scan.sh --scan ComfyUI-XXX --stream  # одна нода
    bash scan.sh --report                     # просмотр (q — выход)
    bash scan.sh --clean-old 5                # почистить старые
    bash scan.sh --help                       # справка

---

## Что переносится, что нет

| Файл | Переносим? |
|---|---|
| `scan.sh` | ✅ Да |
| `scan_inner.sh` | ✅ Да |
| `install_scan_toolkit.sh` | ✅ Да |
| `README.md` | ✅ Да |
| `INSTALL.md` | ✅ Да |
| `whitelist.txt` | ⚠️ Опционально |
| `reports/` | ❌ Нет |
| `docker-compose.yml` | ❌ Нет |

---

## Если что-то пошло не так

### Docker не найден

Открой Docker Desktop:
- **Settings** → **Resources** → **WSL Integration**
- Включи **Enable integration with my default WSL distro**
- Включи Ubuntu
- **Apply & Restart**

### Контейнер ComfyUI не запущен

    cd /mnt/c/путь/к/папке/с/docker-compose.yml
    docker compose up -d

### Имя контейнера отличается

    export COMFY_CONTAINER=comfyui-mega
    bash scan.sh --list

Или правь вручную:

    nano scan.sh
    # Найти: CONTAINER="${COMFY_CONTAINER:-comfyui-megapak}"
    # Заменить на нужное
    # Ctrl+O, Enter, Ctrl+X

### CRLF в файлах

    tr -d '\r' < scan.sh > scan.sh.tmp && mv scan.sh.tmp scan.sh
    tr -d '\r' < scan_inner.sh > scan_inner.sh.tmp && mv scan_inner.sh.tmp scan_inner.sh
    chmod +x scan.sh scan_inner.sh

Или просто перезапусти установщик — он сам исправит.

### Скан ничего не находит

    docker ps | grep comfy
    docker exec comfyui-megapak ls /root/ComfyUI/custom_nodes/
    docker exec comfyui-megapak ls -la /tmp/scan_inner.sh

---

## После установки

Первый полный скан:

    bash scan.sh --scan-all --stream 2>&1 | tee /tmp/first_scan.txt

Займёт 3-6 минут. В конце увидишь секцию "ПОДОЗРИТЕЛЬНЫЕ НОДЫ".

Проверить CRITICAL:

    cat $(ls -t reports/suspects_*.log | head -1)

**Ожидаемое на типичном мегапаке:** ~25 CRITICAL, все — ложные.

Повторять регулярно:

    bash scan.sh --scan-all --stream
    bash scan.sh --clean-old 5

---

## Что НЕ делает сканер

- Не удаляет ноды.
- Не блокирует загрузку.
- Не проверяет зависимости (`requirements.txt`).
- Не детектирует обфускацию в `.pyc`.
- Не сканирует `.so`, `.dll`, `.pyd`.

**Только статический анализ** `.py` / `.sh` / `.bat` / `.ps1`.

---

## Просмотр отчётов

Полный отчёт:

    bash scan.sh --report

Выход из `less` — **`q`**.

Только CRITICAL:

    cat $(ls -t reports/suspects_*.log | head -1)

---

## Философия работы

- Сканер проверяет все файлы. Ничего не пропускает.
- Не отличает "плохое место" от "хорошего". Все CRITICAL — на виду.
- Ложные срабатывания — норма. Цена за то, что реальная угроза не будет пропущена.
- Решение — за пользователем.

**При появлении новых CRITICAL** — сначала проверь путь файла
(`extern/`, `tools/`, `tests/` — почти всегда ложные), потом
контекст (`sed -n '<line-10>,<line+10>p'`).

---

## Документация

- **README.md** — полное описание команд и уровней.
- **INSTALL.md** — эта инструкция.

---

## Контакты

При вопросах — см. README.md, раздел «Частые вопросы».
