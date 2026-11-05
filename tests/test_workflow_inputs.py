"""Offline tests: workflow inputs never reach a shell script by ${{ }} expansion."""

import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
WORKFLOWS = REPO / ".github/workflows"
# Contexts a person triggering a workflow controls.
UNTRUSTED = re.compile(r"\$\{\{[^}]*\b(inputs\.|github\.event\.|github\.head_ref)")


def steps(path):
    """Yield (name, env, script) for each step with a `run:` in a workflow file.

    A line-based reader for this repository's workflow layout, so the tests
    need no YAML library.
    """
    lines = path.read_text().splitlines()
    name, env, indent = None, {}, None
    i = 0
    while i < len(lines):
        line = lines[i]
        step = re.match(r"^(\s*)- name: (.*)$", line)
        if step:
            name, env, indent = step.group(2).strip(), {}, len(step.group(1)) + 2
        elif indent is not None and re.match(rf"^ {{{indent}}}env:\s*$", line):
            i += 1
            while i < len(lines) and re.match(rf"^ {{{indent + 2},}}\S", lines[i]):
                key, _, value = lines[i].strip().partition(":")
                env[key] = value.strip()
                i += 1
            continue
        elif indent is not None and re.match(rf"^ {{{indent}}}run:", line):
            inline = line.split("run:", 1)[1].strip()
            if inline not in ("|", ">"):
                yield name, env, inline
            else:
                body = []
                i += 1
                while i < len(lines) and (not lines[i].strip() or re.match(rf"^ {{{indent + 1},}}", lines[i])):
                    body.append(lines[i])
                    i += 1
                yield name, env, textwrap.dedent("\n".join(body))
                continue
        i += 1


class WorkflowInputTest(unittest.TestCase):
    def test_no_untrusted_expression_inside_a_script(self):
        found = 0
        for path in sorted(WORKFLOWS.glob("*.yml")):
            for name, _, script in steps(path):
                found += 1
                self.assertIsNone(UNTRUSTED.search(script), f"{path.name}: step {name!r}")
        self.assertGreater(found, 20)

    def resolve(self, input_version="", ref="refs/heads/main", config_version="0.1.28"):
        step = next(s for s in steps(WORKFLOWS / "deploy.yml") if s[0] == "Resolve version")
        self.assertEqual(step[1]["INPUT_VERSION"], "${{ inputs.version }}")
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "output"
            output.touch()
            env = {**os.environ, "INPUT_VERSION": input_version, "CONFIG_VERSION": config_version,
                   "GITHUB_REF": ref, "GITHUB_OUTPUT": str(output)}
            result = subprocess.run(["bash", "-e", "-c", step[2]], cwd=tmp, env=env,
                                    capture_output=True, text=True)
            planted = sorted(p.name for p in Path(tmp).iterdir() if p.name != "output")
            return result.returncode, output.read_text(), planted

    def test_version_precedence(self):
        self.assertEqual(self.resolve()[:2], (0, "effective=0.1.28\n"))
        self.assertEqual(self.resolve(ref="refs/tags/deploy-v0.1.30")[:2], (0, "effective=0.1.30\n"))
        self.assertEqual(self.resolve("0.1.31", "refs/tags/deploy-v0.1.30")[:2], (0, "effective=0.1.31\n"))
        self.assertEqual(self.resolve("0.2.0-rc.1")[:2], (0, "effective=0.2.0-rc.1\n"))

    def test_hostile_versions_are_refused_and_never_run(self):
        for payload in ('$(touch planted)', '0.1.1"; touch planted; echo "', "`touch planted`",
                        "0.1.1|e", "0.1.1\ntouch planted", "latest"):
            with self.subTest(payload=payload):
                code, output, planted = self.resolve(payload)
                self.assertNotEqual(code, 0)
                self.assertEqual(output, "")
                self.assertEqual(planted, [])
        code, _, planted = self.resolve(ref="refs/tags/deploy-v0.1.1;touch-planted")
        self.assertNotEqual(code, 0)
        self.assertEqual(planted, [])


if __name__ == "__main__":
    unittest.main()
