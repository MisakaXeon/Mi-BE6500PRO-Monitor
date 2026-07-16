#!/bin/sh

set -f

INSTALL_DIR=${INSTALL_DIR:-/data/other_vol/router-monitor}
BIN="$INSTALL_DIR/router-monitor"
CFG="$INSTALL_DIR/config.env"
PID_FILE="$INSTALL_DIR/router-monitor.pid"
LOG_FILE="$INSTALL_DIR/router-monitor.log"
START_LOCK="$INSTALL_DIR/.start.lock"
UPDATE_LOCK="$INSTALL_DIR/.update.lock"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
RESET='\033[0m'

cecho() {
    printf '%b\n' "$*"
}

valid_port() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

valid_interval() {
    case "$1" in
        *s) seconds=${1%s} ;;
        *) return 1 ;;
    esac
    case "$seconds" in
        ""|*[!0-9]*) return 1 ;;
    esac
    [ "$seconds" -ge 1 ] 2>/dev/null
}

valid_listen() {
    listen_port=${1##*:}
    valid_port "$listen_port"
}

load_config() {
    [ -f "$CFG" ] || return 0
    while IFS= read -r config_line || [ -n "$config_line" ]; do
        config_line=$(printf '%s' "$config_line" | tr -d '\r')
        case "$config_line" in
            ""|\#*) continue ;;
        esac
        config_key=${config_line%%=*}
        [ "$config_key" != "$config_line" ] || continue
        config_value=${config_line#*=}
        case "$config_key" in
            LISTEN) valid_listen "$config_value" && CONFIG_LISTEN="$config_value" ;;
            INTERVAL) valid_interval "$config_value" && CONFIG_INTERVAL="$config_value" ;;
        esac
    done <"$CFG"
}

load_config

LISTEN=${CONFIG_LISTEN:-0.0.0.0:9898}
INTERVAL=${CONFIG_INTERVAL:-10s}

update_in_progress() {
    [ -d "$UPDATE_LOCK" ] || return 1
    owner_record=$(cat "$UPDATE_LOCK/owner" 2>/dev/null)
    owner=${owner_record%% *}
    expected_start=${owner_record#* }
    [ -n "$owner" ] || return 1
    [ "${RM_UPDATE_OWNER:-}" = "$owner" ] && return 1
    [ "$expected_start" != "$owner_record" ] || return 1
    kill -0 "$owner" 2>/dev/null || return 1
    actual_start=$(awk '{print $22}' "/proc/$owner/stat" 2>/dev/null)
    [ -n "$actual_start" ] && [ "$actual_start" = "$expected_start" ]
}

ensure_update_idle() {
    if update_in_progress; then
        cecho "${YELLOW}在线更新正在进行，暂不允许启停服务${RESET}"
        return 1
    fi
    return 0
}

is_monitor_pid() {
    candidate="$1"
    [ -n "$candidate" ] || return 1
    kill -0 "$candidate" 2>/dev/null || return 1
    exe=$(readlink "/proc/$candidate/exe" 2>/dev/null)
    [ "$exe" = "$BIN" ]
}

get_pid() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if is_monitor_pid "$pid"; then
            echo "$pid"
            return 0
        fi
    fi
    for pid in $(pidof router-monitor 2>/dev/null); do
        if is_monitor_pid "$pid"; then
            echo "$pid"
            return 0
        fi
    done
    return 1
}

release_start_lock() {
    owner=$(cat "$START_LOCK/owner" 2>/dev/null)
    [ "$owner" = "$$" ] || return 0
    rm -f "$START_LOCK/owner"
    rmdir "$START_LOCK" 2>/dev/null
}

is_start_lock_owner_active() {
    owner="$1"
    [ -n "$owner" ] || return 1
    kill -0 "$owner" 2>/dev/null || return 1
    owner_cmd=$(tr '\000' ' ' <"/proc/$owner/cmdline" 2>/dev/null)
    case "$owner_cmd" in
        *"$INSTALL_DIR/start.sh"*) return 0 ;;
        *) return 1 ;;
    esac
}

acquire_start_lock() {
    attempts=0
    while ! mkdir "$START_LOCK" 2>/dev/null; do
        owner=$(cat "$START_LOCK/owner" 2>/dev/null)
        if [ -z "$owner" ]; then
            attempts=$((attempts + 1))
            [ "$attempts" -lt 3 ] || owner=stale
            if [ "$owner" != "stale" ]; then
                sleep 1
                continue
            fi
        fi
        if is_start_lock_owner_active "$owner"; then
            attempts=$((attempts + 1))
            [ "$attempts" -lt 10 ] || return 1
            sleep 1
            continue
        fi
        rm -f "$START_LOCK/owner"
        rmdir "$START_LOCK" 2>/dev/null || return 1
    done
    echo "$$" >"$START_LOCK/owner"
    trap 'release_start_lock' 0
    trap 'exit 1' 1 2 15
    return 0
}

start_service() {
    pid=$(get_pid)
    if [ -n "$pid" ]; then
        cecho "${GREEN}router-monitor 已在运行，PID: $pid${RESET}"
        return 0
    fi

    if [ ! -x "$BIN" ]; then
        cecho "${RED}未找到可执行文件：$BIN${RESET}"
        return 1
    fi

    mkdir -p "$INSTALL_DIR"

    if ! acquire_start_lock; then
        pid=$(get_pid)
        if [ -n "$pid" ]; then
            cecho "${GREEN}router-monitor 已在运行，PID: $pid${RESET}"
            return 0
        fi
        cecho "${RED}无法获取启动锁：$START_LOCK${RESET}"
        return 1
    fi

    pid=$(get_pid)
    if [ -n "$pid" ]; then
        release_start_lock
        trap - 0 1 2 15
        cecho "${GREEN}router-monitor 已在运行，PID: $pid${RESET}"
        return 0
    fi

    cd "$INSTALL_DIR" || return 1
    rm -f "$PID_FILE"
    started=0
    if command -v start-stop-daemon >/dev/null 2>&1; then
        if start-stop-daemon -S -b -m -p "$PID_FILE" -x "$BIN" -- \
            -listen "$LISTEN" -interval "$INTERVAL" -log "$LOG_FILE"; then
            started=1
        else
            rm -f "$PID_FILE"
            cecho "${YELLOW}start-stop-daemon 启动失败，尝试兼容模式${RESET}"
        fi
    fi
    if [ "$started" -ne 1 ]; then
        "$BIN" -listen "$LISTEN" -interval "$INTERVAL" -log "$LOG_FILE" \
            </dev/null >/dev/null 2>&1 &
        echo $! >"$PID_FILE"
    fi
    sleep 1
    release_start_lock
    trap - 0 1 2 15

    pid=$(get_pid)
    if [ -n "$pid" ]; then
        cecho "${GREEN}router-monitor 已启动，PID: $pid${RESET}"
        cecho "${BLUE}接口地址：http://路由器IP:${LISTEN##*:}/metrics.json${RESET}"
        return 0
    fi

    cecho "${RED}启动失败，请查看日志：$LOG_FILE${RESET}"
    tail -n 20 "$LOG_FILE" 2>/dev/null
    return 1
}

stop_service() {
    pid=$(get_pid)
    if [ -z "$pid" ]; then
        cecho "${YELLOW}router-monitor 未运行${RESET}"
        rm -f "$PID_FILE"
        return 0
    fi

    kill "$pid" 2>/dev/null
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
    cecho "${GREEN}router-monitor 已停止${RESET}"
}

status_service() {
    pid=$(get_pid)
    if [ -n "$pid" ]; then
        cecho "${GREEN}运行中${RESET}，PID: $pid"
        cecho "监听：${BLUE}$LISTEN${RESET}"
        cecho "间隔：${BLUE}$INTERVAL${RESET}"
        return 0
    fi
    cecho "${YELLOW}未运行${RESET}"
    return 1
}

show_metrics() {
    port=${LISTEN##*:}
    if command -v wget >/dev/null 2>&1; then
        wget -qO- "http://127.0.0.1:$port/metrics.json"
    elif command -v curl >/dev/null 2>&1; then
        curl -s "http://127.0.0.1:$port/metrics.json"
    else
        cecho "${RED}未找到 wget/curl，无法请求本地接口${RESET}"
        return 1
    fi
    echo
}

case "$1" in
    start)
        ensure_update_idle || exit 1
        start_service
        ;;
    stop)
        ensure_update_idle || exit 1
        stop_service
        ;;
    restart)
        ensure_update_idle || exit 1
        stop_service
        start_service
        ;;
    status) status_service ;;
    metrics) show_metrics ;;
    log) tail -n "${2:-50}" "$LOG_FILE" 2>/dev/null ;;
    *)
        cecho "${BLUE}用法:${RESET} $0 {start|stop|restart|status|metrics|log}"
        ;;
esac
