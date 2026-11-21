"""Real KLayout DRC/LVS jobs and untrusted request boundaries."""
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.error import URLError
from urllib.request import ProxyHandler, Request, build_opener

_LOOPBACK_OPENER = build_opener(ProxyHandler({}))
urlopen = _LOOPBACK_OPENER.open

import klayout.db as db
from hongtu.verification import (
    _demo_mos4,
    _round_coord,
    _sky130_met1,
    _validated_details,
    bootstrap_trusted_venv,
    run_verification,
    validate_verification_request,
)


class VerificationTests(unittest.TestCase):
    def request(self, width=1000):
        with tempfile.TemporaryDirectory() as directory:
            layout = db.Layout()
            layout.dbu = 0.001
            top = layout.create_cell("TOP")
            top.shapes(layout.layer(68, 20)).insert(db.Box(0, 0, width, 1000))
            path = Path(directory) / "input.gds"
            layout.write(str(path))
            encoded = base64.b64encode(path.read_bytes()).decode()
        return {"kind": "drc", "technologyId": "sky130", "deckId": "sky130-met1-public", "documentGds": encoded}

    def test_real_drc_pass_and_fail(self):
        passed = run_verification(self.request())
        self.assertTrue(passed["success"], passed["error"])
        self.assertTrue(passed["complete"] and passed["passed"])
        failed = run_verification(self.request(100))
        self.assertTrue(failed["success"], failed["error"])
        self.assertTrue(failed["complete"])
        self.assertFalse(failed["passed"])
        self.assertGreater(failed["violationCount"], 0)
        self.assertEqual(failed["violations"][0]["layerNumber"], 68)
        self.assertFalse(failed["foundrySignoff"])

    def test_wrong_technology_and_missing_deck(self):
        request = self.request()
        request["technologyId"] = "unrelated-process"
        self.assertFalse(run_verification(request)["success"])
        request["deckId"] = "not-installed"
        self.assertFalse(run_verification(request)["passed"])

    def test_request_cannot_supply_code_paths_or_fields(self):
        request = self.request()
        request["script"] = "import os"
        with self.assertRaises(ValueError):
            validate_verification_request(request)
        request.pop("script")
        request["deckId"] = "../escape.py"
        with self.assertRaises(ValueError):
            validate_verification_request(request)

    def test_invalid_deck_cannot_publish_pass_or_bad_marker_coordinates(self):
        marker = {"rule": "R1", "message": "width", "layerNumber": 1, "datatype": 0,
                  "minX": 0, "minY": 0, "maxX": 10, "maxY": 10}
        with self.assertRaisesRegex(ValueError, "violations cannot pass"):
            _validated_details({"complete": True, "passed": True, "violations": [marker]})
        with self.assertRaisesRegex(ValueError, "incomplete"):
            _validated_details({"complete": False, "passed": True})
        marker["maxX"] = float("nan")
        with self.assertRaisesRegex(ValueError, "coordinates"):
            _validated_details({"complete": True, "passed": False, "violations": [marker]})
        marker["maxX"] = 10
        validated = _validated_details({"complete": True, "passed": False,
                                        "violations": [marker] * 5001, "foundrySignoff": True})
        self.assertEqual(validated["violationCount"], 5001)
        self.assertEqual(len(validated["violations"]), 5000)
        self.assertTrue(validated["markersTruncated"])
        self.assertNotIn("foundrySignoff", validated)

    def test_violation_coordinates_strip_float_mantissa_tails(self):
        self.assertEqual(_round_coord(0.1 + 0.2), 0.3)
        self.assertEqual(_round_coord(-0.0), 0.0)
        with tempfile.TemporaryDirectory() as directory:
            layout = db.Layout()
            layout.dbu = 0.0003  # 0.3 nm DBU triggers 100 * 0.3 = 30.000000000000004 in IEEE-754
            top = layout.create_cell("FLOAT_TAIL")
            top.shapes(layout.layer(68, 20)).insert(db.Box(1, 3, 101, 2003))
            gds_path = Path(directory) / "tail.gds"
            layout.write(str(gds_path))
            details = _sky130_met1(gds_path, "FLOAT_TAIL")
            validated = _validated_details(details)
            self.assertFalse(validated["passed"])
            self.assertGreater(validated["violationCount"], 0)
            for violation in validated["violations"]:
                for key in ("minX", "minY", "maxX", "maxY"):
                    coord = violation[key]
                    self.assertEqual(coord, round(coord, 6))
                    self.assertNotIn("000000000", repr(coord))

    def test_direct_unmocked_demo_mos4_entry_and_builtin_fallback(self):
        """Directly invoke _demo_mos4 without mocking to guard against missing verify_klayout_lvs.py."""
        python_root = Path(__file__).resolve().parents[1]
        self.assertTrue((python_root / "verify_klayout_lvs.py").is_file())
        samples = python_root / "samples"
        source = db.Layout()
        source.read(str(samples / "klayout-inv.oas"))
        reference_text = (samples / "klayout-inv.cir").read_text(encoding="utf-8")

        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            gds_path = folder / "inv.gds"
            source.write(str(gds_path))
            ref_path = folder / "inv.cir"
            ref_path.write_text(reference_text, encoding="utf-8")

            # 1. Real un-mocked call through verify_klayout_lvs.py
            out_primary = folder / "out-primary"
            direct = _demo_mos4(gds_path, ref_path, "INVERTER", out_primary)
            self.assertTrue(direct["complete"])
            self.assertTrue(direct["passed"])
            self.assertTrue((out_primary / "extracted.cir").is_file())
            self.assertIn("SUBCKT", direct["extractedSpice"].upper())
            models = {device["model"] for device in direct["devices"]}
            self.assertEqual(models, {"PMOS", "NMOS"})

            # 2. Connectivity mismatch must report complete=True, passed=False
            mismatch_ref = folder / "inv-mismatch.cir"
            mismatch_ref.write_text(reference_text.replace("OUT IN", "IN IN"), encoding="utf-8")
            mismatch = _demo_mos4(gds_path, mismatch_ref, "INVERTER", folder / "out-mismatch")
            self.assertTrue(mismatch["complete"])
            self.assertFalse(mismatch["passed"])

            # 3. Built-in fallback if verify_klayout_lvs.py were absent
            with patch.object(Path, "is_file", autospec=True,
                              side_effect=lambda p: False if p.name == "verify_klayout_lvs.py" else os.path.isfile(p)):
                fallback = _demo_mos4(gds_path, ref_path, "INVERTER", folder / "out-fallback")
            self.assertTrue(fallback["complete"] and fallback["passed"])
            self.assertEqual({d["model"] for d in fallback["devices"]}, {"PMOS", "NMOS"})

            # 4. Missing cell and empty layout fail explicitly without claiming pass
            with self.assertRaisesRegex(ValueError, "top circuit"):
                _demo_mos4(gds_path, ref_path, "NONEXISTENT_CELL", folder / "out-missing")
            empty_layout = db.Layout()
            empty_layout.create_cell("EMPTY")
            empty_gds = folder / "empty.gds"
            empty_layout.write(str(empty_gds))
            with self.assertRaisesRegex(ValueError, "no devices"):
                _demo_mos4(empty_gds, ref_path, "EMPTY", folder / "out-empty")

    def test_real_mos4_reference_and_connectivity_mismatch(self):
        samples = Path(__file__).resolve().parents[1] / "samples"
        source = db.Layout()
        source.read(str(samples / "klayout-inv.oas"))
        with tempfile.TemporaryDirectory() as directory:
            gds = Path(directory) / "demo.gds"
            source.write(str(gds))
            encoded = base64.b64encode(gds.read_bytes()).decode()
        reference = (samples / "klayout-inv.cir").read_text(encoding="utf-8")
        request = {"kind": "lvs", "technologyId": "klayout-demo", "deckId": "klayout-demo-mos4",
                   "documentGds": encoded, "referenceSpice": reference}
        result = run_verification(request)
        self.assertTrue(result["success"], result["error"])
        self.assertTrue(result["passed"])
        self.assertGreater(len(result["devices"]), 0)
        request["referenceSpice"] = reference.replace("OUT IN", "IN IN")
        result = run_verification(request)
        self.assertTrue(result["complete"], result["error"])
        self.assertFalse(result["passed"])

    def test_registered_hash_pinned_deck(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            deck = folder / "deck.py"
            deck.write_text('import klayout.db as db\ndef verify_layout(layout, reference, cell, output):\n'
                            '    view=db.Layout(); view.read(str(layout))\n'
                            '    return {"complete":True,"passed":view.cells()>0}\n', encoding="utf-8")
            registry = folder / "registry.json"
            registry.write_text(json.dumps({"decks": {"my-deck": {"technologyId": "my-tech", "kind": "drc",
                                       "path": "deck.py", "sha256": hashlib.sha256(deck.read_bytes()).hexdigest(),
                                       "scope": "Test process registry"}}}), encoding="utf-8")
            old = os.environ.get("HONGTU_TECHNOLOGY_REGISTRY")
            os.environ["HONGTU_TECHNOLOGY_REGISTRY"] = str(registry)
            try:
                request = self.request()
                request.update(technologyId="my-tech", deckId="my-deck")
                result = run_verification(request)
                self.assertTrue(result["success"] and result["passed"], result["error"])
                deck.write_text(deck.read_text(encoding="utf-8") + "\n# Changed after review\n", encoding="utf-8")
                result = run_verification(request)
                self.assertFalse(result["success"])
                self.assertIn("hash", result["error"])
            finally:
                if old is None:
                    os.environ.pop("HONGTU_TECHNOLOGY_REGISTRY", None)
                else:
                    os.environ["HONGTU_TECHNOLOGY_REGISTRY"] = old

    def test_cross_platform_isolated_venv_bootstrap(self):
        from hongtu.worker import bootstrap_trusted_venv as worker_bootstrap

        with tempfile.TemporaryDirectory() as directory:
            fake_root = Path(directory) / "python"
            posix_sp = fake_root / ".venv" / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "site-packages"
            win_sp = fake_root / ".venv" / "Lib" / "site-packages"
            posix_sp.mkdir(parents=True)
            win_sp.mkdir(parents=True)
            original_path = list(sys.path)
            try:
                inserted_v = bootstrap_trusted_venv(fake_root)
                self.assertIn(str(posix_sp), inserted_v)
                self.assertIn(str(win_sp), inserted_v)
                self.assertEqual(sys.path[0], str(fake_root))
                sys.path[:] = original_path
                inserted_w = worker_bootstrap(fake_root)
                self.assertIn(str(posix_sp), inserted_w)
                self.assertIn(str(win_sp), inserted_w)
            finally:
                sys.path[:] = original_path

    def test_isolated_bridge_entry_verifies_over_real_http(self):
        """Launch bridge_entry.py under -I with untrusted cwd/PYTHONPATH on both POSIX and Windows."""
        python_root = Path(__file__).resolve().parents[1]
        base_python = getattr(sys, "_base_executable", sys.executable)
        self.assertTrue(Path(base_python).is_file())
        from hongtu.bridge import worker_directory
        with worker_directory() as directory:
            folder = Path(directory)
            token = secrets.token_urlsafe(32)
            if os.name == "nt":
                config_dir = folder / "HongTu" / "python-bridge"
            else:
                config_dir = folder / "HongTu" / "python-bridge"
            config_dir.mkdir(parents=True)
            (config_dir / "config.json").write_text(json.dumps({
                "endpoint": "http://127.0.0.1:7865", "port": 7865, "token": token}), encoding="utf-8")
            with socket.socket() as reserved:
                reserved.bind(("127.0.0.1", 0))
                port = reserved.getsockname()[1]
            environment = dict(os.environ)
            if os.name == "nt":
                environment["LOCALAPPDATA"] = str(folder)
            else:
                environment["XDG_DATA_HOME"] = str(folder)
            # Both parent and children must ignore this untrusted directory under -I.
            (folder / "klayout.py").write_text("raise RuntimeError('untrusted cwd import')\n", encoding="utf-8")
            environment["PYTHONPATH"] = str(folder)
            kwargs = {"cwd": folder, "env": environment, "stdin": subprocess.DEVNULL,
                      "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
            if os.name == "nt":
                kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
            process = subprocess.Popen(
                [base_python, "-I", str(python_root / "bridge_entry.py"), "--port", str(port)],
                **kwargs)
            endpoint = f"http://127.0.0.1:{port}"
            try:
                deadline = time.monotonic() + 15
                health = None
                while time.monotonic() < deadline:
                    self.assertIsNone(process.poll(), "isolated bridge entry stopped before health")
                    try:
                        with urlopen(endpoint + "/health", timeout=1) as response:
                            health = json.load(response)
                        break
                    except (URLError, TimeoutError):
                        time.sleep(0.05)
                self.assertIsNotNone(health, "isolated bridge did not start")
                self.assertTrue(health["ok"])
                for width, expected_pass in ((1000, True), (100, False)):
                    payload = self.request(width)
                    payload["cellName"] = "TOP"
                    request = Request(endpoint + "/v1/verify", data=json.dumps(payload).encode(),
                                      headers={"Content-Type": "application/json", "Authorization": "Bearer " + token})
                    with urlopen(request, timeout=30) as response:
                        result = json.load(response)
                    self.assertTrue(result["success"], result["error"])
                    self.assertTrue(result["complete"])
                    self.assertEqual(result["passed"], expected_pass)
                    self.assertIn(health["engineVersion"], result["engine"])
                    self.assertEqual(json.loads(result["reportText"])["cellName"], "TOP")
                    self.assertFalse(result["foundrySignoff"])
                    if not expected_pass:
                        self.assertGreater(result["violationCount"], 0)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
