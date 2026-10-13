import base64
import configparser
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import main


def fixture_env():
    return {
        "OCI_USER_OCID": "ocid1.user.test",
        "OCI_TENANCY_OCID": "ocid1.tenancy.test",
        "OCI_FINGERPRINT": "test-fingerprint",
        "OCI_PRIVATE_KEY_B64": base64.b64encode(
            b"-----BEGIN PRIVATE KEY-----\ntest\n-----END PRIVATE KEY-----\n"
        ).decode(),
        "SSH_PUBLIC_KEY_B64": base64.b64encode(b"ssh-ed25519 test fixture").decode(),
    }


class WorkerTests(unittest.TestCase):
    def test_telegram_failure_does_not_abort_successful_hunter(self):
        script = "\n".join([
            "set -Eeuo pipefail", "source lib/util.sh", "source lib/notify.sh",
            "python3() { return 1; }", "TELEGRAM_BOT_TOKEN=test",
            "TELEGRAM_CHAT_ID=test", "notify_success shape ad instance ip",
            "echo completed",
        ])
        result = subprocess.run(["bash", "-c", script], cwd=main.ROOT,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("Telegram notification failed", result.stdout)
        self.assertIn("completed", result.stdout)

    def test_generated_credentials_override_local_paths_and_hide_originals(self):
        with tempfile.TemporaryDirectory() as folder:
            env = fixture_env()
            env.update(CONFIG_FILE="/Users/old/config", REGION="ap-singapore-1",
                       OCI_KEY_PASSPHRASE="test-passphrase", A1_OCPUS="2")
            runtime = main.prepare_environment(Path(folder), env)
            config = configparser.ConfigParser(interpolation=None)
            config.read(runtime["CONFIG_FILE"])
            self.assertEqual(config["DEFAULT"]["user"], env["OCI_USER_OCID"])
            self.assertEqual(config["DEFAULT"]["region"], env["REGION"])
            self.assertEqual(config["DEFAULT"]["pass_phrase"], "test-passphrase")
            self.assertEqual(runtime["A1_OCPUS"], "2")
            self.assertEqual(runtime["ORACLE_VPS_ENV_FILE"], "/dev/null")
            self.assertNotIn("OCI_PRIVATE_KEY_B64", runtime)
            self.assertNotIn("OCI_KEY_PASSPHRASE", runtime)
            for name in ("config", "api-key.pem", "ssh.pub"):
                self.assertEqual((Path(folder) / name).stat().st_mode & 0o777, 0o600)

    def test_missing_or_invalid_secrets_fail_before_launch(self):
        with tempfile.TemporaryDirectory() as folder:
            for name in fixture_env():
                env = fixture_env()
                del env[name]
                with self.subTest(name=name), self.assertRaises(ValueError):
                    main.prepare_environment(Path(folder), env)
            env = fixture_env()
            env["OCI_PRIVATE_KEY_B64"] = "not base64!"
            with self.assertRaises(ValueError):
                main.prepare_environment(Path(folder), env)

    def test_success_stays_idle_and_sigterm_cleans_credentials(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            # A fixture hunter uses no network and prints the generated config path.
            (root / "retry-oracle-vps.sh").write_text('echo "$CONFIG_FILE"; exit 0\n')
            (root / "oci").write_text("#!/bin/sh\nexit 0\n")
            (root / "oci").chmod(0o700)
            env = {**os.environ, **fixture_env()}
            env["PATH"] = str(root) + os.pathsep + env["PATH"]
            code = f"import main; from pathlib import Path; main.ROOT=Path({str(root)!r}); raise SystemExit(main.main())"
            proc = subprocess.Popen([sys.executable, "-u", "-c", code], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertEqual(proc.stdout.readline().strip(), "Starting Oracle hunter worker")
                config_file = Path(proc.stdout.readline().strip())
                self.assertIn("completed successfully", proc.stdout.readline())
                self.assertIsNone(proc.poll())
                self.assertTrue(config_file.exists())
                proc.terminate()
                proc.communicate(timeout=10)
                self.assertEqual(proc.returncode, 0)
                self.assertFalse(config_file.parent.exists())
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.communicate()


if __name__ == "__main__":
    unittest.main()
