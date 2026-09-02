#!/usr/bin/env python3
"""Self-check for history.py: symlink/FIFO/hardlink/overflow must not leak."""
import os
import re
import stat
import tempfile
import time
import unittest

import history


def _state(tmp):
    os.environ["XDG_STATE_HOME"] = tmp
    os.environ.pop("HOME", None)
    return history.open_state_dir()


class HistorySecurity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cellmate-hist-")
        self.dirfd = _state(self.tmp)
        self.omarchy = os.path.join(self.tmp, "omarchy")
        self.path = os.path.join(self.omarchy, history.NAME)

    def tearDown(self):
        os.close(self.dirfd)
        os.system("rm -rf %s" % self.tmp)

    def test_roundtrip(self):
        rec = b"1700000000 0.8500 12.3000 1"
        history.append_record(self.dirfd, rec)
        self.assertEqual(history.load_records(self.dirfd), [rec])
        st = os.stat(self.path)
        self.assertTrue(stat.S_ISREG(st.st_mode))
        self.assertEqual(st.st_mode & 0o777, 0o600)

    def test_rejects_symlink(self):
        target = os.path.join(self.tmp, "victim")
        with open(target, "w") as f:
            f.write("secret\n")
        os.symlink(target, self.path)
        rec = b"1700000000 0.8500 12.3000 1"
        history.append_record(self.dirfd, rec)
        with open(target) as f:
            self.assertEqual(f.read(), "secret\n")
        self.assertFalse(os.path.islink(self.path))
        self.assertEqual(history.load_records(self.dirfd), [rec])

    def test_fifo_does_not_block(self):
        os.mkfifo(self.path)
        t0 = time.monotonic()
        self.assertEqual(history.load_records(self.dirfd), [])
        rec = b"1700000000 0.8500 12.3000 1"
        history.append_record(self.dirfd, rec)
        self.assertLess(time.monotonic() - t0, 1.0)
        self.assertTrue(stat.S_ISREG(os.stat(self.path).st_mode))
        self.assertEqual(history.load_records(self.dirfd), [rec])

    def test_hardlink_not_appended(self):
        other = os.path.join(self.tmp, "other")
        with open(self.path, "w") as f:
            f.write("1700000000 0.1000 1.0000 0\n")
        os.link(self.path, other)
        rec = b"1700000001 0.2000 2.0000 1"
        history.append_record(self.dirfd, rec)
        with open(other) as f:
            self.assertEqual(f.read(), "1700000000 0.1000 1.0000 0\n")
        self.assertEqual(history.load_records(self.dirfd), [rec])

    def test_drops_long_and_non_numeric(self):
        blob = b"not a record\n" + (b"x" * 400 + b"\n") + b"1700000000 0.5000 1.0000 0\n"
        os.write(os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), blob)
        recs = history.load_records(self.dirfd)
        self.assertEqual(recs, [b"1700000000 0.5000 1.0000 0"])

    def test_caps_store(self):
        recs = [
            ("1700000%03d 0.5000 1.0000 0" % i).encode()
            for i in range(history.MAX_STORE + 50)
        ]
        history._replace(self.dirfd, recs)
        got = history.load_records(self.dirfd)
        self.assertEqual(len(got), history.MAX_KEEP)
        self.assertEqual(got[0], recs[-history.MAX_KEEP])
        self.assertEqual(got[-1], recs[-1])

    def test_existing_dir_is_made_private(self):
        os.chmod(self.omarchy, 0o755)
        os.close(self.dirfd)
        self.dirfd = history.open_state_dir()
        self.assertEqual(stat.S_IMODE(os.fstat(self.dirfd).st_mode), 0o700)

    def test_dir_symlink_rejected(self):
        os.close(self.dirfd)
        evil = os.path.join(self.tmp, "evil")
        os.mkdir(evil)
        os.rename(self.omarchy, os.path.join(self.tmp, "real"))
        os.symlink(evil, self.omarchy)
        with self.assertRaises(OSError):
            history.open_state_dir()
        self.dirfd = os.open(self.tmp, os.O_RDONLY | os.O_DIRECTORY)

    def test_relative_state_rejected(self):
        """Relative XDG_STATE_HOME raises OSError."""
        os.environ["XDG_STATE_HOME"] = "relative/state"
        os.environ.pop("HOME", None)
        with self.assertRaises(OSError):
            history.open_state_dir()
        os.environ.pop("XDG_STATE_HOME", None)
        os.environ["HOME"] = "relative"
        with self.assertRaises(OSError):
            history.open_state_dir()

    def test_ancestor_symlink_rejected(self):
        """Ancestor symlink in XDG_STATE_HOME raises OSError; no write under its target."""
        base = tempfile.mkdtemp(prefix="cellmate-ancestor-")
        try:
            target = os.path.join(base, "target")
            os.mkdir(target)
            link = os.path.join(base, "link")
            os.symlink(target, link)
            state_dir = os.path.join(link, "state")
            os.environ["XDG_STATE_HOME"] = state_dir
            os.environ.pop("HOME", None)
            with self.assertRaises(OSError):
                history.open_state_dir()
            self.assertEqual(os.listdir(target), [],
                             "symlink target must remain untouched")
        finally:
            os.system("rm -rf %s" % base)

    def test_panel_qml_process_safety(self):
        """Every Process block in Panel.qml has clearEnvironment, pinned PATH,
        and automatic producers use absolute executables (hostile-PATH regression)."""
        panel_path = os.path.join(os.path.dirname(__file__), "Panel.qml")
        with open(panel_path) as f:
            content = f.read()
        lines = content.splitlines()
        # Split into Process blocks by tracking brace depth.
        blocks = []
        i = 0
        while i < len(lines):
            if lines[i].strip().endswith("Process {"):
                start = i
                depth = 1
                j = i + 1
                while j < len(lines) and depth > 0:
                    depth += lines[j].count("{") - lines[j].count("}")
                    j += 1
                blocks.append("\n".join(lines[start:j]))
            i += 1
        self.assertGreater(len(blocks), 0, "no Process blocks in Panel.qml")
        known_pids = set()
        for block in blocks:
            self.assertIn("clearEnvironment: true", block,
                          "block missing clearEnvironment:\n" + block)
            self.assertIn("environment: ({", block,
                          "block missing environment:\n" + block)
            self.assertIn(
                'PATH: "/run/current-system/sw/bin:/usr/bin:/bin"', block,
                "block missing pinned PATH:\n" + block)
            # Extract block id (present on named processes).
            m = re.search(r'\bid:\s*(\w+)', block)
            pid = m.group(1) if m else "anonymous"
            known_pids.add(pid)
            if pid in ("detailsProc", "profilesProc", "histLoad",
                       "histAppend", "topProc", "actionProc"):
                # Automatic processes: every externally-resolved executable
                # (timeout, python3, sh) MUST be absolute to resist hostile PATH.
                self.assertNotIn(
                    '"timeout"', block,
                    f"{pid} uses bare \"timeout\"; must be absolute")
                self.assertNotIn(
                    '"python3"', block,
                    f"{pid} uses bare \"python3\"; must be absolute")
                self.assertNotIn(
                    '"sh"', block,
                    f"{pid} uses bare \"sh\"; must be absolute")
        # Verify all expected named processes were found.
        expected = {"detailsProc", "profilesProc", "histLoad",
                    "histAppend", "topProc", "actionProc"}
        missing = expected - known_pids
        self.assertFalse(missing, f"expected Process blocks missing: {missing}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
