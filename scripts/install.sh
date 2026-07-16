#!/bin/sh

set -f

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
        if [ "${RM_UPDATE_INSECURE:-0}" = "1" ]; then
            curl -kfsSL --connect-timeout 10 --max-time 180 --retry 2 -o "$dst" "$src"
        else
            curl -fsSL --connect-timeout 10 --max-time 180 --retry 2 -o "$dst" "$src"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if [ "${RM_UPDATE_INSECURE:-0}" = "1" ]; then
            wget --no-check-certificate -q -O "$dst" "$src"
        else
            wget -q -O "$dst" "$src"
        fi
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
        *s) raw_seconds=${val%s} ;;
        *) raw_seconds=$val ;;
    esac
    case "$raw_seconds" in
        ""|*[!0-9]*) return 1 ;;
    esac
    [ "$raw_seconds" -ge 1 ] 2>/dev/null || return 1
    echo "${raw_seconds}s"
}

valid_port() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

valid_update_url() {
    case "$1" in
        https://*) ;;
        http://*) [ "${RM_UPDATE_INSECURE:-0}" = "1" ] || return 1 ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!a-zA-Z0-9:/?\&=%._@+~-]*) return 1 ;;
    esac
    return 0
}

hash_file() {
    file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
        return $?
    fi
    if command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}'
        return $?
    fi
    return 1
}

manifest_hash() {
    manifest="$1"
    relative_path="$2"
    awk -v path="$relative_path" '$2 == path {print $1; found=1} END {if (!found) exit 1}' "$manifest"
}

valid_hash() {
    value="$1"
    [ "${#value}" -eq 64 ] || return 1
    case "$value" in
        *[!0-9a-fA-F]*) return 1 ;;
    esac
    return 0
}

validate_version() {
    value="$1"
    printf '%s\n' "$value" | awk -F. '
        NF != 3 {exit 1}
        $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ {exit 1}
        {ok=1}
        END {exit !ok}
    '
}

verify_one() {
    root="$1"
    relative_path="$2"
    expected=$(manifest_hash "$root/checksums.txt" "$relative_path") || return 1
    valid_hash "$expected" || return 1
    actual=$(hash_file "$root/$relative_path") || return 1
    [ "$actual" = "$expected" ]
}

verify_release() {
    root="$1"
    for relative_path in VERSION bin/router-monitor_linux_arm64 \
        scripts/start.sh scripts/rmmon scripts/update.sh; do
        [ -s "$root/$relative_path" ] && verify_one "$root" "$relative_path" || {
            cecho "${RED}校验失败：$relative_path${RESET}"
            return 1
        }
    done
    expected_version=$(sed -n '1p' "$root/VERSION" | tr -d '\r\n')
    validate_version "$expected_version" || return 1
    chmod 755 "$root/bin/router-monitor_linux_arm64" "$root/scripts/start.sh" \
        "$root/scripts/rmmon" "$root/scripts/update.sh" || return 1
    binary_version=$("$root/bin/router-monitor_linux_arm64" -version 2>/dev/null | sed -n '1p' | tr -d '\r\n')
    [ "$binary_version" = "$expected_version" ]
}

write_config_file() {
    config_tmp="$INSTALL_DIR/config.env.tmp.$$"
    cat >"$config_tmp" <<EOF
LISTEN=0.0.0.0:$PORT
INTERVAL=$INTERVAL
INSTALL_DIR=$INSTALL_DIR
UPDATE_URL=$BASE_URL
EOF
    chmod 600 "$config_tmp" 2>/dev/null || true
    mv "$config_tmp" "$INSTALL_DIR/config.env"
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

case "$INSTALL_DIR" in
    /data/other_vol/*) ;;
    *) cecho "${RED}安装目录必须位于 /data/other_vol/ 下${RESET}"; exit 1 ;;
esac
case "$INSTALL_DIR" in
    *[!a-zA-Z0-9/._-]*) cecho "${RED}安装目录包含不支持的字符${RESET}"; exit 1 ;;
esac
relative_install_dir=${INSTALL_DIR#/data/other_vol/}
case "$relative_install_dir" in
    "") cecho "${RED}不能直接使用 /data/other_vol/ 作为安装目录${RESET}"; exit 1 ;;
esac
old_ifs=$IFS
IFS=/
set -- $relative_install_dir
IFS=$old_ifs
path_probe=/data/other_vol
for path_component do
    case "$path_component" in
        ""|.) continue ;;
        ..) cecho "${RED}安装目录不能包含 .. 路径段${RESET}"; exit 1 ;;
    esac
    path_probe="$path_probe/$path_component"
    [ ! -L "$path_probe" ] || {
        cecho "${RED}安装目录不能经过符号链接：$path_probe${RESET}"
        exit 1
    }
done
valid_update_url "$BASE_URL" || {
    cecho "${RED}下载源必须是 HTTPS；临时 HTTP 测试需设置 RM_UPDATE_INSECURE=1${RESET}"
    exit 1
}

INTERVAL_RAW=$(ask_default "请输入监控间隔，单位：秒" "${RM_INTERVAL:-10}" "$RM_INTERVAL")
PORT=$(ask_default "请输入监听端口" "${RM_PORT:-9898}" "$RM_PORT")
START_NOW=$(ask_default "是否安装后立即启动？y/n" "${RM_START:-y}" "$RM_START")

INTERVAL=$(normalize_seconds "$INTERVAL_RAW") || { cecho "${RED}监控间隔无效，请输入正整数秒数${RESET}"; exit 1; }
valid_port "$PORT" || { cecho "${RED}端口必须在 1-65535 之间${RESET}"; exit 1; }
case "$START_NOW" in
    y|Y|n|N) ;;
    *) cecho "${RED}是否立即启动只能输入 y 或 n${RESET}"; exit 1 ;;
esac

mkdir -p "$INSTALL_DIR" || exit 1
INSTALL_DIR=$(CDPATH= cd "$INSTALL_DIR" 2>/dev/null && pwd -P) || exit 1
case "$INSTALL_DIR" in
    /data/other_vol/*) ;;
    *) cecho "${RED}解析后的安装目录越出 /data/other_vol/${RESET}"; exit 1 ;;
esac
STAGE="$INSTALL_DIR/.install-$$"
TRANSACTION_OPEN=0

cleanup_install() {
    if [ "$TRANSACTION_OPEN" -eq 1 ] && [ -d "$INSTALL_DIR/.update-transaction" ] && \
       [ -x "$INSTALL_DIR/update.sh" ]; then
        INSTALL_DIR="$INSTALL_DIR" sh "$INSTALL_DIR/update.sh" rollback-transaction >/dev/null 2>&1 || \
            cecho "${RED}自动回滚失败，请检查 $INSTALL_DIR/.update-transaction${RESET}"
    fi
    rm -rf "$STAGE"
}

rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/scripts" || exit 1
trap 'cleanup_install' 0
trap 'exit 1' 1 2 15

line
cecho "${BLUE}开始下载文件，来源：${RESET}${GREEN}$BASE_URL${RESET}"
webget "$STAGE/checksums.txt" "$BASE_URL/checksums.txt" || exit 1
webget "$STAGE/VERSION" "$BASE_URL/VERSION" || exit 1
webget "$STAGE/bin/router-monitor_linux_arm64" "$BASE_URL/bin/router-monitor_linux_arm64" || exit 1
webget "$STAGE/scripts/start.sh" "$BASE_URL/scripts/start.sh" || exit 1
webget "$STAGE/scripts/rmmon" "$BASE_URL/scripts/rmmon" || exit 1
webget "$STAGE/scripts/update.sh" "$BASE_URL/scripts/update.sh" || exit 1

chmod 755 "$STAGE/bin/router-monitor_linux_arm64" "$STAGE/scripts/start.sh" \
    "$STAGE/scripts/rmmon" "$STAGE/scripts/update.sh"
verify_release "$STAGE" || {
    cecho "${RED}安装包校验失败，未修改现有程序${RESET}"
    exit 1
}

RM_UPDATE_FORCE=1 RM_UPDATE_DEFER_COMMIT=1 INSTALL_DIR="$INSTALL_DIR" \
    sh "$STAGE/scripts/update.sh" apply-stage "$STAGE" || {
    cecho "${RED}安装事务失败，旧版本已保留或恢复${RESET}"
    exit 1
}
TRANSACTION_OPEN=1

"$INSTALL_DIR/start.sh" stop >/dev/null 2>&1 || {
    cecho "${RED}无法停止监控进程，正在恢复安装前状态${RESET}"
    exit 1
}
write_config_file || {
    cecho "${RED}写入配置失败，正在恢复安装前状态${RESET}"
    exit 1
}

if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
    if ! "$INSTALL_DIR/start.sh" start; then
        cecho "${RED}新配置无法启动，正在恢复安装前版本、配置和服务${RESET}"
        exit 1
    fi
    COMMIT_HEALTH=1
else
    COMMIT_HEALTH=0
fi

RM_UPDATE_COMMIT_HEALTH="$COMMIT_HEALTH" INSTALL_DIR="$INSTALL_DIR" \
    sh "$INSTALL_DIR/update.sh" commit-transaction || {
        cecho "${RED}安装确认失败，已恢复或正在恢复安装前状态${RESET}"
        exit 1
    }
TRANSACTION_OPEN=0

if [ "${RM_SKIP_SYSTEM_INTEGRATION:-0}" != "1" ]; then
    write_profile
    write_command || cecho "${YELLOW}未能在 PATH 中创建实体 rmmon 命令，请执行：. /etc/profile${RESET}"
fi

line
trap - 0 1 2 15
rm -rf "$STAGE"
cecho "${GREEN}安装完成${RESET}"
cecho "管理菜单：${WHITE_BG} rmmon ${RESET}"
cecho "备用命令：${BLUE}sh $INSTALL_DIR/rmmon${RESET}"
cecho "数据接口：${GREEN}http://路由器IP:$PORT/metrics.json${RESET}"
line
