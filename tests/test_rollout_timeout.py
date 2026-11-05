"""Offline tests: deploy waits long enough for a slow worker and reports failure."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
STUB_KUBECTL = """\
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls.log"
case "$*" in
  *"config current-context"*) echo stub-context ;;
  *"get job"*) exit 1 ;;
  *"rollout status"*) [[ -n "${STUB_FAIL_ROLLOUT:-}" && "$*" == *"$STUB_FAIL_ROLLOUT "* ]] && exit 1 ;;
esac
exit 0
"""


@unittest.skipUnless(shutil.which("bash"), "bash not installed")
class RolloutTimeoutTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name) / "repo"
        # The whole CLI surface deploy may call (bin, scripts, config, k8s).
        for rel in ("bin", "scripts", "config", "k8s"):
            shutil.copytree(REPO / rel, root / rel)
        (root / "config/kubeconfig.yaml").write_text("apiVersion: v1\nkind: Config\n")
        self.eve_infra = root / "bin/eve-infra"
        self.stub = Path(tmp.name) / "stub"
        self.stub.mkdir()
        (self.stub / "kubectl").write_text(STUB_KUBECTL)
        (self.stub / "kubectl").chmod(0o755)
        self.env = {**os.environ, "STUB_DIR": str(self.stub),
                    "PATH": f"{self.stub}{os.pathsep}{os.environ['PATH']}"}
        for name in ("KUBECONFIG", "EVE_ROLLOUT_TIMEOUT", "STUB_FAIL_ROLLOUT"):
            self.env.pop(name, None)

    def deploy(self, **env):
        result = subprocess.run([str(self.eve_infra), "deploy"], capture_output=True, text=True,
                                env={**self.env, **env})
        log = self.stub / "calls.log"
        calls = log.read_text().splitlines() if log.exists() else []
        return result, [c for c in calls if "rollout status" in c], calls

    def test_default_timeout_covers_a_slow_worker_boot(self):
        result, rollouts, _ = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(rollouts), 6)
        self.assertTrue(all(c.endswith("--timeout=600s") for c in rollouts), rollouts)
        self.assertIn("Deploy complete.", result.stdout)

    def test_timeout_is_configurable(self):
        result, rollouts, _ = self.deploy(EVE_ROLLOUT_TIMEOUT="15m")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(c.endswith("--timeout=15m") for c in rollouts), rollouts)

    def test_invalid_timeout_is_refused_before_any_cluster_call(self):
        result, _, calls = self.deploy(EVE_ROLLOUT_TIMEOUT="600s; echo hi")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("EVE_ROLLOUT_TIMEOUT must be a duration", result.stderr)
        self.assertEqual(calls, [])

    def test_unfinished_rollout_fails_the_deploy_after_checking_all(self):
        result, rollouts, _ = self.deploy(STUB_FAIL_ROLLOUT="deployment/eve-worker")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(rollouts), 6)
        self.assertIn("Rollout did not finish for: deployment/eve-worker", result.stderr)
        self.assertNotIn("Deploy complete.", result.stdout)


if __name__ == "__main__":
    unittest.main()
