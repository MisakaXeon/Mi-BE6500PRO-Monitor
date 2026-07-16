#!/bin/sh

set -eu

SOURCE_BIN=${1:?usage: start_integration_test.sh /path/to/router-monitor}
RUN_SH=${RUN_SH:-sh}
SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEST_DIR=$(mktemp -d)

cleanup() {
    INSTALL_DIR="$TEST_DIR" "$RUN_SH" "$TEST_DIR/start.sh" stop >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
}
trap cleanup 0 1 2 15

cp "$SOURCE_BIN" "$TEST_DIR/router-monitor"
cp "$SOURCE_DIR/start.sh" "$TEST_DIR/start.sh"
chmod 755 "$TEST_DIR/router-monitor" "$TEST_DIR/start.sh"

PORT=$(python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)

cat >"$TEST_DIR/config.env" <<EOF
LISTEN=127.0.0.1:$PORT
INTERVAL=1s
INSTALL_DIR=$TEST_DIR
BIN=/bin/false
START_LOCK=/tmp/router-monitor-invalid-lock
EOF

(INSTALL_DIR="$TEST_DIR" "$RUN_SH" "$TEST_DIR/start.sh" start >"$TEST_DIR/start-1.out" 2>&1) &
first=$!
(INSTALL_DIR="$TEST_DIR" "$RUN_SH" "$TEST_DIR/start.sh" start >"$TEST_DIR/start-2.out" 2>&1) &
second=$!
wait "$first"
wait "$second"

pid=$(cat "$TEST_DIR/router-monitor.pid")
kill -0 "$pid"
curl --fail --silent --max-time 3 "http://127.0.0.1:$PORT/health" | grep -q '"ok"'

INSTALL_DIR="$TEST_DIR" "$RUN_SH" "$TEST_DIR/start.sh" stop >/dev/null
mkdir "$TEST_DIR/.update.lock"
echo "$$ $(awk '{print $22}' /proc/$$/stat)" >"$TEST_DIR/.update.lock/owner"
if INSTALL_DIR="$TEST_DIR" "$RUN_SH" "$TEST_DIR/start.sh" start >/dev/null 2>&1; then
    echo "start.sh ignored an active update lock" >&2
    exit 1
fi
RM_UPDATE_OWNER="$$" INSTALL_DIR="$TEST_DIR" "$RUN_SH" "$TEST_DIR/start.sh" start >/dev/null
pid=$(cat "$TEST_DIR/router-monitor.pid")
kill -0 "$pid"
RM_UPDATE_OWNER="$$" INSTALL_DIR="$TEST_DIR" "$RUN_SH" "$TEST_DIR/start.sh" stop >/dev/null
rm -f "$TEST_DIR/.update.lock/owner"
rmdir "$TEST_DIR/.update.lock"

mkdir "$TEST_DIR/.start.lock"
echo "$$" >"$TEST_DIR/.start.lock/owner"
INSTALL_DIR="$TEST_DIR" "$RUN_SH" "$TEST_DIR/start.sh" start >/dev/null
pid=$(cat "$TEST_DIR/router-monitor.pid")
kill -0 "$pid"

INSTALL_DIR="$TEST_DIR" "$RUN_SH" "$TEST_DIR/start.sh" stop >/dev/null
mkdir "$TEST_DIR/failing-bin"
cat >"$TEST_DIR/failing-bin/start-stop-daemon" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$TEST_DIR/failing-bin/start-stop-daemon"
PATH="$TEST_DIR/failing-bin:$PATH" INSTALL_DIR="$TEST_DIR" \
    "$RUN_SH" "$TEST_DIR/start.sh" start >/dev/null
pid=$(cat "$TEST_DIR/router-monitor.pid")
kill -0 "$pid"
curl --fail --silent --max-time 3 "http://127.0.0.1:$PORT/health" | grep -q '"ok"'

echo "start.sh integration tests passed"
