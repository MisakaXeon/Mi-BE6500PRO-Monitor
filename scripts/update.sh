#!/bin/sh

set -f

INSTALL_DIR=${INSTALL_DIR:-/data/other_vol/router-monitor}
CFG="$INSTALL_DIR/config.env"
START_SH="$INSTALL_DIR/start.sh"
BIN="$INSTALL_DIR/router-monitor"
VERSION_FILE="$INSTALL_DIR/VERSION"
LOCAL_MANIFEST="$INSTALL_DIR/checksums.txt"
UPDATE_LOCK="$INSTALL_DIR/.update.lock"
TXN_DIR="$INSTALL_DIR/.update-transaction"

DEFAULT_UPDATE_URL="https://cdn.jsdelivr.net/gh/MisakaXeon/Mi-BE6500PRO-Monitor@main"
DEFAULT_FALLBACK_URLS="$DEFAULT_UPDATE_URL https://raw.githubusercontent.com/MisakaXeon/Mi-BE6500PRO-Monitor/main"

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
            UPDATE_URL) valid_update_url "$config_value" && CONFIG_UPDATE_URL="$config_value" ;;
        esac
    done <"$CFG"
}

load_config

LISTEN=${CONFIG_LISTEN:-0.0.0.0:9898}
INTERVAL=${CONFIG_INTERVAL:-10s}
PRIMARY_SOURCE=${RM_UPDATE_URL:-${CONFIG_UPDATE_URL:-$DEFAULT_UPDATE_URL}}
FALLBACK_SOURCES=${RM_UPDATE_FALLBACK_URLS-$DEFAULT_FALLBACK_URLS}
HEALTH_ATTEMPTS=${RM_UPDATE_HEALTH_ATTEMPTS:-10}
HEALTH_DELAY=${RM_UPDATE_HEALTH_DELAY:-1}

RELEASE_FILES="
VERSION
bin/router-monitor_linux_arm64
scripts/start.sh
scripts/rmmon
scripts/update.sh
"

trim_source() {
    printf '%s' "$1" | sed 's:/*$::'
}

webget() {
    dst="$1"
    src="$2"
    part="$dst.part"
    rm -f "$part"

    if command -v curl >/dev/null 2>&1; then
        if [ "${RM_UPDATE_INSECURE:-0}" = "1" ]; then
            curl -kfsSL --connect-timeout 8 --max-time 180 --speed-time 15 \
                --speed-limit 1 --retry 1 --retry-max-time 40 -o "$part" "$src"
        else
            curl -fsSL --connect-timeout 8 --max-time 180 --speed-time 15 \
                --speed-limit 1 --retry 1 --retry-max-time 40 -o "$part" "$src"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if [ "${RM_UPDATE_INSECURE:-0}" = "1" ]; then
            wget --no-check-certificate -q -O "$part" "$src"
        else
            wget -q -O "$part" "$src"
        fi
    else
        cecho "${RED}未找到 curl 或 wget，无法联网更新${RESET}"
        return 1
    fi

    [ -s "$part" ] || {
        rm -f "$part"
        return 1
    }
    mv "$part" "$dst"
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

verify_metadata() {
    root="$1"
    [ -s "$root/checksums.txt" ] || return 1
    [ -s "$root/VERSION" ] || return 1
    verify_one "$root" VERSION || return 1
    online=$(sed -n '1p' "$root/VERSION" | tr -d '\r\n')
    validate_version "$online"
}

verify_release() {
    root="$1"
    verify_metadata "$root" || return 1
    for relative_path in $RELEASE_FILES; do
        verify_one "$root" "$relative_path" || {
            cecho "${RED}校验失败：$relative_path${RESET}"
            return 1
        }
    done

    chmod 755 "$root/bin/router-monitor_linux_arm64" \
        "$root/scripts/start.sh" "$root/scripts/rmmon" "$root/scripts/update.sh" || return 1
    expected_version=$(sed -n '1p' "$root/VERSION" | tr -d '\r\n')
    binary_version=$("$root/bin/router-monitor_linux_arm64" -version 2>/dev/null | sed -n '1p' | tr -d '\r\n')
    [ "$binary_version" = "$expected_version" ] || {
        cecho "${RED}二进制版本不匹配：期望 $expected_version，实际 ${binary_version:-未知}${RESET}"
        return 1
    }
}

get_local_version() {
    if [ -s "$VERSION_FILE" ]; then
        local_version=$(sed -n '1p' "$VERSION_FILE" | tr -d '\r\n')
        if validate_version "$local_version"; then
            printf '%s\n' "$local_version"
            return 0
        fi
    fi
    if [ -x "$BIN" ]; then
        local_version=$("$BIN" -version 2>/dev/null | sed -n '1p' | tr -d '\r\n')
        if validate_version "$local_version"; then
            printf '%s\n' "$local_version"
            return 0
        fi
    fi
    printf '%s\n' "unknown"
}

compare_versions() {
    left="$1"
    right="$2"
    awk -v left="$left" -v right="$right" 'BEGIN {
        split(left, a, ".")
        split(right, b, ".")
        for (i = 1; i <= 3; i++) {
            if ((a[i] + 0) > (b[i] + 0)) {print 1; exit}
            if ((a[i] + 0) < (b[i] + 0)) {print -1; exit}
        }
        print 0
    }'
}

lock_owner_active() {
    owner_record=$(cat "$UPDATE_LOCK/owner" 2>/dev/null)
    owner=${owner_record%% *}
    expected_start=${owner_record#* }
    [ -n "$owner" ] || return 1
    [ "$expected_start" != "$owner_record" ] || return 1
    kill -0 "$owner" 2>/dev/null || return 1
    actual_start=$(awk '{print $22}' "/proc/$owner/stat" 2>/dev/null)
    [ -n "$actual_start" ] && [ "$actual_start" = "$expected_start" ]
}

write_lock_owner() {
    owner_start=$(awk '{print $22}' "/proc/$$/stat" 2>/dev/null)
    [ -n "$owner_start" ] || return 1
    printf '%s %s\n' "$$" "$owner_start" >"$UPDATE_LOCK/owner"
}

acquire_update_lock() {
    mkdir -p "$INSTALL_DIR"
    if mkdir "$UPDATE_LOCK" 2>/dev/null; then
        write_lock_owner || {
            rmdir "$UPDATE_LOCK" 2>/dev/null
            return 1
        }
        return 0
    fi

    owner_record=$(cat "$UPDATE_LOCK/owner" 2>/dev/null)
    owner=${owner_record%% *}
    if lock_owner_active; then
        cecho "${YELLOW}已有更新任务正在运行，PID: $owner${RESET}"
        return 1
    fi

    rm -f "$UPDATE_LOCK/owner" 2>/dev/null
    rmdir "$UPDATE_LOCK" 2>/dev/null || return 1
    mkdir "$UPDATE_LOCK" 2>/dev/null || return 1
    write_lock_owner || {
        rmdir "$UPDATE_LOCK" 2>/dev/null
        return 1
    }
}

release_update_lock() {
    owner_record=$(cat "$UPDATE_LOCK/owner" 2>/dev/null)
    owner=${owner_record%% *}
    [ "$owner" = "$$" ] || return 0
    rm -f "$UPDATE_LOCK/owner"
    rmdir "$UPDATE_LOCK" 2>/dev/null
}

write_phase() {
    phase="$1"
    printf '%s\n' "$phase" >"$TXN_DIR/phase.tmp" || return 1
    mv "$TXN_DIR/phase.tmp" "$TXN_DIR/phase"
}

backup_target() {
    key="$1"
    target="$2"
    [ -f "$target" ] || return 0
    if [ "$key" = "router-monitor" ]; then
        ln "$target" "$TXN_DIR/backup/$key" 2>/dev/null || \
            cp -p "$target" "$TXN_DIR/backup/$key" || return 1
    else
        cp -p "$target" "$TXN_DIR/backup/$key" || return 1
    fi
    echo "$key" >>"$TXN_DIR/backup/present"
}

backup_current() {
    mkdir -p "$TXN_DIR/backup" || return 1
    : >"$TXN_DIR/backup/present"
    backup_target VERSION "$VERSION_FILE" || return 1
    backup_target router-monitor "$BIN" || return 1
    backup_target start.sh "$START_SH" || return 1
    backup_target rmmon "$INSTALL_DIR/rmmon" || return 1
    backup_target update.sh "$INSTALL_DIR/update.sh" || return 1
    backup_target checksums.txt "$LOCAL_MANIFEST" || return 1
    backup_target config.env "$CFG" || return 1
}

restore_target() {
    key="$1"
    target="$2"
    mode="$3"
    if grep -qx "$key" "$TXN_DIR/backup/present" 2>/dev/null; then
        tmp="$target.restore.$$"
        cp -p "$TXN_DIR/backup/$key" "$tmp" || return 1
        chmod "$mode" "$tmp" || return 1
        mv "$tmp" "$target" || return 1
    else
        rm -f "$target"
    fi
}

rollback_update() {
    was_running=$(cat "$TXN_DIR/was_running" 2>/dev/null)
    [ -x "$START_SH" ] && RM_UPDATE_OWNER=$$ "$START_SH" stop >/dev/null 2>&1

    restore_target router-monitor "$BIN" 755 || return 1
    restore_target start.sh "$START_SH" 755 || return 1
    restore_target rmmon "$INSTALL_DIR/rmmon" 755 || return 1
    restore_target update.sh "$INSTALL_DIR/update.sh" 755 || return 1
    restore_target VERSION "$VERSION_FILE" 644 || return 1
    restore_target checksums.txt "$LOCAL_MANIFEST" 644 || return 1
    restore_target config.env "$CFG" 600 || return 1

    restart_ok=1
    if [ "$was_running" = "1" ]; then
        RM_UPDATE_OWNER=$$ "$START_SH" start >/dev/null 2>&1 || restart_ok=0
    fi
    rm -rf "$TXN_DIR"
    [ "$restart_ok" -eq 1 ]
}

rollback_with_message() {
    success_message="$1"
    if rollback_update; then
        cecho "${RED}$success_message${RESET}"
    else
        cecho "${RED}自动恢复失败，请保留 $TXN_DIR 并手动检查${RESET}"
    fi
    return 1
}

recover_interrupted_update() {
    [ -d "$TXN_DIR" ] || return 0
    phase=$(cat "$TXN_DIR/phase" 2>/dev/null)
    case "$phase" in
        stopping|replacing|installed|awaiting_commit)
            cecho "${YELLOW}检测到未完成的更新事务，正在恢复旧版本...${RESET}"
            rollback_update || {
                cecho "${RED}自动恢复失败，请保留 $TXN_DIR 并手动检查${RESET}"
                return 1
            }
            cecho "${GREEN}旧版本已恢复${RESET}"
            ;;
        *)
            rm -rf "$TXN_DIR"
            ;;
    esac
}

source_seen() {
    needle="$1"
    case " $TRIED_SOURCES " in
        *" $needle "*) return 0 ;;
    esac
    return 1
}

prepare_metadata() {
    rm -rf "$TXN_DIR"
    mkdir -p "$TXN_DIR/meta" || return 1
    TRIED_SOURCES=""
    for raw_source in $PRIMARY_SOURCE $FALLBACK_SOURCES; do
        source=$(trim_source "$raw_source")
        [ -n "$source" ] || continue
        valid_update_url "$source" || continue
        source_seen "$source" && continue
        TRIED_SOURCES="$TRIED_SOURCES $source"
        cecho "${BLUE}检查更新源：$source${RESET}"
        rm -rf "$TXN_DIR/meta"
        mkdir -p "$TXN_DIR/meta" || return 1
        if webget "$TXN_DIR/meta/checksums.txt" "$source/checksums.txt" && \
           webget "$TXN_DIR/meta/VERSION" "$source/VERSION" && \
           verify_metadata "$TXN_DIR/meta"; then
            SELECTED_SOURCE="$source"
            ONLINE_VERSION=$(sed -n '1p' "$TXN_DIR/meta/VERSION" | tr -d '\r\n')
            return 0
        fi
        cecho "${YELLOW}该更新源不可用或版本清单不一致，尝试下一来源${RESET}"
    done
    return 1
}

prepare_release() {
    rm -rf "$TXN_DIR"
    TRIED_SOURCES=""
    for raw_source in $PRIMARY_SOURCE $FALLBACK_SOURCES; do
        source=$(trim_source "$raw_source")
        [ -n "$source" ] || continue
        valid_update_url "$source" || continue
        source_seen "$source" && continue
        TRIED_SOURCES="$TRIED_SOURCES $source"
        cecho "${BLUE}下载更新包：$source${RESET}"
        rm -rf "$TXN_DIR"
        mkdir -p "$TXN_DIR/stage/bin" "$TXN_DIR/stage/scripts" || return 1
        failed=0
        webget "$TXN_DIR/stage/checksums.txt" "$source/checksums.txt" || failed=1
        if [ "$failed" -eq 0 ]; then
            for relative_path in $RELEASE_FILES; do
                webget "$TXN_DIR/stage/$relative_path" "$source/$relative_path" || {
                    failed=1
                    break
                }
            done
        fi
        if [ "$failed" -eq 0 ] && verify_release "$TXN_DIR/stage"; then
            SELECTED_SOURCE="$source"
            ONLINE_VERSION=$(sed -n '1p' "$TXN_DIR/stage/VERSION" | tr -d '\r\n')
            return 0
        fi
        cecho "${YELLOW}更新包下载或校验失败，尝试下一来源${RESET}"
    done
    return 1
}

replace_from_stage() {
    relative_path="$1"
    target="$2"
    mode="$3"
    chmod "$mode" "$TXN_DIR/stage/$relative_path" || return 1
    mv "$TXN_DIR/stage/$relative_path" "$target"
}

install_staged_release() {
    replace_from_stage bin/router-monitor_linux_arm64 "$BIN" 755 || return 1
    replace_from_stage scripts/start.sh "$START_SH" 755 || return 1
    replace_from_stage scripts/rmmon "$INSTALL_DIR/rmmon" 755 || return 1
    replace_from_stage scripts/update.sh "$INSTALL_DIR/update.sh" 755 || return 1
    replace_from_stage VERSION "$VERSION_FILE" 644 || return 1
    replace_from_stage checksums.txt "$LOCAL_MANIFEST" 644 || return 1
}

http_probe() {
    url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --connect-timeout 2 --max-time 3 "$url" >/dev/null 2>&1
        return $?
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 wget -qO- "$url" >/dev/null 2>&1
        return $?
    fi
    wget -qO- "$url" >/dev/null 2>&1
}

health_check() {
    health_url=${RM_UPDATE_HEALTH_URL:-http://127.0.0.1:${LISTEN##*:}/health}
    attempt=1
    while [ "$attempt" -le "$HEALTH_ATTEMPTS" ]; do
        http_probe "$health_url" && return 0
        sleep "$HEALTH_DELAY"
        attempt=$((attempt + 1))
    done
    return 1
}

handle_signal() {
    trap - 1 2 15
    cecho "${YELLOW}更新被中断，正在清理...${RESET}"
    phase=$(cat "$TXN_DIR/phase" 2>/dev/null)
    case "$phase" in
        stopping|replacing|installed|awaiting_commit) rollback_update >/dev/null 2>&1 ;;
        *) rm -rf "$TXN_DIR" ;;
    esac
    release_update_lock
    exit 1
}

check_update() {
    prepare_metadata || {
        rm -rf "$TXN_DIR"
        cecho "${RED}无法获取有效的在线版本信息${RESET}"
        return 1
    }
    local_version=$(get_local_version)
    cecho "本地版本：${BLUE}$local_version${RESET}"
    cecho "在线版本：${GREEN}$ONLINE_VERSION${RESET}"
    cecho "更新来源：$SELECTED_SOURCE"
    if [ "$local_version" = "unknown" ]; then
        cecho "${YELLOW}本地版本未知，建议重新安装当前在线版本${RESET}"
    else
        comparison=$(compare_versions "$ONLINE_VERSION" "$local_version")
        case "$comparison" in
            1) cecho "${GREEN}发现新版本${RESET}" ;;
            0) cecho "${GREEN}当前已是最新版本${RESET}" ;;
            -1) cecho "${YELLOW}在线版本低于本地版本，可能是 CDN 缓存尚未刷新${RESET}" ;;
        esac
    fi
    rm -rf "$TXN_DIR"
}

apply_staged_release() {
    local_version=$(get_local_version)
    cecho "本地版本：${BLUE}$local_version${RESET}"
    cecho "目标版本：${GREEN}$ONLINE_VERSION${RESET}"
    cecho "更新来源：$SELECTED_SOURCE"

    if [ "$local_version" != "unknown" ]; then
        comparison=$(compare_versions "$ONLINE_VERSION" "$local_version")
        if [ "$comparison" -lt 0 ] && [ "${RM_UPDATE_FORCE:-0}" != "1" ]; then
            rm -rf "$TXN_DIR"
            cecho "${RED}目标版本低于本地版本；如需降级，请设置 RM_UPDATE_FORCE=1${RESET}"
            return 1
        fi
        if [ "$comparison" -eq 0 ] && [ "${RM_UPDATE_FORCE:-0}" != "1" ]; then
            printf "%b" "${YELLOW}当前已是该版本，是否重新安装？y/N > ${RESET}"
            read answer
            case "$answer" in
                y|Y) ;;
                *) rm -rf "$TXN_DIR"; return 0 ;;
            esac
        fi
    fi

    was_running=0
    if [ -x "$START_SH" ] && RM_UPDATE_OWNER=$$ "$START_SH" status >/dev/null 2>&1; then
        was_running=1
    fi
    echo "$was_running" >"$TXN_DIR/was_running"
    backup_current || {
        rm -rf "$TXN_DIR"
        cecho "${RED}无法创建更新备份，当前版本未改动${RESET}"
        return 1
    }
    write_phase prepared || return 1
    write_phase stopping || return 1

    if [ "$was_running" -eq 1 ]; then
        RM_UPDATE_OWNER=$$ "$START_SH" stop >/dev/null 2>&1 || {
            rollback_with_message "无法停止旧服务，已取消更新"
            return 1
        }
        if RM_UPDATE_OWNER=$$ "$START_SH" status >/dev/null 2>&1; then
            rollback_with_message "旧服务仍在运行，已取消更新"
            return 1
        fi
    fi

    write_phase replacing || {
        rollback_update >/dev/null 2>&1
        return 1
    }
    if ! install_staged_release; then
        rollback_with_message "替换文件失败，已恢复旧版本"
        return 1
    fi
    write_phase installed || {
        rollback_update >/dev/null 2>&1
        return 1
    }

    if [ "$was_running" -eq 1 ]; then
        if ! RM_UPDATE_OWNER=$$ "$START_SH" start >/dev/null 2>&1 || ! health_check; then
            rollback_with_message "新版本健康检查失败，已自动恢复旧版本"
            return 1
        fi
    fi

    if [ "${RM_UPDATE_DEFER_COMMIT:-0}" = "1" ]; then
        write_phase awaiting_commit || {
            rollback_update >/dev/null 2>&1
            return 1
        }
        cecho "${GREEN}安装文件已暂存，等待安装器确认配置${RESET}"
        return 0
    fi

    rm -rf "$TXN_DIR"
    cecho "${GREEN}更新完成，当前版本：$ONLINE_VERSION${RESET}"
    if [ "$was_running" -eq 1 ]; then
        cecho "${GREEN}服务已恢复运行${RESET}"
    fi
    return 0
}

online_update() {
    prepare_release || {
        rm -rf "$TXN_DIR"
        cecho "${RED}所有更新源均下载或校验失败，当前版本未改动${RESET}"
        return 1
    }
    apply_staged_release
}

apply_external_stage() {
    requested_stage="$1"
    install_root=$(CDPATH= cd "$INSTALL_DIR" 2>/dev/null && pwd -P) || return 1
    stage_root=$(CDPATH= cd "$requested_stage" 2>/dev/null && pwd -P) || return 1
    case "$stage_root" in
        "$install_root"/.install-*) ;;
        *)
            cecho "${RED}拒绝应用安装目录之外的暂存包${RESET}"
            return 1
            ;;
    esac
    verify_release "$stage_root" || return 1
    rm -rf "$TXN_DIR"
    mkdir -p "$TXN_DIR" || return 1
    mv "$stage_root" "$TXN_DIR/stage" || return 1
    SELECTED_SOURCE="installer staging"
    ONLINE_VERSION=$(sed -n '1p' "$TXN_DIR/stage/VERSION" | tr -d '\r\n')
    RM_UPDATE_FORCE=1
    apply_staged_release
}

commit_transaction() {
    [ -d "$TXN_DIR" ] || {
        cecho "${RED}未找到待提交的安装事务${RESET}"
        return 1
    }
    phase=$(cat "$TXN_DIR/phase" 2>/dev/null)
    [ "$phase" = "awaiting_commit" ] || {
        cecho "${RED}安装事务状态异常：${phase:-未知}${RESET}"
        return 1
    }
    if [ "${RM_UPDATE_COMMIT_HEALTH:-0}" = "1" ] && ! health_check; then
        rollback_with_message "新配置健康检查失败，已恢复安装前版本和配置"
        return 1
    fi
    rm -rf "$TXN_DIR"
    cecho "${GREEN}安装事务已提交${RESET}"
}

rollback_transaction() {
    [ -d "$TXN_DIR" ] || return 0
    phase=$(cat "$TXN_DIR/phase" 2>/dev/null)
    case "$phase" in
        stopping|replacing|installed|awaiting_commit) rollback_update ;;
        *) rm -rf "$TXN_DIR" ;;
    esac
}

case "$1" in
    check|install)
        acquire_update_lock || exit 1
        trap 'release_update_lock' 0
        trap 'handle_signal' 1 2 15
        recover_interrupted_update || exit 1
        if [ "$1" = "check" ]; then
            check_update
        else
            online_update
        fi
        ;;
    apply-stage)
        acquire_update_lock || exit 1
        trap 'release_update_lock' 0
        trap 'handle_signal' 1 2 15
        recover_interrupted_update || exit 1
        apply_external_stage "$2"
        ;;
    commit-transaction|rollback-transaction)
        acquire_update_lock || exit 1
        trap 'release_update_lock' 0
        trap 'handle_signal' 1 2 15
        if [ "$1" = "commit-transaction" ]; then
            commit_transaction
        else
            rollback_transaction
        fi
        ;;
    verify)
        verify_release "$2"
        ;;
    *)
        cecho "${BLUE}用法:${RESET} $0 {check|install}"
        exit 1
        ;;
esac
