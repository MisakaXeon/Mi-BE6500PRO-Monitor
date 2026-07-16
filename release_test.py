from pathlib import Path
import hashlib
import re
import unittest


ROOT = Path(__file__).resolve().parent


class ReleaseLayoutTests(unittest.TestCase):
    def test_release_version_is_semantic(self):
        version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
        self.assertRegex(version, r"^\d+\.\d+\.\d+$")

    def test_release_checksums_match_public_update_assets(self):
        manifest_path = ROOT / "checksums.txt"
        manifest = {}
        for line in manifest_path.read_text(encoding="utf-8").splitlines():
            digest, relative_path = re.split(r"\s+", line.strip(), maxsplit=1)
            manifest[relative_path] = digest

        expected_paths = {
            "VERSION",
            "bin/router-monitor_linux_arm64",
            "scripts/start.sh",
            "scripts/rmmon",
            "scripts/update.sh",
        }
        self.assertEqual(expected_paths, set(manifest))
        for relative_path in expected_paths:
            data = (ROOT / relative_path).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), manifest[relative_path])

    def test_installer_uses_github_raw_assets(self):
        installer = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
        self.assertIn(
            "https://raw.githubusercontent.com/MisakaXeon/Mi-BE6500PRO-Monitor/main",
            installer,
        )
        self.assertIn("$BASE_URL/bin/router-monitor_linux_arm64", installer)
        self.assertIn("$BASE_URL/scripts/start.sh", installer)
        self.assertIn("$BASE_URL/scripts/rmmon", installer)
        self.assertIn("$BASE_URL/scripts/update.sh", installer)
        self.assertIn("$BASE_URL/checksums.txt", installer)
        self.assertNotIn('sh "$STAGE/scripts/update.sh" verify', installer)
        self.assertIn('verify_release "$STAGE"', installer)
        self.assertIn('apply-stage "$STAGE"', installer)

    def test_installer_requires_model_confirmation(self):
        installer = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
        self.assertIn("BE6500PRO", installer)
        self.assertIn("thermal zone", installer)

    def test_public_release_files_exist(self):
        required = [
            "README.md",
            "README_EN.md",
            "LICENSE",
            ".gitignore",
            "bin/router-monitor_linux_arm64",
            "VERSION",
            "checksums.txt",
            "scripts/update.sh",
            "scripts/generate_checksums.sh",
            "scripts/start_integration_test.sh",
        ]
        for relative_path in required:
            self.assertTrue((ROOT / relative_path).is_file(), relative_path)

    def test_service_starts_as_a_detached_daemon(self):
        start_script = (ROOT / "scripts" / "start.sh").read_text(encoding="utf-8")
        self.assertIn("start-stop-daemon -S -b -m", start_script)
        self.assertIn('-log "$LOG_FILE"', start_script)
        self.assertIn('echo "$$" >"$START_LOCK/owner"', start_script)
        self.assertIn("尝试兼容模式", start_script)

    def test_autostart_does_not_delay_firewall_startup(self):
        manager = (ROOT / "scripts" / "rmmon").read_text(encoding="utf-8")
        self.assertNotIn("sleep 30", manager)
        self.assertIn("firewall.RouterMonitor.enabled", manager)
        self.assertIn("enable_auto_start_file", manager)

    def test_manager_exposes_safe_online_update_commands(self):
        manager = (ROOT / "scripts" / "rmmon").read_text(encoding="utf-8")
        self.assertIn("check-update", manager)
        self.assertIn('"$UPDATE_SH" install', manager)
        self.assertIn("refresh-boot", manager)
        self.assertIn('valid_port "$val"', manager)
        self.assertIn("已恢复原配置和服务", manager)

    def test_updater_stages_verifies_and_rolls_back(self):
        updater = (ROOT / "scripts" / "update.sh").read_text(encoding="utf-8")
        self.assertIn("checksums.txt", updater)
        self.assertIn("verify_release", updater)
        self.assertIn("rollback_update", updater)
        self.assertIn("health_check", updater)
        signal_handler = updater.split("handle_signal()", 1)[1].split("check_update()", 1)[0]
        self.assertIn("stopping|replacing|installed|awaiting_commit", signal_handler)
        self.assertNotIn("source \"$STAGE", updater)
        self.assertNotIn('. "$CFG"', updater)

    def test_runtime_scripts_parse_config_without_sourcing_it(self):
        for relative_path in ["scripts/start.sh", "scripts/rmmon", "scripts/update.sh"]:
            script = (ROOT / relative_path).read_text(encoding="utf-8")
            self.assertIn("load_config", script)
            self.assertNotIn('. "$CFG"', script)


if __name__ == "__main__":
    unittest.main()
