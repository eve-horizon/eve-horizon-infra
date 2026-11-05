"""Offline tests for rendering and syncing Eve's Kubernetes secrets."""

import base64
import importlib.util
import json
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("render_k8s_secrets", REPO / "scripts/render-k8s-secrets.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)

# Synthetic, structurally PEM-shaped test data; not a usable key.
PEM = "-----BEGIN PRIVATE KEY-----\nAAAAtestonlyAAAA\nBBBBtestonlyBBBB\n-----END PRIVATE KEY-----"


def decoded(manifest, name):
    item = next(i for i in manifest["items"] if i["metadata"]["name"] == name)
    return {k: base64.b64decode(v).decode() for k, v in item["data"].items()}


class ParseEnvTest(unittest.TestCase):
    def parse(self, text, environ=None):
        return renderer.parse_env(textwrap.dedent(text), environ or {})

    def test_unquoted_values_match_kubectl_from_env_file(self):
        values = self.parse("""\
            # comment
              INDENTED=kept
            URL=postgres://u:p@h:5432/db?sslmode=require#frag
            EQUALS=a=b=c
            EMPTY=
            INNER=in"side"
            FROM_ENV
        """ + "SPACES=a b  \n", {"FROM_ENV": "from-process"})
        self.assertEqual(values, {
            "INDENTED": "kept",
            "URL": "postgres://u:p@h:5432/db?sslmode=require#frag",
            "SPACES": "a b  ",
            "EQUALS": "a=b=c",
            "EMPTY": "",
            "INNER": 'in"side"',
            "FROM_ENV": "from-process",
        })

    def test_double_quoted_multiline_pem_is_kept_intact(self):
        values = self.parse(f'EVE_AUTH_PRIVATE_KEY="{PEM}"\nNEXT=1\n')
        self.assertEqual(values["EVE_AUTH_PRIVATE_KEY"], PEM)
        self.assertEqual(values["NEXT"], "1")

    def test_escaped_newlines_expand_inside_double_quotes(self):
        escaped = PEM.replace("\n", "\\n")
        values = self.parse(f'EVE_REGISTRY_SIGNING_KEY="{escaped}"\n')
        self.assertEqual(values["EVE_REGISTRY_SIGNING_KEY"], PEM)

    def test_quote_escapes_and_single_quotes(self):
        values = self.parse("""\
            A="say \\"hi\\" \\\\ \\d"
        """ + "B='literal \\n \"x\"'  \n")
        self.assertEqual(values["A"], 'say "hi" \\ \\d')
        self.assertEqual(values["B"], 'literal \\n "x"')

    def test_crlf_files(self):
        text = f'A=1\r\nKEY="{PEM}"\r\nB=2\r\n'.replace("\n", "\r\n").replace("\r\r\n", "\r\n")
        values = renderer.parse_env(text, {})
        self.assertEqual(values, {"A": "1", "KEY": PEM, "B": "2"})

    def assertRejected(self, text, fragment):
        with self.assertRaises(renderer.EnvFileError) as ctx:
            self.parse(text)
        message = str(ctx.exception)
        self.assertIn(fragment, message)
        for secret_text in ("AAAAtestonly", "BBBBtestonly", "hunter2"):
            self.assertNotIn(secret_text, message)

    def test_unquoted_multiline_pem_is_rejected_without_echoing_it(self):
        self.assertRejected(f"OK=1\nEVE_AUTH_PRIVATE_KEY={PEM}\n", "line 2: EVE_AUTH_PRIVATE_KEY starts a PEM key")

    def test_single_line_pem_is_rejected(self):
        escaped = PEM.replace("\n", "\\n")
        self.assertRejected(f"EVE_AUTH_PRIVATE_KEY={escaped}\n", "line 1: EVE_AUTH_PRIVATE_KEY starts a PEM key")
        flattened = PEM.replace("\n", " ")
        self.assertRejected(f'EVE_AUTH_PRIVATE_KEY="{flattened}"\n', "EVE_AUTH_PRIVATE_KEY holds a PEM key without line breaks")

    def test_stray_lines_are_rejected_without_echoing_them(self):
        self.assertRejected("A=1\nnot a key line hunter2\n", "line 2: expected KEY=VALUE")

    def test_value_opening_with_a_quote_must_close_it(self):
        self.assertRejected('INNER="quoted"hunter2\n', "unexpected text after the closing quote of INNER")

    def test_unterminated_quote(self):
        self.assertRejected('A=1\nPASSWORD="hunter2\nB=2\n', "line 2: PASSWORD has no closing \"")

    def test_text_after_closing_quote(self):
        self.assertRejected('PASSWORD="hunter2" trailing\n', "line 1: unexpected text after the closing quote of PASSWORD")

    def test_duplicate_key(self):
        self.assertRejected("A=hunter2\nA=hunter2\n", "line 2: duplicate key A")


class RenderTest(unittest.TestCase):
    def test_api_only_keys_leave_eve_app(self):
        values = {
            "DATABASE_URL": "postgres://db", "EVE_INTERNAL_API_KEY": "internal",
            "EVE_SECRETS_MASTER_KEY": "master", "EVE_AUTH_PRIVATE_KEY": PEM,
            "EVE_REGISTRY_SIGNING_KEY": PEM, "EVE_BOOTSTRAP_TOKEN": "boot",
        }
        manifest = renderer.render(values, "eve")
        self.assertEqual([i["metadata"]["name"] for i in manifest["items"]], ["eve-app", "eve-api-keys"])
        self.assertEqual(decoded(manifest, "eve-app"),
                         {"DATABASE_URL": "postgres://db", "EVE_INTERNAL_API_KEY": "internal"})
        self.assertEqual(decoded(manifest, "eve-api-keys"), {
            "EVE_SECRETS_MASTER_KEY": "master", "EVE_AUTH_PRIVATE_KEY": PEM,
            "EVE_REGISTRY_SIGNING_KEY": PEM, "EVE_BOOTSTRAP_TOKEN": "boot",
        })

    def test_both_secrets_render_even_when_one_is_empty(self):
        manifest = renderer.render({"EVE_INTERNAL_API_KEY": "internal"}, "eve")
        self.assertEqual(decoded(manifest, "eve-api-keys"), {})
        self.assertEqual(manifest["items"][1]["metadata"]["namespace"], "eve")


class ExampleFileTest(unittest.TestCase):
    def setUp(self):
        self.text = (REPO / "config/secrets.env.example").read_text()

    def test_example_parses_and_documents_the_auth_key(self):
        values = renderer.parse_env(self.text, {})
        self.assertIn("EVE_AUTH_PRIVATE_KEY", values)
        self.assertNotIn("multi-line value supported", self.text)

    def test_api_only_markers_match_the_renderer(self):
        marked, pending = set(), False
        for line in self.text.splitlines():
            if line.startswith("#"):
                pending = pending or "[API ONLY]" in line
                continue
            match = re.match(r"([A-Z0-9_]+)=", line)
            if match and pending:
                marked.add(match.group(1))
            pending = False if match else pending
        present = set(renderer.parse_env(self.text, {}))
        self.assertEqual(marked, renderer.API_ONLY_KEYS & present)

    @unittest.skipUnless(shutil.which("openssl"), "openssl not installed")
    def test_documented_generation_command_produces_a_parseable_pem(self):
        for key in ("EVE_AUTH_PRIVATE_KEY", "EVE_REGISTRY_SIGNING_KEY"):
            command = re.search(rf"^#   (printf '{key}=.*) >> config/secrets\.env$", self.text, re.MULTILINE)
            self.assertIsNotNone(command, key)
            with tempfile.TemporaryDirectory() as tmp:
                env_file = Path(tmp) / "secrets.env"
                subprocess.run(["bash", "-c", f"{command.group(1)} >> {env_file}"],
                               check=True, capture_output=True)
                value = renderer.parse_env(env_file.read_text(), {})[key]
            self.assertTrue(value.startswith("-----BEGIN PRIVATE KEY-----\n"), key)
            self.assertTrue(value.endswith("\n-----END PRIVATE KEY-----"), key)
            self.assertGreater(value.count("\n"), 10, key)


STUB_KUBECTL = """\
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls.log"
case "$*" in
  *"config current-context"*) echo stub-context ;;
  *"get deployment eve-api"*)
    if [[ -n "${STUB_API_REFS+x}" ]]; then printf '%s' "$STUB_API_REFS"; else
      echo 'Error from server (NotFound): deployments.apps "eve-api" not found' >&2; exit 1; fi ;;
  *"apply -f -"*) cat > "$STUB_DIR/applied.json" ;;
  *) echo "unexpected kubectl call: $*" >&2; exit 2 ;;
esac
"""


@unittest.skipUnless(shutil.which("bash"), "bash not installed")
class SecretsSyncTest(unittest.TestCase):
    """Runs `eve-infra secrets sync` against a stub kubectl."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / "repo"
        for rel in ("bin/eve-infra", "scripts/render-k8s-secrets.py", "config/platform.yaml"):
            (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / rel, self.root / rel)
        (self.root / "config/kubeconfig.yaml").write_text("apiVersion: v1\nkind: Config\n")
        self.stub = Path(tmp.name) / "stub"
        self.stub.mkdir()
        (self.stub / "kubectl").write_text(STUB_KUBECTL)
        (self.stub / "kubectl").chmod(0o755)
        self.env = {**os.environ, "STUB_DIR": str(self.stub), "PATH": f"{self.stub}{os.pathsep}{os.environ['PATH']}"}
        self.env.pop("KUBECONFIG", None)
        self.env.pop("STUB_API_REFS", None)

    def sync(self, secrets_text, api_refs=None):
        (self.root / "config/secrets.env").write_text(secrets_text)
        env = dict(self.env)
        if api_refs is not None:
            env["STUB_API_REFS"] = api_refs
        return subprocess.run([str(self.root / "bin/eve-infra"), "secrets", "sync"],
                              capture_output=True, text=True, env=env)

    def applied(self):
        path = self.stub / "applied.json"
        return json.loads(path.read_text()) if path.exists() else None

    def test_first_setup_applies_split_secrets_with_intact_pem(self):
        result = self.sync(f'EVE_INTERNAL_API_KEY=internal\nEVE_AUTH_PRIVATE_KEY="{PEM}"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = self.applied()
        self.assertEqual(decoded(manifest, "eve-app"), {"EVE_INTERNAL_API_KEY": "internal"})
        self.assertEqual(decoded(manifest, "eve-api-keys"), {"EVE_AUTH_PRIVATE_KEY": PEM})
        self.assertNotIn("AAAAtestonly", result.stdout + result.stderr)

    def test_split_waits_for_an_api_that_mounts_eve_api_keys(self):
        result = self.sync("EVE_INTERNAL_API_KEY=internal\n", api_refs="eve-app")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Run 'eve-infra deploy' first", result.stderr)
        self.assertIsNone(self.applied())
        result = self.sync("EVE_INTERNAL_API_KEY=internal\n", api_refs="eve-app eve-api-keys")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(self.applied())

    def test_malformed_file_never_reaches_kubectl(self):
        result = self.sync(f"EVE_AUTH_PRIVATE_KEY={PEM}\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no secret was changed", result.stderr)
        self.assertNotIn("AAAAtestonly", result.stdout + result.stderr)
        self.assertIsNone(self.applied())


if __name__ == "__main__":
    unittest.main()
