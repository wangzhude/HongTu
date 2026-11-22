"""Bounded KLayout verification jobs; process decks are selected by registered ID.

HTTP callers provide layout data, never code or executable paths. The two bundled
decks are explicitly small public/demo checks. Local administrators may register
a hash-pinned Python deck implementing verify_layout(layout, reference, cell, out).
Installing a deck does not imply foundry qualification.
"""
from __future__ import annotations

import base64
import hashlib
import json
import math
import os
from pathlib import Path
import re
import runpy
import site
import subprocess
import sys
import tempfile

MAX_LAYOUT_BYTES = 32 * 1024 * 1024
MAX_REFERENCE_BYTES = 2 * 1024 * 1024
MAX_MARKERS = 5000
TIMEOUT_SECONDS = 90
MEMORY_BYTES = 1024 * 1024 * 1024
BUILTINS = {"sky130-met1-public": ("sky130", "drc"), "klayout-demo-mos4": ("klayout-demo", "lvs")}
FIELDS = {"kind", "technologyId", "deckId", "documentGds", "referenceSpice", "cellName"}
ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,119}\Z")
COORD_DECIMALS = 6


def bootstrap_trusted_venv(trusted_root: Path | None = None) -> list[str]:
    """Populate sys.path under -I for Windows (.venv/Lib/site-packages) and POSIX (.venv/lib/pythonX.Y/site-packages)."""
    root = (trusted_root or Path(__file__).resolve().parents[1]).resolve()
    ver = f"python{sys.version_info.major}.{sys.version_info.minor}"
    candidates: list[Path] = []
    for venv in (root / ".venv", root.parent / ".venv", root.parent.parent / ".venv", Path(sys.prefix)):
        candidates.append(venv / "Lib" / "site-packages")
        candidates.append(venv / "lib" / ver / "site-packages")
        candidates.append(venv / "lib64" / ver / "site-packages")
        lib_dir = venv / "lib"
        if lib_dir.is_dir():
            candidates.extend(sorted(lib_dir.glob("python*/site-packages")))
    inserted: list[str] = []
    seen: set[str] = set()
    for candidate in reversed(candidates):
        resolved = str(candidate)
        if resolved not in seen and candidate.is_dir():
            seen.add(resolved)
            site.addsitedir(resolved)
            if resolved in sys.path:
                sys.path.remove(resolved)
            sys.path.insert(0, resolved)
            inserted.append(resolved)
    root_str = str(root)
    if root_str in sys.path:
        sys.path.remove(root_str)
    sys.path.insert(0, root_str)
    return list(reversed(inserted))


def _round_coord(value: int | float) -> int | float:
    if type(value) is int:
        return value
    rounded = round(float(value), COORD_DECIMALS)
    if rounded == 0.0:
        return 0.0
    return rounded


def validate_verification_request(request):
    if not isinstance(request, dict) or set(request) - FIELDS:
        raise ValueError("verification request has unknown fields")
    if request.get("kind") not in ("drc", "lvs"):
        raise ValueError("kind must be drc or lvs")
    for field in ("technologyId", "deckId"):
        if not isinstance(request.get(field), str) or not ID.fullmatch(request[field]):
            raise ValueError(f"invalid {field}")
    encoded = request.get("documentGds")
    if not isinstance(encoded, str) or not encoded or len(encoded) > (MAX_LAYOUT_BYTES + 2) // 3 * 4:
        raise ValueError("layout snapshot is missing or exceeds 32 MiB")
    try:
        binary = base64.b64decode(encoded, validate=True)
    except (ValueError, TypeError) as exc:
        raise ValueError("layout snapshot must be base64") from exc
    if not 6 <= len(binary) <= MAX_LAYOUT_BYTES:
        raise ValueError("invalid layout snapshot size")
    reference = request.get("referenceSpice", "")
    if not isinstance(reference, str) or len(reference.encode("utf-8")) > MAX_REFERENCE_BYTES:
        raise ValueError("reference netlist exceeds 2 MiB")
    if request["kind"] == "lvs" and not reference.strip():
        raise ValueError("LVS needs a reference SPICE netlist")
    cell = request.get("cellName", "")
    if not isinstance(cell, str) or len(cell) > 512 or "\0" in cell:
        raise ValueError("invalid Cell name")
    return request


def _empty(request, error=""):
    return {"success": False, "complete": False, "passed": False,
            "kind": request.get("kind", ""), "technologyId": request.get("technologyId", ""),
            "deckId": request.get("deckId", ""), "engine": "CPython + klayout.db",
            "scope": "", "foundrySignoff": False, "violationCount": 0, "markersTruncated": False,
            "violations": [], "devices": [], "netCount": 0, "reportText": "", "error": error}


def _registered_deck(request):
    builtin = BUILTINS.get(request["deckId"])
    if builtin:
        if (request["technologyId"], request["kind"]) != builtin:
            raise ValueError("deck does not belong to the selected technology or check kind")
        return None
    configured = os.environ.get("HONGTU_TECHNOLOGY_REGISTRY")
    if not configured:
        raise ValueError("deck is not installed; register this process deck on the companion computer")
    registry_path = Path(configured).resolve(strict=True)
    if registry_path.stat().st_size > 2 * 1024 * 1024:
        raise ValueError("technology registry exceeds limit")
    registry = json.loads(registry_path.read_text(encoding="utf-8-sig"))
    entry = registry.get("decks", {}).get(request["deckId"])
    if not isinstance(entry, dict) or entry.get("technologyId") != request["technologyId"] or entry.get("kind") != request["kind"]:
        raise ValueError("registered deck does not match technology and check kind")
    path = (registry_path.parent / entry.get("path", "")).resolve(strict=True)
    if path.suffix != ".py" or not path.is_file() or path.stat().st_size > 2 * 1024 * 1024:
        raise ValueError("registered deck must be a bounded Python file")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if not isinstance(entry.get("sha256"), str) or digest != entry["sha256"].lower():
        raise ValueError("registered deck hash changed; administrator must review and register the new version")
    return {"path": str(path), "sha256": digest, "scope": str(entry.get("scope", "User-installed process deck"))[:2000]}


def run_verification(request, *, _control=None):
    try:
        validate_verification_request(request)
        registered = _registered_deck(request)
    except (ValueError, TypeError, OSError) as exc:
        return _empty(request if isinstance(request, dict) else {}, str(exc)[:1200])
    from .limits import WindowsJob, child_environment, posix_limit
    from .jobs import JobCancelled
    with tempfile.TemporaryDirectory(prefix="hongtu-verification-") as directory:
        folder = Path(directory)
        (folder / "request.json").write_text(json.dumps(request), encoding="utf-8")
        (folder / "deck.json").write_text(json.dumps(registered), encoding="utf-8")
        kwargs = {"cwd": directory, "stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL,
                  "stderr": subprocess.DEVNULL, "env": child_environment()}
        if os.name == "nt":
            kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
        else:
            kwargs["preexec_fn"] = lambda: posix_limit(MEMORY_BYTES)
        process = None
        job = None
        try:
            executable = getattr(sys, "_base_executable", sys.executable) if os.name == "nt" else sys.executable
            command = [executable, "-I", str(Path(__file__).resolve()), "--worker", directory]
            if _control is not None:
                process = _control.spawn(lambda: subprocess.Popen(command, **kwargs),
                                         (lambda child: WindowsJob(child, MEMORY_BYTES)) if os.name == "nt" else None)
            else:
                process = subprocess.Popen(command, **kwargs)
                if os.name == "nt":
                    job = WindowsJob(process, MEMORY_BYTES)
            process.wait(timeout=TIMEOUT_SECONDS)
            result_path = folder / "result.json"
            if process.returncode != 0 or not result_path.is_file() or result_path.stat().st_size > 16 * 1024 * 1024:
                return _empty(request, "verification worker stopped or result exceeded its resource budget")
            return json.loads(result_path.read_text(encoding="utf-8"))
        except subprocess.TimeoutExpired:
            if _control is not None:
                _control.timed_out = True
            return _empty(request, "verification exceeded the 90 second resource limit; no pass conclusion")
        except JobCancelled:
            return _empty(request, "verification cancelled before execution; no pass conclusion")
        except (OSError, ValueError):
            return _empty(request, "verification worker could not start with resource limits")
        finally:
            if _control is not None:
                _control.reap()
            else:
                try:
                    if job:
                        job.close()
                finally:
                    if process is not None:
                        if process.poll() is None:
                            process.kill()
                        process.wait(timeout=5)


def _sky130_met1(path, cell_name):
    import klayout.db as db
    layout = db.Layout()
    layout.read(str(path))
    top = layout.cell(cell_name) if cell_name else layout.top_cell()
    if top is None:
        raise ValueError("requested Cell does not exist")
    layer = layout.find_layer(68, 20)
    if layer is None:
        raise ValueError("SKY130 met1 68/20 is absent; no rules evaluated")
    region = db.Region(top.begin_shapes_rec(layer)).merged()
    if region.is_empty():
        raise ValueError("selected Cell has no met1 geometry; no rules evaluated")
    width = math.ceil(0.140 / layout.dbu - 1e-10)
    area = math.ceil(0.083 / (layout.dbu * layout.dbu) - 1e-10)
    checks = [("m1.1", region.width_check(width)), ("m1.2", region.space_check(width)),
              ("m1.6", region.with_area(0, area, False))]
    markers, count = [], 0
    scale = layout.dbu * 1000.0
    for rule, items in checks:
        for item in items.each():
            count += 1
            if len(markers) < MAX_MARKERS:
                box = item.bbox()
                markers.append({"rule": rule, "layerNumber": 68, "datatype": 20,
                                "minX": _round_coord(box.left * scale), "minY": _round_coord(box.bottom * scale),
                                "maxX": _round_coord(box.right * scale), "maxY": _round_coord(box.top * scale),
                                "message": f"SKY130 met1 public subset {rule}"})
    return {"complete": True, "passed": count == 0, "violations": markers,
            "violationCount": count, "markersTruncated": count > len(markers),
            "scope": "SKY130 public met1 68/20 m1.1/m1.2/m1.6 only; no huge_met1 exceptions, other layers or foundry signoff"}


def _builtin_extract_mos4(path, cell_name=""):
    """Built-in fallback matching verify_klayout_lvs.extract if invoked standalone."""
    import klayout.db as db

    layout = db.Layout()
    layout.read(str(Path(path)))
    top = layout.cell(cell_name) if cell_name else layout.top_cell()
    if top is None:
        raise ValueError("demo extraction does not contain the requested top circuit")
    l2n = db.LayoutToNetlist(db.RecursiveShapeIterator(layout, top, []))

    def layer_or_empty(num, dt, name, text_only=False):
        idx = layout.find_layer(num, dt)
        if idx is None:
            return l2n.make_layer(name)
        return l2n.make_text_layer(idx, name) if text_only else l2n.make_layer(idx, name)

    nwell = layer_or_empty(1, 0, "nwell")
    active = layer_or_empty(2, 0, "active")
    pplus = layer_or_empty(3, 0, "pplus")
    nplus = layer_or_empty(4, 0, "nplus")
    poly = layer_or_empty(5, 0, "poly")
    contact = layer_or_empty(6, 0, "contact")
    metal1 = layer_or_empty(7, 0, "metal1")
    metal1_lbl = layer_or_empty(7, 1, "metal1_label", True)
    via1 = layer_or_empty(8, 0, "via1")
    metal2 = layer_or_empty(9, 0, "metal2")
    metal2_lbl = layer_or_empty(9, 1, "metal2_label", True)
    bulk = l2n.make_layer("bulk")

    active_in_nwell = active & nwell
    pactive = active_in_nwell & pplus
    ntie = active_in_nwell & nplus
    pgate = pactive & poly
    psd = pactive - pgate

    active_outside_nwell = active - nwell
    nactive = active_outside_nwell & nplus
    ptie = active_outside_nwell & pplus
    ngate = nactive & poly
    nsd = nactive - ngate

    l2n.extract_devices(db.DeviceExtractorMOS4Transistor("PMOS"),
                        {"SD": psd, "G": pgate, "P": poly, "W": nwell,
                         "tS": psd, "tD": psd, "tG": poly, "tB": nwell})
    l2n.extract_devices(db.DeviceExtractorMOS4Transistor("NMOS"),
                        {"SD": nsd, "G": ngate, "P": poly, "W": bulk,
                         "tS": nsd, "tD": nsd, "tG": poly, "tB": bulk})
    for lyr in (psd, nsd, poly, ntie, ptie, contact, metal1, via1, metal2, nwell):
        l2n.connect(lyr)
    for a, b in ((psd, contact), (nsd, contact), (poly, contact), (ntie, contact),
                 (ntie, nwell), (ptie, contact), (contact, metal1), (metal1, metal1_lbl),
                 (metal1, via1), (via1, metal2), (metal2, metal2_lbl),
                 (metal1, layer_or_empty(7, 0, "m1_direct_label", True)),
                 (metal2, layer_or_empty(9, 0, "m2_direct_label", True))):
        l2n.connect(a, b)
    l2n.connect_global(ptie, "SUBSTRATE")
    l2n.connect_global(bulk, "SUBSTRATE")
    nw_idx, act_idx, np_idx = layout.find_layer(1, 0), layout.find_layer(2, 0), layout.find_layer(4, 0)
    has_tie = (nw_idx is not None and act_idx is not None and np_idx is not None and
               not (db.Region(top.begin_shapes_rec(act_idx)) & db.Region(top.begin_shapes_rec(nw_idx)) &
                    db.Region(top.begin_shapes_rec(np_idx))).is_empty())
    if not has_tie:
        l2n.connect_global(nwell, "NWELL")
    l2n.extract_netlist()
    netlist = l2n.netlist()
    netlist.make_top_level_pins()
    netlist.simplify()
    return l2n, netlist


def _demo_mos4(path, reference, cell_name, folder):
    import inspect
    import klayout.db as db
    # This extraction is explicitly the official demo process, never inferred from a PDK name.
    lvs_script = Path(__file__).resolve().parents[1] / "verify_klayout_lvs.py"
    if lvs_script.is_file():
        module = runpy.run_path(str(lvs_script))
        extract_fn = module["extract"]
        params = list(inspect.signature(extract_fn).parameters)
        holder, actual = extract_fn(path, cell_name) if len(params) >= 2 else extract_fn(path)
    else:
        holder, actual = _builtin_extract_mos4(path, cell_name)
    check_layout = db.Layout()
    check_layout.read(str(Path(path)))
    requested_top = check_layout.cell(cell_name) if cell_name else check_layout.top_cell()
    if requested_top is None:
        raise ValueError("demo extraction does not contain the requested top circuit")
    circuit = actual.circuit_by_name(cell_name) if cell_name and hasattr(actual, "circuit_by_name") else actual.top_circuit()
    if circuit is None:
        circuit = actual.top_circuit()
    if circuit is None:
        raise ValueError("demo MOS4 extraction found no devices")
    if cell_name and circuit.name != cell_name:
        raise ValueError("demo extraction does not contain the requested top circuit")
    if not list(circuit.each_device()):
        raise ValueError("demo MOS4 extraction found no devices")
    expected = db.Netlist()
    expected.read(str(reference), db.NetlistSpiceReader())
    if expected.top_circuit() is None:
        raise ValueError("reference netlist has no top circuit")
    expected.simplify()
    passed = bool(db.NetlistComparer().compare(actual, expected))
    devices = [{"name": d.name, "model": d.device_class().name,
                "parameters": {p.name: _round_coord(d.parameter(p.id()))
                               for p in d.device_class().parameter_definitions()}}
               for d in circuit.each_device()]
    out_dir = Path(folder)
    out_dir.mkdir(parents=True, exist_ok=True)
    extracted_path = out_dir / "extracted.cir"
    actual.write(str(extracted_path), db.NetlistSpiceWriter())
    return {"complete": True, "passed": passed, "devices": devices,
            "netCount": len(list(circuit.each_net())),
            "scope": "Official KLayout demo MOS4 technology only; not SKY130 or foundry signoff",
            "extractedSpice": extracted_path.read_text(encoding="utf-8")}


def _validated_details(details):
    """Do not publish a pass or coordinates from an invalid deck result."""
    if not isinstance(details, dict):
        raise ValueError("verification deck returned no structured result")
    if type(details.get("complete")) is not bool or type(details.get("passed")) is not bool:
        raise ValueError("verification deck must explicitly report boolean complete and passed")
    if details["passed"] and not details["complete"]:
        raise ValueError("an incomplete verification cannot pass")
    markers, devices = details.get("violations", []), details.get("devices", [])
    if not isinstance(markers, list) or not isinstance(devices, list):
        raise ValueError("verification markers/devices must be arrays")
    normalized_markers = []
    for marker in markers:
        if not isinstance(marker, dict):
            raise ValueError("invalid verification marker")
        for field in ("rule", "message"):
            if not isinstance(marker.get(field), str) or len(marker[field]) > 2000:
                raise ValueError("invalid verification marker text")
        for field in ("layerNumber", "datatype"):
            if type(marker.get(field)) is not int or not 0 <= marker[field] <= 65535:
                raise ValueError("invalid verification marker layer/datatype")
        coords = {}
        for field in ("minX", "minY", "maxX", "maxY"):
            value = marker.get(field)
            if type(value) not in (int, float) or not math.isfinite(value):
                raise ValueError("invalid verification marker coordinates")
            coords[field] = _round_coord(value)
        if coords["minX"] > coords["maxX"] or coords["minY"] > coords["maxY"]:
            raise ValueError("inverted verification marker bounds")
        if len(normalized_markers) < MAX_MARKERS:
            normalized_markers.append({
                "rule": marker["rule"],
                "layerNumber": marker["layerNumber"],
                "datatype": marker["datatype"],
                **coords,
                "message": marker["message"],
            })
    count = details.get("violationCount", len(markers))
    nets = details.get("netCount", 0)
    truncated = details.get("markersTruncated", False)
    if type(count) is not int or count < len(markers) or type(nets) is not int or nets < 0:
        raise ValueError("invalid verification result counts")
    if type(truncated) is not bool or (count > len(markers) and not truncated):
        raise ValueError("verification marker count requires explicit truncation flag")
    if details["passed"] and count > 0:
        raise ValueError("verification with violations cannot pass")
    if len(devices) > 50000:
        raise ValueError("extracted device list exceeds 50000 item budget")
    for device in devices:
        if not isinstance(device, dict):
            raise ValueError("invalid extracted device")
        for field in ("name", "model"):
            if not isinstance(device.get(field), str) or len(device[field]) > 2000:
                raise ValueError("invalid extracted device name/model")
        parameters = device.get("parameters")
        if not isinstance(parameters, dict) or len(parameters) > 1024:
            raise ValueError("invalid extracted device parameters")
        for key, value in parameters.items():
            if not isinstance(key, str) or len(key) > 512 or type(value) not in (int, float) or not math.isfinite(value):
                raise ValueError("invalid extracted device parameter")
    scope = details.get("scope", "User-installed process deck")
    if not isinstance(scope, str) or len(scope) > 2000:
        raise ValueError("invalid verification scope")
    checked = {"complete": details["complete"], "passed": details["passed"], "scope": scope,
               "violations": normalized_markers, "violationCount": count,
               "markersTruncated": truncated or len(markers) > MAX_MARKERS,
               "devices": devices, "netCount": nets}
    if "extractedSpice" in details:
        if not isinstance(details["extractedSpice"], str) or len(details["extractedSpice"].encode("utf-8")) > MAX_REFERENCE_BYTES:
            raise ValueError("extracted SPICE exceeds report budget")
        checked["extractedSpice"] = details["extractedSpice"]
    return checked


def _worker(folder):
    request = json.loads((folder / "request.json").read_text(encoding="utf-8"))
    result = _empty(request)
    try:
        validate_verification_request(request)
        import klayout.db as db
        result["engine"] += " " + db.__version__
        binary = base64.b64decode(request["documentGds"], validate=True)
        path = folder / "input.gds"
        path.write_bytes(binary)
        reference = folder / "reference.cir"
        reference.write_text(request.get("referenceSpice", ""), encoding="utf-8")
        cell = request.get("cellName", "")
        registered = json.loads((folder / "deck.json").read_text(encoding="utf-8"))
        if registered is not None:
            deck = Path(registered["path"])
            if hashlib.sha256(deck.read_bytes()).hexdigest() != registered["sha256"]:
                raise ValueError("registered deck changed before execution")
            function = runpy.run_path(str(deck)).get("verify_layout")
            if not callable(function):
                raise ValueError("registered deck must define verify_layout(layout, reference, cell, output_dir)")
            details = function(path, reference if request["kind"] == "lvs" else None, cell, folder)
            if not isinstance(details, dict):
                raise ValueError("registered deck returned no structured result")
            details["scope"] = registered["scope"]
        elif request["deckId"] == "sky130-met1-public":
            details = _sky130_met1(path, cell)
        elif request["deckId"] == "klayout-demo-mos4":
            details = _demo_mos4(path, reference, cell, folder)
        else:
            raise ValueError("unregistered deck")
        details = _validated_details(details)
        for name in ("complete", "passed", "scope", "violations", "violationCount", "markersTruncated", "devices", "netCount"):
            if name in details:
                result[name] = details[name]
        result["success"] = True
        result["reportText"] = json.dumps({"schema": "hongtu-verification/v1", "inputSha256": hashlib.sha256(binary).hexdigest(),
                                          "cellName": cell, "technologyId": request["technologyId"], "deckId": request["deckId"],
                                          "deckSha256": registered["sha256"] if registered else "bundled",
                                          "engine": result["engine"], "foundrySignoff": False, "details": details}, ensure_ascii=False, indent=2)
    except Exception as exc:
        result = _empty(request, str(exc)[:1200])
    (folder / "result.json").write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__" and len(sys.argv) == 3 and sys.argv[1] == "--worker":
    # -I deliberately ignores cwd/PYTHONPATH and the base interpreter does not
    # inherit bridge_entry's sys.path. Match the generation worker's trusted
    # repository/venv bootstrap; never derive import paths from request content.
    bootstrap_trusted_venv(Path(__file__).resolve().parents[1])
    _worker(Path(sys.argv[2]))
