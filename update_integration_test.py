from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parent
UPDATER = ROOT / "scripts" / "update.sh"
ASSETS = [
    "VERSION",
    "bin/router-monitor_linux_arm64",
    "scripts/start.sh",
    "scripts/rmmon",
    "scripts/update.sh",
]


def executable(version: str, marker: str) -> str:
    return f"""#!/bin/sh
# {marker}
if [ "$1" = "-version" ]; then
    echo "{version}"
    exit 0
fi
exit 0
"""


def service_script(marker: str) -> str:
    return f"""#!/bin/sh
# {marker}
case "$1" in
    status) [ -f "$INSTALL_DIR/service.running" ] ;;
    start) : >"$INSTALL_DIR/service.running" ;;
    stop) rm -f "$INSTALL_DIR/service.running" ;;
    restart) rm -f "$INSTALL_DIR/service.running"; : >"$INSTALL_DIR/service.running" ;;
    *) exit 0 ;;
esac
"""


def manager_script(marker: str) -> str:
    return f"""#!/bin/sh
# {marker}
exit 0
"""


class ReleaseHandler(SimpleHTTPRequestHandler):
    health_ok = True

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200 if self.health_ok else 503)
            self.end_headers()
            self.wfile.write(b"ok" if self.health_ok else b"failed")
            return
        super().do_GET()

    def log_message(self, *_args):
        return


class UpdateIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.shell = os.environ.get("SH") or shutil.which("sh")
        if not self.shell:
            self.skipTest("POSIX sh is unavailable")
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.install = self.base / "install"
        self.release = self.base / "release"
        self.test_bin = self.base / "test-bin"
        (self.install).mkdir()
        (self.release / "bin").mkdir(parents=True)
        (self.release / "scripts").mkdir(parents=True)
        self.shell_install = self._to_shell_path(self.install)
        self._write_current_release()
        self._write_online_release()
        if os.name == "nt":
            self._write(self.test_bin / "chmod", "#!/bin/sh\nexit 0\n", True)
        handler = partial(ReleaseHandler, directory=str(self.release))
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        ReleaseHandler.health_ok = True
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        if hasattr(self, "httpd"):
            self.httpd.shutdown()
            self.httpd.server_close()
        self.temp.cleanup()

    def _write(self, path: Path, content: str, executable_file: bool = False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8", newline="\n")
        if executable_file:
            path.chmod(0o755)

    def _to_shell_path(self, path: Path) -> str:
        result = subprocess.run(
            [self.shell, "-c", 'cd "$1" && pwd', "sh", str(path)],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=10,
        )
        if result.returncode != 0:
            self.fail(result.stdout + result.stderr)
        return result.stdout.strip()

    def _write_current_release(self):
        self._write(self.install / "VERSION", "1.0.0\n")
        self._write(
            self.install / "router-monitor",
            executable("1.0.0", "old-binary"),
            True,
        )
        self._write(self.install / "start.sh", service_script("old-start"), True)
        self._write(self.install / "rmmon", manager_script("old-manager"), True)
        self._write(self.install / "update.sh", manager_script("old-updater"), True)
        self._write(
            self.install / "config.env",
            "LISTEN=0.0.0.0:9898\nINTERVAL=7s\nINSTALL_DIR="
            + "'"
            + self.shell_install
            + "'"
            + "\nUPDATE_URL=https://old.example.invalid\n",
        )
        (self.install / "service.running").touch()

    def _write_online_release(self):
        self._write(self.release / "VERSION", "2.0.0\n")
        self._write(
            self.release / "bin" / "router-monitor_linux_arm64",
            executable("2.0.0", "new-binary"),
            True,
        )
        self._write(
            self.release / "scripts" / "start.sh",
            service_script("new-start"),
            True,
        )
        self._write(
            self.release / "scripts" / "rmmon",
            manager_script("new-manager"),
            True,
        )
        self._write(
            self.release / "scripts" / "update.sh",
            manager_script("new-updater"),
            True,
        )
        lines = []
        for relative_path in ASSETS:
            digest = hashlib.sha256((self.release / relative_path).read_bytes()).hexdigest()
            lines.append(f"{digest}  {relative_path}")
        self._write(self.release / "checksums.txt", "\n".join(lines) + "\n")

    def _run(self, command: str, *arguments: str, extra_env=None):
        port = self.httpd.server_address[1]
        path_entries = [str(Path(self.shell).resolve().parent)]
        if self.test_bin.exists():
            path_entries.insert(0, str(self.test_bin))
        env = {
            **os.environ,
            "PATH": os.pathsep.join(path_entries + [os.environ.get("PATH", "")]),
            "INSTALL_DIR": self.shell_install,
            "RM_UPDATE_URL": f"http://127.0.0.1:{port}",
            "RM_UPDATE_FALLBACK_URLS": "",
            "RM_UPDATE_HEALTH_URL": f"http://127.0.0.1:{port}/health",
            "RM_UPDATE_HEALTH_ATTEMPTS": "2",
            "RM_UPDATE_HEALTH_DELAY": "0",
            "RM_UPDATE_INSECURE": "1",
        }
        env.update(extra_env or {})
        return subprocess.run(
            [self.shell, str(UPDATER), command, *arguments],
            env=env,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=20,
        )

    def test_check_reports_local_and_online_versions_without_changing_files(self):
        result = self._run("check")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("1.0.0", result.stdout)
        self.assertIn("2.0.0", result.stdout)
        self.assertIn("old-binary", (self.install / "router-monitor").read_text())

    def test_plain_http_source_requires_explicit_insecure_override(self):
        result = self._run("check", extra_env={"RM_UPDATE_INSECURE": "0"})
        self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("old-binary", (self.install / "router-monitor").read_text())

    def test_config_file_cannot_override_internal_update_paths(self):
        protected = self.base / "protected-transaction"
        protected.mkdir()
        marker = protected / "keep"
        marker.touch()
        with (self.install / "config.env").open("a", encoding="utf-8") as config:
            config.write(f"TXN_DIR={self._to_shell_path(protected)}\n")
            config.write("START_SH=/bin/false\n")
            config.write("UPDATE_LOCK=/tmp/invalid-update-lock\n")
        result = self._run("check")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertTrue(marker.exists())

    def test_update_preserves_config_and_starts_new_release(self):
        old_config = (self.install / "config.env").read_text()
        result = self._run("install")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual("2.0.0", (self.install / "VERSION").read_text().strip())
        self.assertIn("new-binary", (self.install / "router-monitor").read_text())
        self.assertEqual(old_config, (self.install / "config.env").read_text())
        self.assertTrue((self.install / "service.running").exists())
        self.assertFalse(any(self.install.glob(".update-*")))

    def test_verified_installer_stage_uses_the_same_transactional_apply(self):
        stage = self.install / ".install-fixture"
        shutil.copytree(self.release, stage)
        old_config = (self.install / "config.env").read_text()
        result = self._run("apply-stage", self._to_shell_path(stage))
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual("2.0.0", (self.install / "VERSION").read_text().strip())
        self.assertEqual(old_config, (self.install / "config.env").read_text())
        self.assertTrue((self.install / "service.running").exists())
        self.assertFalse(stage.exists())

    def test_deferred_installer_transaction_can_be_committed(self):
        stage = self.install / ".install-deferred-commit"
        shutil.copytree(self.release, stage)
        new_config = "LISTEN=0.0.0.0:9988\nINTERVAL=3s\n"

        result = self._run(
            "apply-stage",
            self._to_shell_path(stage),
            extra_env={"RM_UPDATE_DEFER_COMMIT": "1"},
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertTrue((self.install / ".update-transaction").exists())
        self._write(self.install / "config.env", new_config)

        result = self._run(
            "commit-transaction",
            extra_env={"RM_UPDATE_COMMIT_HEALTH": "1"},
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual("2.0.0", (self.install / "VERSION").read_text().strip())
        self.assertEqual(new_config, (self.install / "config.env").read_text())
        self.assertFalse((self.install / ".update-transaction").exists())

    def test_deferred_installer_transaction_restores_release_and_config(self):
        stage = self.install / ".install-deferred-rollback"
        shutil.copytree(self.release, stage)
        old_config = (self.install / "config.env").read_text()

        result = self._run(
            "apply-stage",
            self._to_shell_path(stage),
            extra_env={"RM_UPDATE_DEFER_COMMIT": "1"},
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self._write(self.install / "config.env", "LISTEN=0.0.0.0:65535\nINTERVAL=1s\n")

        result = self._run("rollback-transaction")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual("1.0.0", (self.install / "VERSION").read_text().strip())
        self.assertIn("old-binary", (self.install / "router-monitor").read_text())
        self.assertEqual(old_config, (self.install / "config.env").read_text())
        self.assertTrue((self.install / "service.running").exists())
        self.assertFalse((self.install / ".update-transaction").exists())

    def test_failed_health_check_restores_previous_release(self):
        ReleaseHandler.health_ok = False
        result = self._run("install")
        self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual("1.0.0", (self.install / "VERSION").read_text().strip())
        self.assertIn("old-binary", (self.install / "router-monitor").read_text())
        self.assertIn("old-start", (self.install / "start.sh").read_text())
        self.assertTrue((self.install / "service.running").exists())

    def test_interrupted_replacement_is_recovered_before_checking_online(self):
        transaction = self.install / ".update-transaction"
        backup = transaction / "backup"
        backup.mkdir(parents=True)
        present = []
        targets = {
            "VERSION": self.install / "VERSION",
            "router-monitor": self.install / "router-monitor",
            "start.sh": self.install / "start.sh",
            "rmmon": self.install / "rmmon",
            "update.sh": self.install / "update.sh",
        }
        for key, target in targets.items():
            shutil.copy2(target, backup / key)
            present.append(key)
        self._write(backup / "present", "\n".join(present) + "\n")
        self._write(transaction / "was_running", "1\n")
        self._write(transaction / "phase", "installed\n")

        shutil.copy2(self.release / "VERSION", self.install / "VERSION")
        shutil.copy2(
            self.release / "bin" / "router-monitor_linux_arm64",
            self.install / "router-monitor",
        )
        shutil.copy2(self.release / "scripts" / "start.sh", self.install / "start.sh")

        result = self._run("check")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("未完成的更新事务", result.stdout)
        self.assertEqual("1.0.0", (self.install / "VERSION").read_text().strip())
        self.assertIn("old-binary", (self.install / "router-monitor").read_text())
        self.assertTrue((self.install / "service.running").exists())


if __name__ == "__main__":
    unittest.main()
