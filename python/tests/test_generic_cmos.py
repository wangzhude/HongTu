"""Actual restricted-worker/HTTP regression for the fixed generic inverter tool.

All layouts here are parametric synthetic fixtures. No external/reference GDS is
read, and no process, electrical simulation or foundry verification is claimed.
"""
import base64
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

_LOOPBACK_OPENER = build_opener(ProxyHandler({}))
urlopen = _LOOPBACK_OPENER.open

import klayout.db as db
from hongtu.bridge import Handler, generate
from hongtu.generic_cmos import GenericInverterError, generic_cmos_inverter, validate_generic_inverter, Reviewer, resolve_mapping
from hongtu.policy import PolicyError, validate_request, validate_script
from hongtu.worker import collect_layer_definitions, execute

SCRIPT = """import hongtu as db
layout = db.Layout()
layout.dbu = 0.001
cell = db.generic_cmos_inverter(layout, gate_length=200, nmos_width=600, pmos_width=1200)
"""
SHORT = SCRIPT + "cell.shapes(layout.layer(7,0)).insert(db.Box(850,1200,950,3900))\n"


class GenericInverterExecution(unittest.TestCase):
    def test_parameterized_helper_dimensions_and_fixed_review(self):
        for length, nw, pw in ((200, 600, 1200), (101, 403, 809), (100, 100, 100), (100000, 100000, 100000)):
            with self.subTest(length=length, nw=nw, pw=pw):
                layout = db.Layout()
                cell = generic_cmos_inverter(layout, "PARAMETRIC", length, nw, pw)
                definitions = collect_layer_definitions(layout, list(layout.layer_indexes()))
                summary = validate_generic_inverter(layout, definitions)
                self.assertIn("formalLvs=false", summary)
                self.assertIn("foundrySignoff=false", summary)
                channel = db.Region(cell.begin_shapes_rec(layout.layer(2, 0))) & db.Region(cell.begin_shapes_rec(layout.layer(3, 0)))
                self.assertEqual(sorted((p.bbox().width(), p.bbox().height()) for p in channel.each()), [(length, nw), (length, pw)])
                mapping, _ = resolve_mapping(definitions, {})
                report = Reviewer(layout, cell, mapping, {p: p for p in ("IN", "OUT", "VDD", "VSS")}).run()
                self.assertEqual(len(set(report["ports"].values())), 4)
                self.assertEqual(report["findings"], [])

    def test_helper_rejects_invalid_parameters_before_mutation(self):
        for values in ({"gate_length": True}, {"gate_length": 99}, {"nmos_width": 1.2},
                       {"pmos_width": 100001}, {"cell_name": "../invalid"}):
            layout = db.Layout()
            with self.assertRaises(ValueError):
                generic_cmos_inverter(layout, **values)
            self.assertEqual(layout.cells(), 0)
        layout.create_cell("EXISTING")
        with self.assertRaisesRegex(ValueError, "empty"):
            generic_cmos_inverter(layout)
        self.assertIsNotNone(layout.cell("EXISTING"))

    def test_real_worker_success_retains_named_layers_and_review(self):
        result = generate(SCRIPT, validationProfile="generic_inverter")
        self.assertTrue(result["success"], result.get("error"))
        self.assertEqual(result["layerCount"], 8)
        self.assertEqual(result["layerDefinitions"][-1]["name"], "PIN_LABEL")
        self.assertIn("generic_inverter: consistent", result["reviewSummary"])
        layout = db.Layout()
        layout.read_bytes(base64.b64decode(result["gdsBase64"]))
        self.assertEqual(layout.top_cell().name, "INVERTER")
        self.assertEqual(result["shapeCount"], 30)

    def test_actual_short_fails_before_export_with_bounded_geometric_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(GenericInverterError, "shorted_ports") as error:
                execute({"script": SHORT, "validationProfile": "generic_inverter"}, directory)
            self.assertIn("bboxUm", str(error.exception))
            self.assertFalse(Path(directory, "generated.gds").exists())
        result = generate(SHORT, validationProfile="generic_inverter")
        self.assertFalse(result["success"])
        self.assertTrue(result["error"].startswith("GenericInverterError:"))
        self.assertLessEqual(len(result["error"]), 3000)
        self.assertNotIn("gdsBase64", result)
        self.assertNotIn("layerDefinitions", result)
        self.assertNotIn("reviewSummary", result)

    def test_default_manual_generation_keeps_previous_behavior(self):
        for values in ({}, {"validationProfile": ""}):
            result = generate(SHORT, **values)
            self.assertTrue(result["success"], result.get("error"))
            self.assertNotIn("reviewSummary", result)

    def test_fixed_profile_rejects_missing_layers_extra_top_and_unknown_geometry(self):
        scripts = ["import hongtu as db\nlayout=db.Layout()\nc=layout.create_cell('ONLY_BOX')\nc.shapes(layout.layer(1,0)).insert(db.Box(0,0,100,100))",
                   SCRIPT + "layout.create_cell('EXTRA_TOP')\n",
                   SCRIPT + "cell.shapes(layout.layer(db.LayerInfo(99,0,'UNMODELED'))).insert(db.Box(0,0,10,10))\n"]
        for script in scripts:
            result = generate(script, validationProfile="generic_inverter")
            self.assertFalse(result["success"])
            self.assertTrue(result["error"].startswith("GenericInverterError:"))
            self.assertNotIn("gdsBase64", result)

    def test_profile_request_type_and_scope_cannot_expand_capabilities(self):
        for profile in (None, True, [], {}, "sky130", "generic_inverter\n"):
            with self.assertRaises(PolicyError):
                validate_request({"script": SCRIPT, "validationProfile": profile})
        for extras in ({"inputMode": "document"}, {"inputMode": "selection"}, {"documentGds": "ignored"}, {"selectionGds": "ignored"}):
            with self.assertRaisesRegex(PolicyError, "only accepts new"):
                validate_request({"script": SCRIPT, "validationProfile": "generic_inverter", **extras})
        for script in ("import hongtu.generic_cmos", "db.generic_cmos_inverter.__globals__", "import os"):
            with self.assertRaises(PolicyError):
                validate_script(script)
        validate_script("from hongtu import generic_cmos_inverter")

    def test_authenticated_http_profile_success_failure_and_unknown_field(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.token, server.job_lock, server.daemon_threads = "synthetic-private-test-token-00000000", threading.Lock(), True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            endpoint = "http://127.0.0.1:" + str(server.server_port) + "/v1/generate"
            def request(script, **extra):
                return Request(endpoint, data=json.dumps({"script": script, "validationProfile": "generic_inverter", **extra}).encode(),
                               headers={"Content-Type": "application/json", "Authorization": "Bearer " + server.token})
            with urlopen(request(SCRIPT), timeout=25) as response:
                self.assertIn("foundrySignoff=false", json.load(response)["reviewSummary"])
            with urlopen(request(SHORT), timeout=25) as response:
                result = json.load(response)
                self.assertFalse(result["success"])
                self.assertIn("GenericInverterError:", result["error"])
                self.assertNotIn("gdsBase64", result)
            with self.assertRaises(HTTPError) as error:
                urlopen(request(SCRIPT, validationProfile="unknown"), timeout=5)
            self.assertEqual(error.exception.code, 400)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
