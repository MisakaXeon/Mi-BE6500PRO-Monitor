from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parent


class ReleaseLayoutTests(unittest.TestCase):
    def test_installer_uses_github_raw_assets(self):
        installer = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
        self.assertIn(
            "https://raw.githubusercontent.com/MisakaXeon/Mi-BE6500PRO-Monitor/main",
            installer,
        )
        self.assertIn("$BASE_URL/bin/router-monitor_linux_arm64", installer)
        self.assertIn("$BASE_URL/scripts/start.sh", installer)
        self.assertIn("$BASE_URL/scripts/rmmon", installer)

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
        ]
        for relative_path in required:
            self.assertTrue((ROOT / relative_path).is_file(), relative_path)


if __name__ == "__main__":
    unittest.main()

