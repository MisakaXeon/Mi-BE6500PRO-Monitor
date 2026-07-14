#!/bin/sh

INSTALL_DIR=${INSTALL_DIR:-/data/other_vol/router-monitor}
BIN="$INSTALL_DIR/router-monitor"
CFG="$INSTALL_DIR/config.env"
PID_FILE="$INSTALL_DIR/router-monitor.pid"
LOG_FILE="$INSTALL_DIR/router-monitor.log"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
RESET='\033[0m'

cecho() {
    printf '%b\n' "$*"
}

[ -f "$CFG" ] && . "$CFG"

LISTEN=${LISTEN:-0.0.0.0:9898}
INTERVAL=${INTERVAL:-10s}

get_pid() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi
    pidof router-monitor 2>/dev/null | awk '{print $1}'
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
    cd "$INSTALL_DIR" || return 1
    "$BIN" -listen "$LISTEN" -interval "$INTERVAL" >"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
    sleep 1

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
    start) start_service ;;
    stop) stop_service ;;
    restart)
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

