#!/bin/sh

BASE_URL=${url:-https://raw.githubusercontent.com/MisakaXeon/Mi-BE6500PRO-Monitor/main}
INSTALL_DIR=${INSTALL_DIR:-/data/other_vol/router-monitor}

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
WHITE_BG='\033[30;47m'
RESET='\033[0m'

cecho() {
    printf '%b\n' "$*"
}

webget() {
    dst="$1"
    src="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -kfL --retry 2 -o "$dst" "$src"
    elif command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -O "$dst" "$src"
    else
        echo "未找到 curl 或 wget"
        return 1
    fi
}

line() {
    echo "-----------------------------------------------"
}

ask_default() {
    prompt="$1"
    default="$2"
    env_value="$3"
    if [ -n "$env_value" ]; then
        echo "$env_value"
        return
    fi
    printf "%b [%b] > " "${YELLOW}${prompt}${RESET}" "${GREEN}${default}${RESET}" >&2
    read val
    [ -z "$val" ] && val="$default"
    echo "$val"
}

normalize_seconds() {
    val="$1"
    case "$val" in
        [1-9])
            echo "${val}s"
            return 0
            ;;
        [1-9][0-9]*)
            echo "${val}s"
            return 0
            ;;
        [1-9][0-9]*s)
            echo "$val"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

write_profile() {
    if [ -w /etc/profile ]; then
        sed -i '/RouterMonitor alias/d' /etc/profile 2>/dev/null
        sed -i '/alias rmmon=.*router-monitor\/rmmon/d' /etc/profile 2>/dev/null
        sed -i '/export ROUTER_MONITOR_DIR=/d' /etc/profile 2>/dev/null
        echo "alias rmmon=\"sh $INSTALL_DIR/rmmon\" #RouterMonitor alias" >>/etc/profile
        echo "export ROUTER_MONITOR_DIR=\"$INSTALL_DIR\" #RouterMonitor alias" >>/etc/profile
        cecho "${GREEN}已写入 /etc/profile${RESET}"
    else
        cecho "${YELLOW}/etc/profile 不可写，跳过 profile alias${RESET}"
    fi
}

write_command() {
    for dir in /usr/bin /bin /sbin /usr/sbin; do
        [ -d "$dir" ] || continue
        tmp="$dir/.rmmon.$$"
        if (cat >"$tmp" <<EOF
#!/bin/sh
exec sh "$INSTALL_DIR/rmmon" "\$@"
EOF
) 2>/dev/null; then
            if mv "$tmp" "$dir/rmmon" 2>/dev/null && chmod 755 "$dir/rmmon" 2>/dev/null; then
                cecho "${GREEN}已创建命令：${WHITE_BG} $dir/rmmon ${RESET}"
                return 0
            fi
            rm -f "$tmp" 2>/dev/null
        fi
    done
    return 1
}

cecho "${BLUE}***********************************************${RESET}"
cecho "${BLUE}**${RESET}          ${GREEN}Router Monitor Installer${RESET}          ${BLUE}**${RESET}"
cecho "${BLUE}***********************************************${RESET}"
cecho "${RED}仅支持并仅在小米 BE6500PRO 上验证。${RESET}"
cecho "${YELLOW}其他型号的 thermal zone 数量、传感器名称和自启机制可能不同。${RESET}"
cecho "${YELLOW}非同型号请自行修改源码；不清楚风险时请勿安装。${RESET}"

MODEL_CONFIRM=$(ask_default "确认当前设备为小米 BE6500PRO，请输入 BE6500PRO" "" "$RM_MODEL_CONFIRM")
if [ "$MODEL_CONFIRM" != "BE6500PRO" ]; then
    cecho "${RED}型号确认失败，已取消安装${RESET}"
    exit 1
fi

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    cecho "${RED}请使用 root 用户安装${RESET}"
    exit 1
fi

arch=$(uname -m)
case "$arch" in
    aarch64|arm64) ;;
    *)
        cecho "${RED}当前架构 $arch 暂未提供安装包${RESET}"
        exit 1
        ;;
esac

if [ ! -d /data/other_vol ] || [ ! -w /data/other_vol ]; then
    cecho "${RED}/data/other_vol 不存在或不可写，已取消安装${RESET}"
    exit 1
fi

INTERVAL_RAW=$(ask_default "请输入监控间隔，单位：秒" "${RM_INTERVAL:-10}" "$RM_INTERVAL")
PORT=$(ask_default "请输入监听端口" "${RM_PORT:-9898}" "$RM_PORT")
START_NOW=$(ask_default "是否安装后立即启动？y/n" "${RM_START:-y}" "$RM_START")

INTERVAL=$(normalize_seconds "$INTERVAL_RAW") || { cecho "${RED}监控间隔无效，请输入正整数秒数${RESET}"; exit 1; }
case "$PORT" in
    [1-9][0-9]*)
        [ "$PORT" -le 65535 ] 2>/dev/null || { cecho "${RED}端口必须在 1-65535 之间${RESET}"; exit 1; }
        ;;
    *) cecho "${RED}端口无效${RESET}"; exit 1 ;;
esac

mkdir -p "$INSTALL_DIR"

if [ -x "$INSTALL_DIR/start.sh" ]; then
    "$INSTALL_DIR/start.sh" stop 2>/dev/null
fi

line
cecho "${BLUE}开始下载文件，来源：${RESET}${GREEN}$BASE_URL${RESET}"
webget "$INSTALL_DIR/router-monitor" "$BASE_URL/bin/router-monitor_linux_arm64" || exit 1
webget "$INSTALL_DIR/start.sh" "$BASE_URL/scripts/start.sh" || exit 1
webget "$INSTALL_DIR/rmmon" "$BASE_URL/scripts/rmmon" || exit 1

chmod 755 "$INSTALL_DIR/router-monitor" "$INSTALL_DIR/start.sh" "$INSTALL_DIR/rmmon"

cat >"$INSTALL_DIR/config.env" <<EOF
LISTEN=0.0.0.0:$PORT
INTERVAL=$INTERVAL
INSTALL_DIR=$INSTALL_DIR
EOF

write_profile
write_command || cecho "${YELLOW}未能在 PATH 中创建实体 rmmon 命令，请执行：. /etc/profile${RESET}"

if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
    "$INSTALL_DIR/start.sh" start
fi

line
cecho "${GREEN}安装完成${RESET}"
cecho "管理菜单：${WHITE_BG} rmmon ${RESET}"
cecho "备用命令：${BLUE}sh $INSTALL_DIR/rmmon${RESET}"
cecho "数据接口：${GREEN}http://路由器IP:$PORT/metrics.json${RESET}"
line

