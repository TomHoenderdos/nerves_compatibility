"""Pin the gates on the privileged CI workflows without a YAML library.

images.yml pushes the worker image and creates a GitHub release with write
tokens. It triggers on `workflow_run`, whose `branches:` filter matches the
triggering run's head branch *name*: a pull request from a fork whose branch
is called `main` passes it. Every job must therefore check for itself that the
run it follows was a push to main of this repository.

The parser below understands only the subset these workflows use (block
mappings, `- ` list items and `>-` folded scalars), which keeps the suite
stdlib-only like the rest of ops/.
"""

from pathlib import Path
import re
import unittest


WORKFLOWS = Path(__file__).resolve().parent.parent / ".github" / "workflows"

WORKFLOW_RUN_GATE = (
    "github.event_name == 'workflow_run'",
    "github.event.workflow_run.conclusion == 'success'",
    "github.event.workflow_run.event == 'push'",
    "github.event.workflow_run.head_branch == 'main'",
    "github.event.workflow_run.head_repository.full_name == github.repository",
)
DISPATCH_GATE = (
    "github.event_name == 'workflow_dispatch'",
    "github.ref == 'refs/heads/main'",
)


def jobs(path):
    """Map each job id to the lines of its block, indentation stripped by 4."""
    lines = path.read_text().splitlines()
    start = lines.index("jobs:")
    blocks, current = {}, None
    for line in lines[start + 1:]:
        if line and not line.startswith(" "):
            break
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if match:
            current = match.group(1)
            blocks[current] = []
        elif current is not None:
            blocks[current].append(line[4:] if line.startswith("    ") else line)
    return blocks


def job_key(block, key):
    """The value of a top-level key of a job, joining a folded scalar."""
    for index, line in enumerate(block):
        match = re.match(rf"^{key}:\s*(.*)$", line)
        if not match:
            continue
        value = match.group(1)
        if value not in (">-", ">", "|", "|-"):
            return value
        folded = []
        for continuation in block[index + 1:]:
            if continuation.startswith("  ") or not continuation.strip():
                folded.append(continuation.strip())
            else:
                break
        return " ".join(part for part in folded if part)
    return None


def normalise(expression):
    return re.sub(r"\s+", " ", expression)


class ImagesWorkflowGateTest(unittest.TestCase):
    path = WORKFLOWS / "images.yml"

    def setUp(self):
        self.jobs = jobs(self.path)

    def test_has_the_publishing_jobs(self):
        self.assertEqual(
            sorted(self.jobs), ["agent-release", "publish", "worker-image"]
        )

    def test_every_job_requires_a_push_to_main_of_this_repository(self):
        for name, block in self.jobs.items():
            with self.subTest(job=name):
                condition = job_key(block, "if")
                self.assertIsNotNone(condition, f"{name} has no if:")
                condition = normalise(condition)
                for clause in WORKFLOW_RUN_GATE + DISPATCH_GATE:
                    self.assertIn(clause, condition)

    def test_dispatch_is_limited_to_main(self):
        for name, block in self.jobs.items():
            with self.subTest(job=name):
                condition = normalise(job_key(block, "if") or "")
                dispatch = re.search(
                    r"\(\s*github\.event_name == 'workflow_dispatch' && "
                    r"github\.ref == 'refs/heads/main'\s*\)",
                    condition,
                )
                self.assertIsNotNone(dispatch, condition)

    def test_checkouts_build_the_triggering_commit(self):
        text = self.path.read_text()
        self.assertIn(
            "${{ github.event.workflow_run.head_sha || github.sha }}", text
        )
        checkouts = re.findall(
            r"uses: actions/checkout@\S+.*\n\s+with:\n((?:\s+\w[\w-]*: .*\n)+)",
            text,
        )
        self.assertTrue(checkouts)
        for options in checkouts:
            self.assertIn("ref: ${{ steps.sha.outputs.sha }}", options)
            self.assertIn("persist-credentials: false", options)

    def test_every_job_declares_its_permissions(self):
        expected = {
            "worker-image": {"contents: read", "packages: write"},
            "agent-release": {"contents: read"},
            "publish": {"contents: write"},
        }
        for name, block in self.jobs.items():
            with self.subTest(job=name):
                self.assertEqual(permissions(block), expected[name])


def permissions(block):
    """The job's permissions mapping as a set of `scope: level` strings."""
    try:
        start = block.index("permissions:")
    except ValueError:
        return None
    granted = set()
    for line in block[start + 1:]:
        if not line.startswith("  ") or line.startswith("   "):
            break
        granted.add(line.strip())
    return granted


class EveryWorkflowTest(unittest.TestCase):
    def test_every_job_declares_its_permissions(self):
        for path in sorted(WORKFLOWS.glob("*.yml")):
            for name, block in jobs(path).items():
                with self.subTest(workflow=path.name, job=name):
                    granted = permissions(block)
                    self.assertTrue(granted, f"{path.name}:{name}")
                    contents = {g for g in granted if g.startswith("contents:")}
                    # Only the release job may write contents.
                    allowed = (
                        {"contents: write"}
                        if (path.name, name) == ("images.yml", "publish")
                        else {"contents: read"}
                    )
                    self.assertEqual(contents, allowed)

    def test_workflows_are_tab_free_and_parse_as_block_yaml(self):
        for path in sorted(WORKFLOWS.glob("*.yml")):
            with self.subTest(workflow=path.name):
                text = path.read_text()
                self.assertNotIn("\t", text)
                self.assertIn("\njobs:\n", text)
                for number, line in enumerate(text.splitlines(), 1):
                    indent = len(line) - len(line.lstrip(" "))
                    self.assertEqual(indent % 2, 0, f"{path.name}:{number}")


if __name__ == "__main__":
    unittest.main()
