"""Offline tests: deploys refuse overlays that still carry template placeholders."""

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CHECK = REPO / "scripts/check-placeholders.sh"
KUBECTL = shutil.which("kubectl")
# Values an instance might fill in; none is a placeholder.
FILLED = {
    "INSTANCE_PREFIX": "acme-prod",
    "GCP_PROJECT": "acme-project-123",
    "YOUR_REGION": "europe-west2",
    "example.com": "acme.test",
}


def render(overlay_dir):
    return subprocess.run([KUBECTL, "kustomize", str(overlay_dir)], check=True,
                          capture_output=True, text=True).stdout


def reported(stderr):
    """Map each reported placeholder to the objects the check names for it."""
    found = {}
    for line in stderr.splitlines():
        match = re.match(r"^  (\S+): (.+)$", line)
        if match:
            found[match.group(1)] = match.group(2).split(", ")
    return found


def check(text, **env):
    return subprocess.run([str(CHECK)], input=text, capture_output=True, text=True,
                          env={**os.environ, **env})


@unittest.skipUnless(KUBECTL, "kubectl not installed")
class PlaceholderCheckTest(unittest.TestCase):
    def test_every_template_overlay_is_refused(self):
        for overlay in ("aws", "aws-eks", "gcp"):
            with self.subTest(overlay=overlay):
                result = check(render(REPO / "k8s/overlays" / overlay))
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("api.eve.example.com: ", result.stderr)
        found = reported(check(render(REPO / "k8s/overlays/gcp")).stderr)
        # Each placeholder names every object that carries it, in render order,
        # so check membership rather than position. Nested component files
        # (org-fs) and the registry ingress must be covered too.
        for token, obj in (("INSTANCE_PREFIX", "ServiceAccount/eve-agent-runtime"),
                           ("INSTANCE_PREFIX", "StorageClass/filestore-rwx"),
                           ("GCP_PROJECT", "ServiceAccount/eve-api"),
                           ("YOUR_REGION", "Deployment/eve-api"),
                           ("apps.example.com", "Deployment/eve-worker"),
                           ("registry.eve.example.com", "Ingress/eve-registry")):
            self.assertIn(obj, found.get(token, ()), f"{token} not reported on {obj}: {found}")

    def test_filled_gcp_overlay_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            shutil.copytree(REPO / "k8s", Path(tmp) / "k8s")
            for path in (Path(tmp) / "k8s").rglob("*.yaml"):
                text = path.read_text()
                for placeholder, value in FILLED.items():
                    text = text.replace(placeholder, value)
                path.write_text(text)
            result = check(render(Path(tmp) / "k8s/overlays/gcp"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

    def test_override_warns_and_passes(self):
        result = check(render(REPO / "k8s/overlays/gcp"), EVE_ALLOW_PLACEHOLDERS="1")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Warning: rendered manifests still contain template placeholders", result.stderr)

    def test_output_names_hosts_not_credentials(self):
        doc = ("data:\n  url: postgres://admin:hunter2@db.example.com:5432/eve\n"
               "kind: ConfigMap\nmetadata:\n  name: settings\n")
        result = check(doc)
        self.assertEqual(result.returncode, 1)
        self.assertIn("db.example.com: ConfigMap/settings", result.stderr)
        self.assertNotIn("hunter2", result.stderr)


STUB_KUBECTL = """\
#!/usr/bin/env bash
case "$*" in
  kustomize*) exec "$REAL_KUBECTL" "$@" ;;
esac
echo "$*" >> "$STUB_DIR/calls.log"
case "$*" in
  *"config current-context"*) echo stub-context ;;
  *) exit 0 ;;
esac
"""


@unittest.skipUnless(KUBECTL and shutil.which("bash"), "kubectl or bash not installed")
class DeployRefusesPlaceholdersTest(unittest.TestCase):
    def test_deploy_stops_before_touching_the_cluster(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            for rel in ("bin", "scripts", "config", "k8s"):
                shutil.copytree(REPO / rel, root / rel)
            config = root / "config/platform.yaml"
            config.write_text(re.sub(r"(?m)^overlay:.*$", "overlay: gcp", config.read_text()))
            (root / "config/kubeconfig.yaml").write_text("apiVersion: v1\nkind: Config\n")
            stub = Path(tmp) / "stub"
            stub.mkdir()
            (stub / "kubectl").write_text(STUB_KUBECTL)
            (stub / "kubectl").chmod(0o755)
            env = {**os.environ, "STUB_DIR": str(stub), "REAL_KUBECTL": KUBECTL,
                   "PATH": f"{stub}{os.pathsep}{os.environ['PATH']}"}
            env.pop("KUBECONFIG", None)
            env.pop("EVE_ALLOW_PLACEHOLDERS", None)
            result = subprocess.run([str(root / "bin/eve-infra"), "deploy"], capture_output=True,
                                    text=True, env=env)
            calls = (stub / "calls.log").read_text().splitlines()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to deploy overlay 'gcp'", result.stderr)
        self.assertIn("INSTANCE_PREFIX", result.stderr)
        self.assertEqual([c for c in calls if "current-context" not in c], [])


if __name__ == "__main__":
    unittest.main()
