"""images-sync.sh refuses bad arguments and malformed downloads without touching the destination."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("images-sync.sh")
SHA = "a" * 40


class ImagesSyncTest(unittest.TestCase):
    def run_sync(self, args, fake_curl_body=None, curl_status=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dest = root / "images.json"
            bindir = root / "bin"
            bindir.mkdir()
            curl = bindir / "curl"
            body = json.dumps(fake_curl_body) if fake_curl_body is not None else ""
            curl.write_text(
                "#!/bin/bash\n"
                "out=''\nwhile [ $# -gt 0 ]; do if [ \"$1\" = -o ]; then out=$2; shift; fi; shift; done\n"
                f"printf '%s' '{body}' > \"$out\"\nexit {curl_status}\n"
            )
            curl.chmod(0o755)
            env = {**os.environ, "PATH": f"{bindir}:{os.environ['PATH']}"}
            result = subprocess.run(
                ["bash", str(SCRIPT), *args, str(dest)], env=env, capture_output=True, text=True
            )
            return result, dest.exists()

    def test_rejects_a_short_sha(self):
        result, written = self.run_sync(["abc"])
        self.assertEqual(result.returncode, 2)
        self.assertFalse(written)

    def test_installs_a_matching_document(self):
        doc = {"commit": SHA, "images": {"ncc-worker": {"digest": "sha256:" + "0" * 64}}}
        result, written = self.run_sync([SHA], fake_curl_body=doc)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(written)

    def test_refuses_a_document_for_another_commit(self):
        doc = {"commit": "b" * 40, "images": {"ncc-worker": {"digest": "sha256:" + "0" * 64}}}
        result, written = self.run_sync([SHA], fake_curl_body=doc)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(written)

    def test_a_missing_release_is_a_retry_not_a_crash(self):
        result, written = self.run_sync([SHA], curl_status=22)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(written)


if __name__ == "__main__":
    unittest.main()
