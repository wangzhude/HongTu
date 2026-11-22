"""One generated script per fresh process. Invoked only by the bridge supervisor."""
import base64
import io
import json
import math
import re
from pathlib import Path
import site
import sys


def bootstrap_trusted_venv(trusted_root: Path | None = None) -> list[str]:
    """Populate sys.path under -I across Windows and POSIX virtual environments."""
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


# -I removes cwd/PYTHONPATH. This path is the installed, trusted package source.
bootstrap_trusted_venv(Path(__file__).resolve().parents[1])


def collect_layer_definitions(layout, layers):
    """GDS does not carry layer names or empty layers; preserve them explicitly."""
    from hongtu.policy import PolicyError
    if not 1 <= len(layers) <= 256:
        raise PolicyError("layer definitions must contain 1..256 entries")
    result, seen = [], set()
    for index in layers:
        info = layout.get_info(index)
        pair = (info.layer, info.datatype)
        if any(type(value) is not int or not 0 <= value <= 32767 for value in pair):
            raise PolicyError("layer number and datatype must be integers in 0..32767")
        if pair in seen:
            raise PolicyError("duplicate layer/datatype definition")
        name = info.name
        if not isinstance(name, str) or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in name):
            raise PolicyError("layer name must be text without control characters")
        try:
            encoded_name = name.encode("utf-8")
        except UnicodeError:
            raise PolicyError("layer name must be valid Unicode") from None
        if len(encoded_name) > 256:
            raise PolicyError("layer name exceeds 256 UTF-8 bytes")
        seen.add(pair)
        result.append({"layerNumber": pair[0], "datatype": pair[1], "name": name})
    return result


def validate_gds_properties(layout, cells, layers):
    """Reject metadata which this GDS/native transport cannot preserve exactly.

    Visit stored owners, including compressed references, never placements.
    KLayout drops named/negative keys and stringifies typed values in GDS;
    the native reader retains at most 64 records per owner and signed INT2 keys.
    """
    from hongtu.policy import MAX_EXPANDED_SHAPES, MAX_OUTPUT_BYTES, PolicyError
    property_bytes = 0
    stored_objects = 0

    def validate(properties, owner):
        nonlocal property_bytes
        if len(properties) > 64:
            raise PolicyError(f"{owner} exceeds the 64 GDS properties per owner limit")
        for key, value in properties.items():
            if type(key) is not int or not 0 <= key <= 32767:
                raise PolicyError(f"{owner} GDS property keys must be integers in 0..32767")
            if not isinstance(value, str):
                raise PolicyError(f"{owner} GDS property values must be strings; typed values cannot be preserved")
            if '\x00' in value:
                raise PolicyError(f"{owner} GDS property strings cannot contain NUL")
            try:
                size = len(value.encode('utf-8'))
            except UnicodeError:
                raise PolicyError(f"{owner} GDS property strings must be valid Unicode") from None
            if size > 65530:
                raise PolicyError(f"{owner} GDS property string exceeds 65530 UTF-8 bytes")
            # PROPATTR header/payload plus PROPVALUE header/padded payload.
            property_bytes += 10 + size + size % 2
            if property_bytes > MAX_OUTPUT_BYTES:
                raise PolicyError("generated GDS properties exceed 8 MiB")

    validate(layout.properties_hash(layout.prop_id), 'library')
    for cell in cells:
        validate(cell.properties(), 'Cell')
        for layer in layers:
            for shape in cell.shapes(layer).each():
                stored_objects += 1
                if stored_objects > MAX_EXPANDED_SHAPES:
                    raise PolicyError("layout exceeds the 200000 stored-object bridge limit")
                validate(shape.properties(), 'shape')
        for instance in cell.each_inst():
            stored_objects += 1
            if stored_objects > MAX_EXPANDED_SHAPES:
                raise PolicyError("layout exceeds the 200000 stored-object bridge limit")
            validate(instance.properties(), 'instance')


def execute(payload, workdir):
    import klayout.db as db
    from hongtu.policy import (MAX_EXPANDED_SHAPES, MAX_OUTPUT_BYTES,
                               MAX_STDOUT_CHARS, PolicyError,
                               script_environment, validate_script, validate_request)
    from hongtu.preview import make_preview
    from hongtu.ports import prepare_ports, attach_context, capture_input_context, preserve_input_context
    validate_request(payload)
    compiled = validate_script(payload["script"])
    output = io.StringIO()

    def limited_print(*args, sep=" ", end="\n"):
        value = sep.join(str(arg) for arg in args) + end
        remaining = MAX_STDOUT_CHARS - output.tell()
        if remaining > 0:
            output.write(value[:remaining])

    env = script_environment(db, limited_print)
    # Only trusted host code can read files. Generated scripts receive geometry objects,
    # never paths or filesystem methods; all edits happen in this disposable process.
    env["params"] = dict(payload.get("parameters", {}))
    mode = payload.get("inputMode", "new")
    input_context = {None: []}
    for key, variable in (("documentGds", "source_layout"), ("selectionGds", "selection_layout")):
        if payload.get(key):
            source = Path(workdir) / (key + ".gds")
            source.write_bytes(base64.b64decode(payload[key], validate=True))
            imported = db.Layout()
            imported.read(str(source))
            if (key == 'documentGds' and mode == 'document') or (key == 'selectionGds' and mode == 'selection'):
                input_context = capture_input_context(imported, source.read_bytes())
            env[variable] = imported
    if mode != "new":
        variable = "source_layout" if mode == "document" else "selection_layout"
        env["layout"] = env[variable].dup()
        name = payload.get("currentCellName", "")
        env["current_cell"] = env["layout"].cell(name) if name else None
        if env["current_cell"] is None:
            tops = list(env["layout"].top_cells())
            env["current_cell"] = tops[0] if tops else None
    exec(compiled, env, env)
    layout = env.get("layout")
    if not isinstance(layout, db.Layout):
        raise PolicyError("script must leave its result in the variable 'layout' (Layout)")
    if not math.isfinite(layout.dbu) or layout.dbu <= 0:
        raise PolicyError("layout.dbu must be finite and positive")
    cells = list(layout.each_cell())
    layers = list(layout.layer_indexes())
    tops = list(layout.top_cells())
    if not tops or len(cells) > 2000 or len(layers) > 256 or len(tops) > 32:
        raise PolicyError("layout must have 1..32 top cells, at most 2000 cells and 256 layers")
    local_counts = {c.cell_index(): sum(c.shapes(l).size() for l in layers) for c in cells}
    total = sum(local_counts.values())
    if total > MAX_EXPANDED_SHAPES:
        raise PolicyError("layout exceeds 200000 stored shapes")
    # Preflight before writing any artifact: metadata must fit both real GDS
    # records and HongTu's native-reader contract, without silent truncation.
    validate_gds_properties(layout, cells, layers)
    port_metadata = prepare_ports(layout)
    if total <= 0 and not port_metadata['ports']:
        raise PolicyError("layout needs drawable shapes or typed port definitions")
    # Port-only layers are part of the authoritative layout, including empty ones.
    layers = list(layout.layer_indexes())
    layer_definitions = collect_layer_definitions(layout, layers)
    memo = {}

    def expanded(cell, ancestors):
        idx = cell.cell_index()
        if idx in ancestors or len(ancestors) >= 32:
            raise PolicyError("cyclic or over-32-level hierarchy is not supported")
        if idx in memo:
            return memo[idx]
        count = local_counts[idx]
        for instance in cell.each_inst():
            count += max(1, instance.na) * max(1, instance.nb) * expanded(
                layout.cell(instance.cell_index), ancestors + (idx,))
            if count > MAX_EXPANDED_SHAPES:
                raise PolicyError("layout exceeds the 200000 expanded-shape bridge limit")
        memo[idx] = count
        return count

    expanded_count = sum(expanded(c, ()) for c in tops)
    if expanded_count > MAX_EXPANDED_SHAPES:
        raise PolicyError("layout exceeds the 200000 expanded-shape bridge limit")
    review_summary = None
    if payload.get("validationProfile") == "generic_inverter":
        from hongtu.generic_cmos import validate_generic_inverter
        review_summary = validate_generic_inverter(layout, layer_definitions)
    staging = Path(workdir) / "port-staging.gds"
    target = Path(workdir) / "generated.gds"
    options = db.SaveLayoutOptions()
    options.format = "GDS2"
    options.gds2_max_vertex_count = 8000
    # HongTu's document transport already carries library and Cell properties.
    # KLayout omits these nonstandard GDS extensions by default, which would
    # silently discard existing metadata after a current-document script runs.
    # Typed ports and persisted MetaInfo use a separate real KLayout context.
    options.gds2_write_cell_properties = True
    options.gds2_write_file_properties = True
    options.write_context_info = True
    layout.write(str(staging), options)
    if staging.stat().st_size > MAX_OUTPUT_BYTES:
        raise PolicyError("generated GDS exceeds 8 MiB")
    raw = preserve_input_context(staging.read_bytes(), input_context, port_metadata)
    attach_context(port_metadata, raw)
    staging.unlink()
    svg, truncated = make_preview(layout)
    default_file_name = "python-generated.gds"
    if len(tops) == 1 and payload.get("inputMode", "new") == "new":
        top_stem = re.sub(r"[^A-Za-z0-9_.-]+", "_", tops[0].name.strip()).strip("._-")[:64]
        if top_stem and top_stem.upper() not in {"TOP", "CELL", "MAIN", "LAYOUT", "UNTITLED"}:
            default_file_name = top_stem if top_stem.lower().endswith(".gds") else f"{top_stem}.gds"
    result = {
        "success": True, "fileName": default_file_name,
        "gdsBase64": base64.b64encode(raw).decode("ascii"),
        "cellCount": len(cells), "shapeCount": total, "layerCount": len(layers),
        "layerDefinitions": layer_definitions,
        "expandedShapeCount": expanded_count, "stdout": output.getvalue(),
        "previewSvg": svg, "previewTruncated": truncated,
        "engine": "CPython + klayout.db", "engineVersion": db.__version__,
        "portMetadata": port_metadata,
    }
    if review_summary is not None:
        result["reviewSummary"] = review_summary
    if len(json.dumps(result).encode('utf8')) > 14 * 1024 * 1024:
        raise PolicyError('combined GDS/port metadata exceeds 14 MiB response budget')
    # Publish only after all geometry, typed metadata and combined budgets pass.
    target.write_bytes(raw)
    return result


def main():
    # Supervisor installs Windows Job limits before sending any input.
    from hongtu.policy import MAX_REQUEST_BYTES
    payload = json.loads(sys.stdin.buffer.readline(MAX_REQUEST_BYTES + 1))
    try:
        result = execute(payload, sys.argv[1])
    except Exception as exc:
        # No traceback, source, local paths or environment are returned.
        message = str(exc).replace(str(Path(sys.argv[1])), "<temporary-output>")
        limit = 2950 if type(exc).__name__ == "GenericInverterError" else 1200
        result = {"success": False, "error": f"{type(exc).__name__}: {message[:limit]}"}
    Path(sys.argv[1], "result.json").write_text(json.dumps(result), encoding="utf-8")


if __name__ == "__main__":
    main()
