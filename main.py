"""FadeHost worker: materialize OCI secrets and supervise the retry script."""

import base64
import configparser
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parent


def required(env, name):
    value = env.get(name, "").strip()
    if not value:
        raise ValueError(f"Missing environment variable: {name}")
    return value


def decoded_secret(env, name):
    try:
        return base64.b64decode(required(env, name), validate=True).decode("utf-8")
    except (ValueError, UnicodeError) as exc:
        raise ValueError(f"{name} must be valid single-line base64 UTF-8") from exc


def prepare_environment(directory, env):
    env = env.copy()
    private_key = decoded_secret(env, "OCI_PRIVATE_KEY_B64")
    public_key = decoded_secret(env, "SSH_PUBLIC_KEY_B64").strip()
    if "PRIVATE KEY-----" not in private_key:
        raise ValueError("OCI_PRIVATE_KEY_B64 must contain a PEM API private key")
    if not public_key.startswith(("ssh-", "ecdsa-", "sk-")) or "\n" in public_key:
        raise ValueError("SSH_PUBLIC_KEY_B64 must contain one OpenSSH public key")

    region = env.get("REGION", "ap-singapore-1")
    config = configparser.ConfigParser(interpolation=None)
    config["DEFAULT"] = {
        "user": required(env, "OCI_USER_OCID"),
        "tenancy": required(env, "OCI_TENANCY_OCID"),
        "fingerprint": required(env, "OCI_FINGERPRINT"),
        "region": region,
        "key_file": str(directory / "api-key.pem"),
    }
    if env.get("OCI_KEY_PASSPHRASE"):
        config["DEFAULT"]["pass_phrase"] = env["OCI_KEY_PASSPHRASE"]

    for name, contents in (("api-key.pem", private_key), ("ssh.pub", public_key + "\n")):
        path = directory / name
        path.write_text(contents)
        path.chmod(0o600)
    config_file = directory / "config"
    with config_file.open("w") as stream:
        config.write(stream)
    config_file.chmod(0o600)

    # Force the generated credentials rather than local macOS paths or overrides.
    env.update({
        "CONFIG_FILE": str(config_file),
        "OCI_CLI_CONFIG_FILE": str(config_file),
        "PROFILE": "DEFAULT",
        "OCI_CLI_PROFILE": "DEFAULT",
        "OCI_CLI_AUTH": "api_key",
        "SSH_PUBKEY_FILE": str(directory / "ssh.pub"),
        "ORACLE_VPS_ENV_FILE": "/dev/null",
        "ORACLE_VPS_MANAGED": "1",
        "REGION": region,
        "PATH": str(Path(sys.executable).parent) + os.pathsep + env.get("PATH", ""),
        "PYTHONUNBUFFERED": "1",
    })
    # The CLI needs only the generated files, not the base64 originals.
    for name in ("OCI_PRIVATE_KEY_B64", "SSH_PUBLIC_KEY_B64", "OCI_KEY_PASSPHRASE"):
        env.pop(name, None)
    return env


def main():
    stopped = threading.Event()
    child = None

    def stop(signum, _frame):
        stopped.set()
        if child is not None:
            try:
                os.killpg(child.pid, signum)
            except ProcessLookupError:
                pass

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="oracle-hunter-") as runtime:
        try:
            env = prepare_environment(Path(runtime), os.environ)
        except ValueError as exc:
            print(f"Configuration error: {exc}", file=sys.stderr, flush=True)
            return 1
        for command in ("bash", "python3", "oci"):
            if not shutil.which(command, path=env["PATH"]):
                print(f"Missing command: {command}", file=sys.stderr, flush=True)
                return 1
        if stopped.is_set():
            return 0
        print("Starting Oracle hunter worker", flush=True)
        child = subprocess.Popen(
            ["bash", str(ROOT / "retry-oracle-vps.sh")],
            cwd=ROOT, env=env, start_new_session=True,
        )
        if stopped.is_set():
            stop(signal.SIGTERM, None)
        while child.poll() is None:
            if stopped.wait(1):
                try:
                    child.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    stop(signal.SIGKILL, None)
                    child.wait()
                return 0
        result = child.returncode
        child = None
        if result:
            return result if result > 0 else 1
        print("Hunter completed successfully; waiting idle. Stop the app in FadeHost.", flush=True)
        # Keep a successful worker alive so a hosting restart policy does not
        # repeatedly launch more capacity checks after the target exists.
        stopped.wait()
    return 0


if __name__ == "__main__":
    sys.exit(main())
