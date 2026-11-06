"""Pin the gates on the privileged CI jobs without a YAML library.

`deploy.yml`'s `worker-image`, `worker-manifest`, `agent-release` and
`publish` jobs push the worker image and create a GitHub release with write
tokens (`packages: write`, `contents: write`). They run `needs: test`, so a
failing `test` job already skips them, but `needs:` alone does not keep a
pull_request run, including one from a fork, out of this default-branch
context: a fork's `ref` is `refs/pull/N/merge`, never `refs/heads/main`, and
`github.repository` always names the base repo for a `pull_request` event
(whose `GITHUB_TOKEN` is read-only anyway), so each job repeats the full
push-or-dispatch-to-main-of-this-repository check in its own `if:` rather
than relying on either alone.

The parser below understands only the subset these workflows use (block
mappings, `- ` list items and `>-` folded scalars), which keeps the suite
stdlib-only like the rest of ops/.
"""

from pathlib import Path
import re
import unittest


WORKFLOWS = Path(__file__).resolve().parent.parent / ".github" / "workflows"

IMAGE_JOBS = ("worker-image", "worker-manifest", "agent-release", "publish")

PUSH_OR_DISPATCH_GATE = (
    "github.repository == 'TomHoenderdos/nerves_compatibility'",
    "github.ref == 'refs/heads/main'",
    "(github.event_name == 'push' || github.event_name == 'workflow_dispatch')",
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


class ImagesJobsGateTest(unittest.TestCase):
    """The image-publishing jobs that live inside `deploy.yml`.

    They run alongside `deploy` (both only `needs: test`) so that the image
    build starts as soon as tests pass on main, instead of waiting on
    `deploy`'s builder drain, which can take up to two hours.
    """

    path = WORKFLOWS / "deploy.yml"

    def setUp(self):
        self.jobs = jobs(self.path)

    def test_has_the_test_deploy_and_publishing_jobs(self):
        self.assertEqual(
            sorted(self.jobs),
            sorted(("test", "deploy") + IMAGE_JOBS),
        )

    def test_image_jobs_need_only_test_transitively(self):
        # Each image job's dependency chain bottoms out at `test`, never at
        # `deploy`: the image path must not wait for the drain.
        self.assertEqual(normalise(job_key(self.jobs["worker-image"], "needs")), "test")
        self.assertEqual(normalise(job_key(self.jobs["worker-manifest"], "needs")), "worker-image")
        self.assertEqual(normalise(job_key(self.jobs["agent-release"], "needs")), "test")
        self.assertIn("worker-manifest", job_key(self.jobs["publish"], "needs"))
        self.assertIn("agent-release", job_key(self.jobs["publish"], "needs"))
        for job in IMAGE_JOBS:
            self.assertNotIn("deploy", job_key(self.jobs[job], "needs") or "")

    def test_worker_image_is_built_natively_per_architecture(self):
        block = "\n".join(self.jobs["worker-image"])
        self.assertIn("runs-on: ${{ matrix.runner }}", block)
        for arch, platform, runner in (
            ("x86_64", "linux/amd64", "ubuntu-24.04"),
            ("aarch64", "linux/arm64", "ubuntu-24.04-arm"),
        ):
            self.assertRegex(
                block,
                rf"- arch: {arch}\n\s+platform: {platform}\n\s+runner: {runner}\n",
            )
        # Plain platform manifests: an attestation would wrap each push in
        # an index, and images.json must name the image a builder runs.
        self.assertIn("provenance: false", block)
        self.assertIn("sbom: false", block)
        self.assertIn("push-by-digest=true", block)

    def test_images_json_names_a_digest_per_architecture(self):
        block = "\n".join(self.jobs["publish"])
        self.assertIn('"digest": amd64', block)
        self.assertIn('"platforms": {"x86_64": amd64, "aarch64": arm64}', block)

    def test_every_image_job_requires_a_push_or_dispatch_to_main_of_this_repository(self):
        for name in IMAGE_JOBS:
            with self.subTest(job=name):
                condition = job_key(self.jobs[name], "if")
                self.assertIsNotNone(condition, f"{name} has no if:")
                condition = normalise(condition)
                for clause in PUSH_OR_DISPATCH_GATE:
                    self.assertIn(clause, condition)

    def test_deploy_job_is_not_a_prerequisite_of_any_image_job(self):
        # `test` has no `if:` of its own (it must run on every push and PR);
        # `deploy` keeps its own extra `vars.PORTAL_AUTO_DEPLOY` clause and is
        # checked separately, not reused by the image jobs.
        for name in IMAGE_JOBS:
            condition = normalise(job_key(self.jobs[name], "if") or "")
            self.assertNotIn("PORTAL_AUTO_DEPLOY", condition)

    def test_checkouts_build_the_triggering_commit(self):
        text = self.path.read_text()
        # No `workflow_run` indirection: every job here is triggered directly
        # by the push/dispatch it runs for, so plain checkout already gets
        # the right commit.
        self.assertNotIn("workflow_run", text)
        checkouts = re.findall(
            r"uses: actions/checkout@\S+.*\n\s+with:\n((?:\s+\w[\w-]*: .*\n)+)",
            text,
        )
        self.assertTrue(checkouts)
        for options in checkouts:
            self.assertIn("persist-credentials: false", options)

    def test_every_job_declares_its_permissions(self):
        expected = {
            "worker-image": {"contents: read", "packages: write"},
            "worker-manifest": {"contents: read", "packages: write"},
            "agent-release": {"contents: read"},
            "publish": {"contents: write"},
        }
        for name, want in expected.items():
            with self.subTest(job=name):
                self.assertEqual(permissions(self.jobs[name]), want)

    def test_image_jobs_are_concurrency_scoped_per_sha(self):
        # So a second run for the same sha (a retriggered dispatch, say)
        # queues behind the first instead of racing it.
        for name in IMAGE_JOBS:
            with self.subTest(job=name):
                block = "\n".join(self.jobs[name])
                match = re.search(r"concurrency:\n\s+group:\s*(\S.*)\n", block)
                self.assertIsNotNone(match, f"{name} has no concurrency group")
                self.assertIn("github.sha", match.group(1))
                self.assertIn("cancel-in-progress: false", block)


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
                        if (path.name, name) == ("deploy.yml", "publish")
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
