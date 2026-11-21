"""Unit test wrapper executing cross-end Python/ArkTS & CI contract assertions."""
from pathlib import Path
import unittest

from check_contracts import run_all_checks


class CrossEndContractTests(unittest.TestCase):
    def test_cross_end_contracts_hypium_and_ci_hygiene(self):
        repo_root = Path(__file__).resolve().parents[2]
        failures = run_all_checks(repo_root)
        self.assertEqual(failures, [], "\n".join(failures))


if __name__ == "__main__":
    unittest.main()
