"""Offline tests for the psql pods behind `eve-infra db status` and `db connect`."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
AWK = REPO / "scripts/pg-env-from-url.awk"
# Synthetic credentials; the password exercises encoding and shell quoting.
PASSWORD = "p@ss:w/rd 'q' $(touch planted) `x`"
ENCODED = "p%40ss%3Aw%2Frd%20'q'%20%24(touch%20planted)%20%60x%60"
URL = f"postgres://eve:{ENCODED}@db.internal:5433/eve?sslmode=require"


def pg_env(url):
    """Run the converter, eval its output in sh, and return the PG* variables."""
    with tempfile.TemporaryDirectory() as tmp:
        script = ('pgenv="$(printf "%s" "$URL" | LC_ALL=C awk -f "$AWK")" || exit 3\n'
                  'eval "$pgenv"\nenv')
        result = subprocess.run(["sh", "-c", script], cwd=tmp, capture_output=True, text=True,
                                env={"PATH": os.environ["PATH"], "URL": url, "AWK": str(AWK)})
        planted = (Path(tmp) / "planted").exists()
    env = dict(line.split("=", 1) for line in result.stdout.splitlines() if line.startswith("PG"))
    return result.returncode, env, result.stderr, planted


class PgEnvFromUrlTest(unittest.TestCase):
    def test_url_parts_become_libpq_variables(self):
        code, env, stderr, planted = pg_env(URL)
        self.assertEqual(code, 0, stderr)
        self.assertEqual(env, {"PGHOST": "db.internal", "PGPORT": "5433", "PGUSER": "eve",
                               "PGPASSWORD": PASSWORD, "PGDATABASE": "eve", "PGSSLMODE": "require"})
        self.assertFalse(planted)

    def test_ipv6_unencoded_at_and_query_overrides(self):
        code, env, stderr, _ = pg_env("postgresql://u:a@b@[::1]:6543/my%20db?host=%2Fcloudsql%2Fi&ssl=true")
        self.assertEqual(code, 0, stderr)
        self.assertEqual(env, {"PGHOST": "/cloudsql/i", "PGPORT": "6543", "PGUSER": "u",
                               "PGPASSWORD": "a@b", "PGDATABASE": "my db"})
        self.assertIn("ignoring unsupported URL parameter ssl", stderr)

    def test_rejections_never_echo_the_url(self):
        for url, message in (("mysql://eve:hunter2@h/db", "is not a postgres:// or postgresql:// URL"),
                             ("postgres://eve:hunter2@h1:1,h2:2/db", "multi-host"),
                             ("postgres://eve:hunter2@[::1/db", "unclosed IPv6 host")):
            with self.subTest(url=url):
                code, env, stderr, _ = pg_env(url)
                self.assertEqual(code, 3)
                self.assertIn(message, stderr)
                self.assertNotIn("hunter2", stderr)
                self.assertEqual(env, {})


STUB_KUBECTL = r'''#!/usr/bin/env python3
"""Stub kubectl: runs a `kubectl run` pod's command locally."""
import json, os, subprocess, sys
args = sys.argv[1:]
with open(os.path.join(os.environ["STUB_DIR"], "calls.log"), "a") as log:
    log.write(" ".join(args) + "\n")
if "current-context" in args:
    print("stub-context")
    sys.exit(0)
if "run" not in args:
    sys.exit(2)
overrides = next(a.split("=", 1)[1] for a in args if a.startswith("--overrides="))
with open(os.path.join(os.environ["STUB_DIR"], "overrides.json"), "w") as out:
    out.write(overrides)
container = json.loads(overrides)["spec"]["containers"][0]
env = {"PATH": os.environ["STUB_POD_PATH"], "PSQL_LOG_DIR": os.environ["PSQL_LOG_DIR"]}
for item in container.get("env", []):
    ref = item.get("valueFrom", {}).get("secretKeyRef")
    if ref == {"name": "eve-app", "key": "DATABASE_URL", "optional": True}:
        env[item["name"]] = os.environ["STUB_DATABASE_URL"]
    elif "value" in item:
        env[item["name"]] = item["value"]
sys.exit(subprocess.run(container["command"], env=env, stdin=subprocess.DEVNULL).returncode)
'''

FAKE_PSQL = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.path.join(os.environ["PSQL_LOG_DIR"], "psql.json"), "w") as out:
    json.dump({"argv": sys.argv[1:], "env": dict(os.environ)}, out)
print("7|0007_add_things.sql")
'''


@unittest.skipUnless(shutil.which("bash") and shutil.which("jq"), "bash or jq not installed")
class DbCommandPodTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.root = self.tmp / "repo"
        for rel in ("bin/eve-infra", "scripts/pg-env-from-url.awk", "config/platform.yaml"):
            (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / rel, self.root / rel)
        (self.root / "config/kubeconfig.yaml").write_text("apiVersion: v1\nkind: Config\n")
        self.stub = self.tmp / "stub"
        self.pod_bin = self.tmp / "pod-bin"
        for directory, name, body in ((self.stub, "kubectl", STUB_KUBECTL), (self.pod_bin, "psql", FAKE_PSQL)):
            directory.mkdir()
            (directory / name).write_text(body)
            (directory / name).chmod(0o755)
        pod_path = os.pathsep.join([str(self.pod_bin), "/usr/bin", "/bin"])
        self.env = {**os.environ, "STUB_DIR": str(self.stub), "STUB_DATABASE_URL": URL,
                    "STUB_POD_PATH": pod_path, "PSQL_LOG_DIR": str(self.tmp),
                    "PATH": f"{self.stub}{os.pathsep}{os.environ['PATH']}"}
        self.env.pop("KUBECONFIG", None)
        for tool in ("sh", "awk", "python3", "env"):  # the pod still needs these
            found = shutil.which(tool)
            if found and os.path.dirname(found) not in pod_path:
                self.env["STUB_POD_PATH"] += os.pathsep + os.path.dirname(found)

    def eve_infra(self, *args):
        return subprocess.run([str(self.root / "bin/eve-infra"), *args], capture_output=True,
                              text=True, env=self.env, stdin=subprocess.DEVNULL)

    def assert_pod_is_narrow(self, tty):
        overrides = json.loads((self.stub / "overrides.json").read_text())
        container = overrides["spec"]["containers"][0]
        self.assertRegex(container["image"], r"^postgres:[0-9.]+-alpine@sha256:[0-9a-f]{64}$")
        self.assertNotIn("envFrom", container)
        self.assertEqual([e["name"] for e in container["env"]], ["DATABASE_URL", "EVE_PG_ENV_AWK"])
        self.assertEqual(container["tty"], tty)
        self.assertNotIn(URL, json.dumps(overrides))
        psql = json.loads((self.tmp / "psql.json").read_text())
        for arg in psql["argv"]:
            self.assertNotIn("p%40ss", arg)
            self.assertNotIn("db.internal", arg)
        self.assertNotIn("DATABASE_URL", psql["env"])
        self.assertEqual(psql["env"]["PGPASSWORD"], PASSWORD)
        self.assertEqual(psql["env"]["PGHOST"], "db.internal")
        return psql["argv"]

    def test_db_status_queries_without_the_url_in_arguments(self):
        result = self.eve_infra("db", "status")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("Applied:", result.stdout)
        self.assertIn("0007_add_things.sql", result.stdout)
        argv = self.assert_pod_is_narrow(tty=False)
        self.assertEqual(argv[:2], ["-tA", "-F|"])

    def test_db_connect_starts_psql_with_no_connection_arguments(self):
        result = self.eve_infra("db", "connect")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.assert_pod_is_narrow(tty=True), [])


if __name__ == "__main__":
    unittest.main()
