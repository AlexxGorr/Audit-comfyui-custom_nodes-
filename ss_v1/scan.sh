#!/usr/bin/env bash
# =============================================================================
# scan.sh v2.4 — ComfyUI custom_nodes scanner (docker exec)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTS_DIR="${SCRIPT_DIR}/reports"
WHITELIST_FILE="${SCRIPT_DIR}/whitelist.txt"
INNER_SCRIPT="${SCRIPT_DIR}/scan_inner.sh"
CONTAINER="${COMFY_CONTAINER:-comfyui-megapak}"
NODE_ROOT="/root/ComfyUI/custom_nodes"
INNER_IN_CONTAINER="/tmp/scan_inner.sh"
WL_IN_CONTAINER="/tmp/scan_whitelist.txt"
SUSPECT_FILE=""
CLEAN_KEEP=5
ANALYZE_ARG=""

DISPLAY_MODE="auto"
SCOPE=""
TARGET=""
QUIET=0
INCLUDE_JS=0
SHOW_FILES=1
THRESHOLD="INFO"

TOTAL_NODES=0
CUR_NODE=0
CUR_NODE_NAME=""
CUR_NODE_HITS=0
TOTAL_FILES=0
CUR_FILE=0
CUR_FILE_NAME=""
CUR_FILE_HITS_TOTAL=0
CUR_FILE_CLEAN_TOTAL=0
FILE_HITS_IN_SEGMENT=0
COUNT_CRITICAL=0
COUNT_WARNING=0
COUNT_INFO=0
COUNT_ADMIN=0
LIVE_LINES_DRAWN=0

# Накопители hits для секции "Подозрительные ноды"
declare -a SUSPICIOUS_LINES=()
declare -a SUSPICIOUS_FILES=()
declare -a GLOBAL_SUSPICIOUS_NODES=()
declare -a GLOBAL_SUSPICIOUS_FILES=()
REPORT_FILE=""

declare -a FILE_HISTORY=()
HISTORY_MAX=40

log()  { [ "$QUIET" -eq 1 ] && return 0; printf '%s\n' "$*"; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }

level_num() {
    case "$1" in
        INFO)     echo 1 ;;
        ADMIN)    echo 2 ;;
        WARNING)  echo 3 ;;
        CRITICAL) echo 4 ;;
        *)        echo 0 ;;
    esac
}

passes_threshold() {
    local a b
    a="$(level_num "$1")"
    b="$(level_num "$THRESHOLD")"
    [ "$a" -ge "$b" ]
}

check_env() {
    command -v docker >/dev/null 2>&1 || { err "docker не найден."; exit 1; }
    docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER" || {
        err "Контейнер '$CONTAINER' не запущен."; exit 1
    }
    [ -f "$INNER_SCRIPT" ] || { err "Не найден: $INNER_SCRIPT"; exit 1; }
}

detect_display_mode() {
    [ "$DISPLAY_MODE" != "auto" ] && return 0
    if [ ! -t 1 ] || [ -z "${TERM:-}" ] || [ "${TERM}" = "dumb" ]; then
        DISPLAY_MODE="stream"; return 0
    fi
    if command -v tput >/dev/null 2>&1 && tput cuu 1 >/dev/null 2>&1; then
        DISPLAY_MODE="live"
    else
        DISPLAY_MODE="stream"
    fi
}

precount() {
    log "Подсчёт объёма..."
    local target_path="$NODE_ROOT"
    if [ "$SCOPE" = "scan" ] && [ -n "$TARGET" ]; then
        target_path="$NODE_ROOT/$TARGET"
    fi

    TOTAL_NODES=$(docker exec "$CONTAINER" bash -c "
        if [ -d '$target_path' ]; then
            if [ '$target_path' = '$NODE_ROOT' ]; then
                ls -d '$NODE_ROOT'/*/ 2>/dev/null | wc -l
            else
                echo 1
            fi
        else
            echo 0
        fi
    " 2>/dev/null || echo 0)

    local ext_pattern="-name '*.py' -o -name '*.sh' -o -name '*.bat' -o -name '*.ps1'"
    [ "$INCLUDE_JS" = "1" ] && ext_pattern="$ext_pattern -o -name '*.js'"

    TOTAL_FILES=$(docker exec "$CONTAINER" bash -c "
        find '$target_path' -type f \( $ext_pattern \) \
            -not -path '*/.git/*' -not -path '*/__pycache__/*' \
            -not -path '*/.venv/*' -not -path '*/venv/*' \
            -not -path '*/node_modules/*' 2>/dev/null | wc -l
    " 2>/dev/null || echo 0)

    log "Нод: $TOTAL_NODES, Файлов: $TOTAL_FILES"

    if [ "$TOTAL_NODES" -eq 0 ]; then
        err "Внутри контейнера нет нод в $NODE_ROOT"
        err "Проверь контейнер: docker exec $CONTAINER ls $NODE_ROOT"
        exit 1
    fi

    if [ "$TOTAL_FILES" -eq 0 ]; then
        warn "Файлов для анализа не найдено (все отфильтрованы или нет .py/.sh/.bat/.ps1)."
    fi

    log ""
}

make_history_bar() {
    local width=40
    local bar=""
    local i
    local start=0
    local len=${#FILE_HISTORY[@]}
    [ "$len" -gt "$width" ] && start=$((len - width))

    for ((i=start; i<len; i++)); do
        if [ "${FILE_HISTORY[$i]}" = "1" ]; then
            bar+="#"
        else
            bar+="."
        fi
    done
    local pad=$((width - ${#bar}))
    for ((i=0; i<pad; i++)); do bar+=" "; done
    printf '%s' "$bar"
}

progress_line() {
    local hist_bar
    hist_bar="$(make_history_bar)"
    # Показываем hits в текущем файле + общий счётчик файлов
    if [ "$SHOW_FILES" = "1" ]; then
        printf '[N%d/%d F%d/%d f-hits:%d hit-files:%d] [%s] %s' \
            "$CUR_NODE" "$TOTAL_NODES" "$CUR_FILE" "$TOTAL_FILES" \
            "$FILE_HITS_IN_SEGMENT" "$CUR_FILE_HITS_TOTAL" "$hist_bar" "$CUR_FILE_NAME"
    else
        printf '[N%d/%d f-hits:%d hit-files:%d] [%s] %s' \
            "$CUR_NODE" "$TOTAL_NODES" "$FILE_HITS_IN_SEGMENT" "$CUR_FILE_HITS_TOTAL" \
            "$hist_bar" "$CUR_NODE_NAME"
    fi
}

draw_live() {
    [ "$DISPLAY_MODE" != "live" ] && return 0
    if [ "$LIVE_LINES_DRAWN" -gt 0 ]; then
        printf '\r\033[K'
    fi
    progress_line
    LIVE_LINES_DRAWN=1
}

draw_stream() {
    [ "$DISPLAY_MODE" != "stream" ] && return 0
    [ "$QUIET" -eq 1 ] && return 0
    progress_line
    printf '\n'
}

push_history() {
    local val="$1"
    FILE_HISTORY+=("$val")
    if [ "${#FILE_HISTORY[@]}" -gt "$HISTORY_MAX" ]; then
        FILE_HISTORY=("${FILE_HISTORY[@]:1}")
    fi
}

print_hit() {
    local lvl="$1" loc="$2" snip="$3" reason="$4"

    if [ "$DISPLAY_MODE" = "live" ]; then
        printf '\r\033[K'
    fi

    printf '  [%s] %s\n' "$lvl" "$loc"
    printf '    %s\n' "$snip"
    printf '    → %s\n' "$reason"

    {
        printf '[%s] %s\n' "$lvl" "$loc"
        printf '  Код:    %s\n' "$snip"
        printf '  Причина: %s\n\n' "$reason"
    } >> "$REPORT_FILE"

    if [ "$lvl" = "CRITICAL" ] && [ -n "$SUSPECT_FILE" ]; then
        {
            printf '[%s] %s\n' "$lvl" "$loc"
            printf '  Код:    %s\n' "$snip"
            printf '  Причина: %s\n\n' "$reason"
        } >> "$SUSPECT_FILE"
    fi

    if [ "$DISPLAY_MODE" = "live" ]; then
        LIVE_LINES_DRAWN=0
    fi
}

run_scan() {
    mkdir -p "$REPORTS_DIR"
    local ts; ts="$(date '+%Y-%m-%d_%H-%M-%S')"
    REPORT_FILE="${REPORTS_DIR}/scan_${ts}.log"
    SUSPECT_FILE="${REPORTS_DIR}/suspects_${ts}.log"

    {
        echo "================================================================"
        echo "ComfyUI Custom Nodes Security Scan v2.4"
        echo "Дата: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Контейнер: $CONTAINER"
        echo "Диапазон: $SCOPE ${TARGET:-}"
        echo "Порог: $THRESHOLD | .js: $([ "$INCLUDE_JS" = 1 ] && echo yes || echo no)"
        echo "================================================================"
        echo ""
    } > "$REPORT_FILE"

    : > "$SUSPECT_FILE"

    log "Контейнер: $CONTAINER"
    log "Режим:     $DISPLAY_MODE"
    log "Порог:     $THRESHOLD"
    log "Отчёт:     $REPORT_FILE"
    log ""

    precount

    docker cp "$INNER_SCRIPT" "$CONTAINER:$INNER_IN_CONTAINER" >/dev/null 2>&1 || {
        err "Не удалось скопировать inner script."; exit 1
    }

    local wl_arg=""
    if [ -f "$WHITELIST_FILE" ]; then
        docker cp "$WHITELIST_FILE" "$CONTAINER:$WL_IN_CONTAINER" >/dev/null 2>&1 && \
            wl_arg="$WL_IN_CONTAINER"
    fi

    local scan_root="$NODE_ROOT"
    if [ "$SCOPE" = "scan" ] && [ -n "$TARGET" ]; then
        scan_root="$NODE_ROOT/$TARGET"
    fi

    while IFS='|' read -r event a b c d e; do
        case "$event" in
            NODE_START)
                CUR_NODE=$((CUR_NODE + 1))
                CUR_NODE_NAME="$a"
                CUR_FILE=0
                CUR_NODE_HITS=0
                FILE_HISTORY=()
                SUSPICIOUS_LINES=()
                SUSPICIOUS_FILES=()
                draw_live
                ;;
            NODE_SKIP) log "[WHITELISTED] $a" ;;
            NODE_END)
                if [ "$DISPLAY_MODE" = "stream" ]; then
                    log "  ✓ $a (hits: $CUR_NODE_HITS)"
                fi
                if [ "${#SUSPICIOUS_LINES[@]}" -gt 0 ]; then
                    log ""
                    log "  [!] ПОДОЗРИТЕЛЬНАЯ НОДА: $a - CRITICAL: ${#SUSPICIOUS_LINES[@]}"
                    local s
                    for s in "${SUSPICIOUS_LINES[@]}"; do
                        local s_loc="${s%%|*}"
                        local rest="${s#*|}"
                        local s_snip="${rest%%|*}"
                        local s_reason="${rest##*|}"
                        log "      |- $s_loc"
                        log "      |   Код:    $s_snip"
                        log "      |   Причина: $s_reason"
                    done

                    # Генерируем команды для проверки
                    log ""
                    log "      doc: cat CRITICAL_CHECKLIST.md"
                    log ""

                    # Запоминаем в глобальном списке
                    GLOBAL_SUSPICIOUS_NODES+=("$a|${#SUSPICIOUS_LINES[@]}")
                    # Запоминаем уникальные файлы
                    local f
                    for f in "${SUSPICIOUS_FILES[@]}"; do
                        GLOBAL_SUSPICIOUS_FILES+=("$a|$f")
                    done
                fi
                ;;
            FILE_START)
                CUR_FILE=$((CUR_FILE + 1))
                CUR_FILE_NAME="$(basename "$a")"
                FILE_HITS_IN_SEGMENT=0
                draw_live
                ;;
            FILE_DONE) : ;; # игнорируем
            FILE_END)
                if [ "$FILE_HITS_IN_SEGMENT" -gt 0 ]; then
                    push_history "1"
                    CUR_FILE_HITS_TOTAL=$((CUR_FILE_HITS_TOTAL + 1))
                else
                    push_history "0"
                    CUR_FILE_CLEAN_TOTAL=$((CUR_FILE_CLEAN_TOTAL + 1))
                fi
                if [ "$DISPLAY_MODE" = "live" ]; then
                    draw_live
                else
                    draw_stream
                fi
                ;;
            HIT)
                local lvl="$a" loc="$b" snip="$c" reason="$d"
                case "$lvl" in
                    CRITICAL) COUNT_CRITICAL=$((COUNT_CRITICAL + 1)) ;;
                    WARNING)  COUNT_WARNING=$((COUNT_WARNING + 1)) ;;
                    INFO)     COUNT_INFO=$((COUNT_INFO + 1)) ;;
                    ADMIN)    COUNT_ADMIN=$((COUNT_ADMIN + 1)) ;;
                esac
                CUR_NODE_HITS=$((CUR_NODE_HITS + 1))
                FILE_HITS_IN_SEGMENT=$((FILE_HITS_IN_SEGMENT + 1))
                # Запоминаем CRITICAL для секции "Подозрительные ноды"
                if [ "$lvl" = "CRITICAL" ]; then
                    SUSPICIOUS_LINES+=("$loc|$snip|$reason")
                    # Запоминаем файл (без :line)
                    local hit_file="${loc%:*}"
                    # Проверяем, нет ли уже такого файла
                    local already=0
                    local existing
                    for existing in "${SUSPICIOUS_FILES[@]}"; do
                        [ "$existing" = "$hit_file" ] && already=1 && break
                    done
                    [ "$already" -eq 0 ] && SUSPICIOUS_FILES+=("$hit_file")
                fi
                if passes_threshold "$lvl"; then
                    if [ "$DISPLAY_MODE" = "stream" ]; then
                        draw_stream
                    fi
                    print_hit "$lvl" "$loc" "$snip" "$reason"
                    [ "$DISPLAY_MODE" = "stream" ] && printf '\n'
                fi
                draw_live
                ;;
            SUMMARY)
                TOTAL_NODES="$a"
                [ "$b" -gt "$TOTAL_FILES" ] && TOTAL_FILES="$b"
                ;;
        esac
    done < <(docker exec "$CONTAINER" stdbuf -oL -eL bash "$INNER_IN_CONTAINER" "$scan_root" "$wl_arg" "$INCLUDE_JS" 2>&1)

    [ "$DISPLAY_MODE" = "live" ] && printf '\n'

    {
        echo ""
        echo "--- СВОДКА ---"
        echo "Всего нод:    $TOTAL_NODES"
        echo "Всего файлов: $TOTAL_FILES"
        echo "Файлов чисто: $CUR_FILE_CLEAN_TOTAL"
        echo "Файлов с hits: $CUR_FILE_HITS_TOTAL"
        echo "CRITICAL: $COUNT_CRITICAL"
        echo "WARNING:  $COUNT_WARNING"
        echo "INFO:     $COUNT_INFO"
        echo "ADMIN:    $COUNT_ADMIN"
        echo ""
        echo "Скрипт ничего не изменял и не удалял."
    } >> "$REPORT_FILE"

    log ""
    log "=== СВОДКА ==="
    log "Нод:           $TOTAL_NODES"
    log "Файлов всего:  $TOTAL_FILES"
    log "Чисто:         $CUR_FILE_CLEAN_TOTAL"
    log "С hits:        $CUR_FILE_HITS_TOTAL"
    log "CRITICAL:      $COUNT_CRITICAL"
    log "WARNING:       $COUNT_WARNING"
    log "INFO:          $COUNT_INFO"
    log "ADMIN:         $COUNT_ADMIN"
    log ""
    log "Отчёт:         $REPORT_FILE"
    [ -s "$SUSPECT_FILE" ] && log "Подозрительные: $SUSPECT_FILE"

    # --- Секция подозрительных нод ---
    if [ "${#GLOBAL_SUSPICIOUS_NODES[@]}" -gt 0 ]; then
        log ""
        log "================================================================"
        log "           [!] ПОДОЗРИТЕЛЬНЫЕ НОДЫ (CRITICAL)"
        log "================================================================"
        log ""

        local entry node_name node_count
        for entry in "${GLOBAL_SUSPICIOUS_NODES[@]}"; do
            node_name="${entry%%|*}"
            node_count="${entry##*|}"
            log ""
            log "  [!] $node_name ($node_count CRITICAL)"

            # Файлы с CRITICAL в этой ноде
            local file_entry fnode fpath
            local first_file=""
            for file_entry in "${GLOBAL_SUSPICIOUS_FILES[@]}"; do
                fnode="${file_entry%%|*}"
                fpath="${file_entry#*|}"
                [ "$fnode" = "$node_name" ] || continue
                [ -z "$first_file" ] && first_file="$fpath"
            done

            if [ -n "$first_file" ]; then
                log "      file: $first_file"
                log ""
                log "      analyze: bash $0 --analyze $first_file:1"
                
                log ""
                log "      check (в WSL):"
                log "         docker exec $CONTAINER sed -n '1,30p' $NODE_ROOT/$first_file"
                log ""
                log "      off (в WSL):"
                log "         docker exec $CONTAINER mv $NODE_ROOT/$node_name $NODE_ROOT/$node_name.disabled"
            fi
        done

        log ""
        log "Подробности:"
        log "  cat $(ls -t "$REPORTS_DIR"/suspects_*.log 2>/dev/null | head -1)"
        log ""
        log "doc: CRITICAL_CHECKLIST.md"
        log ""
        log "ВНИМАНИЕ: находки CRITICAL требуют ручной проверки!"
        log "Реальные угрозы редки, но возможны. Открой suspects-файл"
        log "и проверь каждую находку глазами."
    else
        log ""
        log "[ok] ПОДОЗРИТЕЛЬНЫХ НОД (CRITICAL): НЕТ"
    fi

    log ""
    log "Просмотр:      bash $0 --report"

    # --- Дописать секцию подозрительных нод в suspects-файл ---
    if [ -n "$SUSPECT_FILE" ] && [ -f "$SUSPECT_FILE" ]; then
        {
            echo ""
            echo "================================================================"
            echo "  СВОДКА ПО НОДАМ"
            echo "================================================================"
            echo ""
            if [ "${#GLOBAL_SUSPICIOUS_NODES[@]}" -gt 0 ]; then
                local entry node_name node_count
                for entry in "${GLOBAL_SUSPICIOUS_NODES[@]}"; do
                    node_name="${entry%%|*}"
                    node_count="${entry##*|}"
                    echo "  [!] $node_name - $node_count CRITICAL"
                done
            else
                echo "  [ok] Нет нод с CRITICAL"
            fi
            echo ""
        } >> "$SUSPECT_FILE"
    fi
}

check_target_exists() {
    [ "$SCOPE" != "scan" ] && return 0
    [ -z "$TARGET" ] && { err "Не указано имя ноды для --scan"; exit 2; }

    if ! docker exec "$CONTAINER" test -d "$NODE_ROOT/$TARGET" 2>/dev/null; then
        err "Нода не найдена: $TARGET"
        err "Проверь имя через: bash $0 --list"
        err "Внутри контейнера: $NODE_ROOT/$TARGET"
        exit 1
    fi
}

clean_old() {
    local keep="${1:-5}"
    mkdir -p "$REPORTS_DIR"

    local scan_count
    scan_count=$(ls -1 "$REPORTS_DIR"/scan_*.log 2>/dev/null | wc -l)
    local susp_count
    susp_count=$(ls -1 "$REPORTS_DIR"/suspects_*.log 2>/dev/null | wc -l)

    log "Найдено отчётов: scan=$scan_count, suspects=$susp_count"
    log "Оставляю последние: $keep"
    log ""

    local removed=0

    if [ "$scan_count" -gt "$keep" ]; then
        while IFS= read -r f; do
            log "  rm $f"
            rm -f "$f"
            removed=$((removed + 1))
        done < <(ls -1t "$REPORTS_DIR"/scan_*.log 2>/dev/null | tail -n +$((keep + 1)))
    fi

    if [ "$susp_count" -gt "$keep" ]; then
        while IFS= read -r f; do
            log "  rm $f"
            rm -f "$f"
            removed=$((removed + 1))
        done < <(ls -1t "$REPORTS_DIR"/suspects_*.log 2>/dev/null | tail -n +$((keep + 1)))
    fi

    log ""
    log "Удалено: $removed файлов."
    log "Осталось:"
    ls -1 "$REPORTS_DIR" 2>/dev/null | head -20 | sed 's/^/  /'
}

analyze_line() {
    local path="$1"
    local line="$2"

    if [ -z "$path" ] || [ -z "$line" ]; then
        err "Использование: bash $0 --analyze <node>/<file>:<line>"
        return 1
    fi

    # Проверить существование файла
    if ! docker exec "$CONTAINER" test -f "$NODE_ROOT/$path" 2>/dev/null; then
        err "Файл не найден: $NODE_ROOT/$path"
        return 1
    fi

    local ctx_start=$((line - 10))
    [ "$ctx_start" -lt 1 ] && ctx_start=1
    local ctx_end=$((line + 10))

    log "═══════════════════════════════════════════════════════════════════"
    log "  Анализ: $path:$line"
    log "═══════════════════════════════════════════════════════════════════"
    log ""
    log "Контекст (строки ${ctx_start}-${ctx_end}):"
    log "───────────────────────────────────────────────────────────────────"

    docker exec "$CONTAINER" sed -n "${ctx_start},${ctx_end}p" "$NODE_ROOT/$path" | \
        awk -v start="$ctx_start" -v target="$line" '
            {
                lineno = start + NR - 1
                if (lineno == target) {
                    printf "▶ %4d: %s\n", lineno, $0
                } else {
                    printf "  %4d: %s\n", lineno, $0
                }
            }
        '

    log "───────────────────────────────────────────────────────────────────"
    log ""

    # Получить целевую строку
    local target_line
    target_line="$(docker exec "$CONTAINER" sed -n "${line}p" "$NODE_ROOT/$path" 2>/dev/null)"
    local trimmed="${target_line#"${target_line%%[![:space:]]*}"}"

    # Классификация
    local verdict=""
    local reason=""
    local recommendation=""

    # === 1. По пути ===
    case "$path" in
        extern/*|*/extern/*|third_party/*|*/third_party/*|vendor/*|*/vendor/*)
            verdict="[ok] ЛОЖНОЕ"
            reason="Файл в сторонней библиотеке (extern/third_party/vendor)."
            recommendation="Сторонние библиотеки не исполняются ComfyUI при импорте."
            ;;
        tools/*|*/tools/*|cli/*|*/cli/*|scripts/*|*/scripts/*)
            verdict="[ok] ЛОЖНОЕ (CLI)"
            reason="CLI-скрипт в tools/, cli/, scripts/."
            recommendation="Запускается вручную, не исполняется при импорте ноды."
            ;;
        */tests/*|*/test/*|*/examples/*|*/example/*|*/docs/*)
            verdict="[ok] ЛОЖНОЕ (тест)"
            reason="Тестовый файл или пример."
            recommendation="Не исполняется в продакшене."
            ;;
        *.disabled/*|*.disabled|*.disabled)
            verdict="[ok] ЛОЖНОЕ (.disabled)"
            reason="Нода отключена."
            recommendation="ComfyUI её не загружает."
            ;;
        *)
            # === 2. По паттернам в строке ===
            if [[ "$trimmed" =~ exec\(.*base64 ]] || [[ "$trimmed" =~ exec\(.*b64decode ]]; then
                verdict="[!!] ОПАСНО"
                reason="exec() + base64 — обфусцированная нагрузка."
                recommendation="НЕМЕДЛЕННО отключить ноду: bash scan.sh --report; mv <node> <node>.disabled"
            elif [[ "$trimmed" =~ __import__.*os.*system ]]; then
                verdict="[!!] ОПАСНО"
                reason="Обфусцированный вызов os.system через __import__."
                recommendation="НЕМЕДЛЕННО отключить ноду."
            elif [[ "$trimmed" =~ eval\(.*input\( ]] || [[ "$trimmed" =~ exec\(.*input\( ]]; then
                verdict="[!!] ОПАСНО"
                reason="exec/eval от пользовательского ввода."
                recommendation="НЕМЕДЛЕННО отключить ноду."
            elif [[ "$trimmed" =~ exec\(.*sys\.argv ]]; then
                verdict="[!!] ОПАСНО"
                reason="exec() от аргументов CLI."
                recommendation="Проверить, откуда приходят аргументы."
            elif [[ "$trimmed" =~ exec\(f ]] || [[ "$trimmed" =~ exec\(\" ]] || [[ "$trimmed" =~ exec\(\' ]]; then
                verdict="[ok] НОРМА (шаблон)"
                reason="exec() с фиксированным шаблоном — динамическая регистрация."
                recommendation="Проверить, что шаблон не содержит внешних данных."
            elif [[ "$trimmed" =~ os\.system\(.*pip ]]; then
                verdict="[ok] НОРМА (установка)"
                reason="os.system с pip — установка зависимостей."
                recommendation="Стандартная практика для install.py."
            elif [[ "$trimmed" =~ ctypes\.CDLL.*(libc|libcudart|libcuda|nvrtc) ]]; then
                verdict="[ok] НОРМА (libc)"
                reason="Загрузка системной библиотеки (libc/libcuda/nvrtc)."
                recommendation="Используется для оптимизации памяти/GPU."
            elif [[ "$trimmed" =~ pickle\.loads ]]; then
                verdict="[!] ОСОЗНАННЫЙ РИСК"
                reason="pickle.loads — опасная десериализация."
                recommendation="Проверить источник данных: сеть (requests/urllib) = риск; локальный файл = норма."
            elif [[ "$trimmed" =~ exec\(open\( ]]; then
                verdict="[!] ПРОВЕРИТЬ"
                reason="exec(open('...').read()) — динамическая загрузка локального файла."
                recommendation="Проверить содержимое файла, который загружается."
            elif [[ "$trimmed" =~ exec\( ]]; then
                verdict="[!] ПОДОЗРИТЕЛЬНО"
                reason="exec() в корневом файле — нужно понять источник данных."
                recommendation="Проверить: откуда данные для exec() — константа (норма) или переменная (риск)."
            elif [[ "$trimmed" =~ os\.system ]] || [[ "$trimmed" =~ subprocess ]]; then
                verdict="[!] ПОДОЗРИТЕЛЬНО"
                reason="Вызов внешнего процесса в корневом файле."
                recommendation="Проверить аргументы: константы (норма) или переменные (риск)."
            elif [[ "$trimmed" =~ ctypes\.CDLL ]]; then
                verdict="[!] ПОДОЗРИТЕЛЬНО"
                reason="Загрузка нативной библиотеки."
                recommendation="Проверить путь к библиотеке — системная или из /tmp/."
            else
                verdict="[?] НЕ ОПРЕДЕЛЕНО"
                reason="Паттерн не распознан."
                recommendation="Посмотреть контекст выше и решить вручную."
            fi
            ;;
    esac

    log "VERDICT: $verdict"
    log "   Причина: $reason"
    log ""
    log "NOTE:"
    log "   $recommendation"
    log ""
    log "───────────────────────────────────────────────────────────────────"
    log ""
    log "file: Файл целиком (первые 30 строк):"
    log "   docker exec $CONTAINER sed -n '1,30p' $NODE_ROOT/$path"
    log ""
    log "off: Отключить ноду (если подтвердится):"
    local node_name="${path%%/*}"
    log "   docker exec $CONTAINER mv $NODE_ROOT/$node_name $NODE_ROOT/$node_name.disabled"
    log ""
}

list_nodes() {
    local root="$NODE_ROOT"
    log "Доступные ноды в $root:"
    log "------------------------------------------------------------"
    docker exec "$CONTAINER" bash -c "
        for d in $root/*/; do
            [ -d \"\$d\" ] || continue
            name=\$(basename \"\$d\")
            size=\$(du -sh \"\$d\" 2>/dev/null | cut -f1)
            files=\$(find \"\$d\" -type f -name '*.py' -not -path '*/.git/*' -not -path '*/__pycache__/*' 2>/dev/null | wc -l)
            printf '  %-45s %8s  %4d .py\\n' \"\$name\" \"\$size\" \"\$files\"
        done
    "
    log "------------------------------------------------------------"
}

show_report() {
    local latest
    latest="$(ls -1t "$REPORTS_DIR"/scan_*.log 2>/dev/null | head -n1)"
    [ -z "$latest" ] && { err "Отчётов пока нет."; return 1; }
    if command -v less >/dev/null 2>&1; then less "$latest"; else cat "$latest"; fi
}

show_help() {
    cat <<'HELP_EOF'
scan.sh v2.4 — security scanner для ComfyUI custom_nodes

Использование:
  bash scan.sh --scan <node> [опции]
  bash scan.sh --scan-all [опции]
  bash scan.sh --report
  bash scan.sh --help

Опции:
  --scan <name>       Сканировать конкретную ноду.
  --scan-all          Сканировать все ноды.
  --list              Список доступных нод.
  --clean-old [N]     Удалить старые отчёты, оставить N (по умолч. 5).
  --analyze <path>:<line>  Анализ конкретной строки с вердиктом.
  --threshold LEVEL   Порог: INFO|ADMIN|WARNING|CRITICAL (по умолч. INFO).
  --live / --stream   Режим отображения.
  --include-js        Включить .js-файлы.
  --no-files          Компактный режим.
  --quiet             Только финальная сводка.
  --report, -r        Просмотр последнего отчёта.
  --help, -h          Эта справка.

Прогресс:
  [N5/74 F128/4474 hits:8] [#..#..#.....] file.py
  N — ноды, F — файлы, hits — файлов с hits,
  [ # . ] — история последних 40 файлов.

Отчёты:
  reports/scan_*.log       Полный отчёт.
  reports/suspects_*.log   Только CRITICAL.
HELP_EOF
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --list)        SCOPE="list"; shift ;;
            --analyze)
                if [ -z "${2:-}" ]; then
                    err "Использование: --analyze <node>/<file>:<line>"
                    exit 2
                fi
                ANALYZE_ARG="$2"
                SCOPE="analyze"
                shift 2
                ;;
            --clean-old)
                SCOPE="clean"
                if [ -n "${2:-}" ] && [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                    CLEAN_KEEP="$2"
                    shift 2
                else
                    CLEAN_KEEP=5
                    shift
                fi
                ;;
            --scan)
                SCOPE="scan"
                if [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
                    err "Не указано имя ноды для --scan"
                    err "Использование: bash $0 --scan <node_name>"
                    exit 2
                fi
                TARGET="$2"
                shift 2
                ;;
            --scan-all)    SCOPE="scan-all"; shift ;;
            --threshold)
                if [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
                    err "Не указан уровень для --threshold"
                    err "Допустимые: INFO|ADMIN|WARNING|CRITICAL"
                    exit 2
                fi
                THRESHOLD="$2"
                shift 2
                ;;
            --live)        DISPLAY_MODE="live"; shift ;;
            --stream)      DISPLAY_MODE="stream"; shift ;;
            --include-js)  INCLUDE_JS=1; shift ;;
            --no-files)    SHOW_FILES=0; shift ;;
            --quiet)       QUIET=1; shift ;;
            --report|-r)   show_report; exit $? ;;
            --help|-h)     show_help; exit 0 ;;
            *) err "Неизвестный аргумент: $1"; show_help; exit 2 ;;
        esac
    done
    [ -z "$SCOPE" ] && { show_help; exit 0; }
    check_env
    check_target_exists
    if [ "$SCOPE" = "list" ]; then
        list_nodes
        exit 0
    fi
    if [ "$SCOPE" = "analyze" ]; then
        local path="${ANALYZE_ARG%:*}"
        local line="${ANALYZE_ARG##*:}"
        analyze_line "$path" "$line"
        exit 0
    fi
    if [ "$SCOPE" = "clean" ]; then
        clean_old "$CLEAN_KEEP"
        exit 0
    fi
    detect_display_mode
    run_scan
}

main "$@"
