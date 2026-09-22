#!/usr/bin/env python3
"""Tests for `scripts/ui-gate.sh --classify` — the gate's per-plan verdict.

Run from the repo root:

    python3 -m unittest discover -s scripts/tests -t .

The gate used to print FAIL for two very different outcomes: tests ran and
some failed, and the test runner never came up at all ("Timed out while
enabling automation mode"), which executes nothing and says nothing about the
code. Every fixture here is a fabricated xcodebuild log — no Xcode, no build,
no result bundle — because the classification is pure log parsing.
"""

import os
import subprocess
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO, "scripts", "ui-gate.sh")

EXECUTED_TOTAL = "Executed 28 tests, with 1 test skipped and 5 failures (0 unexpected) in 41.0 seconds"
RUNNER_WEDGE = (
    "    t =    30.01s Tear Down\n"
    "Failed to initialize for UI testing: Timed out while enabling automation mode.\n"
)


def classify(log_text, status):
    """Return (verdict, exit code) for a fabricated log."""
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as fh:
        fh.write(log_text)
        path = fh.name
    try:
        proc = subprocess.run(
            ["bash", SCRIPT, "--classify", path, str(status)],
            capture_output=True,
            text=True,
        )
        return proc.stdout.strip(), proc.returncode
    finally:
        os.unlink(path)


class ClassifyVerdictTests(unittest.TestCase):
    def test_zero_status_is_pass(self):
        log = "Test Suite 'All tests' passed\n" + EXECUTED_TOTAL + "\n"
        self.assertEqual(classify(log, 0), ("PASS", 0))

    def test_tests_ran_and_failed_is_fail(self):
        log = "Test Case '-[X testY]' failed\n" + EXECUTED_TOTAL + "\n** TEST FAILED **\n"
        self.assertEqual(classify(log, 65), ("FAIL", 1))

    def test_no_tests_and_a_wedged_runner_is_runner_failed(self):
        log = "Test Suite 'Full' started\n" + RUNNER_WEDGE + "** TEST FAILED **\n"
        self.assertEqual(classify(log, 65), ("RUNNER-FAILED", 1))

    def test_a_wedge_after_tests_ran_is_still_a_fail(self):
        """The cascade case: the runner died partway, but tests DID run, so
        the run carries real results and must not be written off as
        environmental."""
        log = "Timed out while enabling automation mode\n" + EXECUTED_TOTAL + "\n"
        self.assertEqual(classify(log, 65), ("FAIL", 1))

    def test_a_failure_with_no_tests_and_no_wedge_is_a_fail(self):
        """A compile error executes nothing either — that IS a code failure."""
        log = "SomeFile.swift:12:5: error: cannot find 'foo' in scope\n** BUILD FAILED **\n"
        self.assertEqual(classify(log, 65), ("FAIL", 1))

    def test_the_other_runner_wedge_spelling_counts(self):
        log = "Not authorized for performing UI testing actions.\n** TEST FAILED **\n"
        self.assertEqual(classify(log, 65), ("RUNNER-FAILED", 1))

    def test_a_missing_log_is_an_error_not_a_verdict(self):
        proc = subprocess.run(
            ["bash", SCRIPT, "--classify", "/nonexistent/ui-gate.log", "65"],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
