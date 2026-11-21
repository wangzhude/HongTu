"""Deliberately narrow policy for generated code; not an OS security sandbox."""
import ast
import base64
import binascii
import math
import types

MAX_SCRIPT_BYTES = 64 * 1024
MAX_AST_NODES = 12000
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
MAX_STDOUT_CHARS = 16000
MAX_EXPANDED_SHAPES = 200000
MAX_PREVIEW_SHAPES = 3000
MAX_PREVIEW_CHARS = 1500000
TIMEOUT_SECONDS = 15
MEMORY_BYTES = 768 * 1024 * 1024
MAX_REQUEST_BYTES = 23 * 1024 * 1024

CLASS_NAMES = frozenset("""
Layout Cell Box DBox Polygon DPolygon SimplePolygon DSimplePolygon Path DPath
Point DPoint Vector DVector Region Trans DTrans CplxTrans DCplxTrans ICplxTrans
CellInstArray DCellInstArray Text DText LayerInfo Edge DEdge Edges EdgePairs
""".split())
MATH_NAMES = frozenset("""
pi tau e sin cos tan asin acos atan atan2 sqrt hypot floor ceil radians degrees
fabs fmod exp log log10 isfinite trunc copysign
""".split())
METHOD_NAMES = frozenset("""
create_cell cell cell_index cell_by_name cells each_cell top_cell top_cells
layer layer_indexes layer_infos get_info shapes insert insert_hole holes
each_point_hull each_point_hole each_point each each_inst each_shape
begin_shapes_rec begin_shapes_rec_touching begin_shapes_rec_overlapping
each_overlapping each_touching bbox dbbox is_empty size count area perimeter
merged merge sized size_inside size_outside moved move transformed transform
rotated scaled dup assign clear flatten copy_tree copy_shapes copy_instances
width height center left right top bottom x y p1 p2 length distance abs
to_itype to_dtype to_polygon polygon resolved_holes simple_polygon is_box
is_polygon is_path is_text is_valid box path text name dbu datatype layer
trans dtrans cplx_trans dcplx_trans a b na nb is_regular_array
R0 R90 R180 R270 M0 M45 M90 M135 mirror angle mag disp
round_corners smoothed with_area with_perimeter interacting not_interacting
overlapping not_overlapping touching not_touching selected_not_interacting
select_inside select_outside select_interacting select_not_interacting
set_property property delete_property properties texts edges polygons
append extend add update copy items keys values get pop reverse sort
""".split())
HELPER_NAMES = frozenset({"generic_cmos_inverter", "add_port", "get_ports", "update_port", "remove_port"})
ALLOWED_ATTRS = CLASS_NAMES | MATH_NAMES | METHOD_NAMES | HELPER_NAMES | {"db"}
SAFE_BUILTINS = {
    "abs": abs, "min": min, "max": max, "round": round,
    "int": int, "float": float, "str": str, "bool": bool,
    "len": len, "sum": sum, "enumerate": enumerate, "zip": zip,
    "list": list, "tuple": tuple, "dict": dict, "set": set,
    "sorted": sorted, "reversed": reversed, "all": all, "any": any,
}


class PolicyError(ValueError):
    pass


def validate_request(payload):
    """Validate bounded data inputs separately from generated executable code."""
    allowed = {"script", "inputMode", "documentGds", "selectionGds", "currentCellName", "parameters", "validationProfile"}
    if not isinstance(payload, dict) or set(payload) - allowed or "script" not in payload:
        raise PolicyError("expected script and optional layout/parameter inputs")
    validate_script(payload["script"])
    mode = payload.get("inputMode", "new")
    if not isinstance(mode, str) or mode not in {"new", "document", "selection"}:
        raise PolicyError("inputMode must be new, document or selection")
    profile = payload.get("validationProfile", "")
    if not isinstance(profile, str) or profile not in {"", "generic_inverter"}:
        raise PolicyError("validationProfile must be empty or generic_inverter")
    if profile and (mode != "new" or payload.get("documentGds") or payload.get("selectionGds")):
        raise PolicyError("generic_inverter validationProfile only accepts new layouts without input snapshots")
    for key in ("documentGds", "selectionGds"):
        value = payload.get(key, "")
        if not isinstance(value, str) or len(value) > 4 * ((MAX_OUTPUT_BYTES + 2) // 3):
            raise PolicyError(f"{key} exceeds 8 MiB")
        if value:
            try:
                raw = base64.b64decode(value, validate=True)
            except (ValueError, binascii.Error):
                raise PolicyError(f"{key} must be base64 GDSII") from None
            if len(raw) > MAX_OUTPUT_BYTES or not raw.startswith(b"\x00\x06\x00\x02"):
                raise PolicyError(f"{key} must be a bounded GDSII file")
    if mode == "document" and not payload.get("documentGds"):
        raise PolicyError("current document snapshot is required")
    if mode == "selection" and not payload.get("selectionGds"):
        raise PolicyError("selection snapshot is required")
    name = payload.get("currentCellName", "")
    if not isinstance(name, str) or len(name) > 256:
        raise PolicyError("currentCellName is invalid")
    params = payload.get("parameters", {})
    if not isinstance(params, dict) or len(params) > 64:
        raise PolicyError("parameters must contain at most 64 named values")
    for key, value in params.items():
        if not isinstance(key, str) or not key.isidentifier() or key.startswith("_") or len(key) > 64:
            raise PolicyError("parameter names must be public identifiers")
        if type(value) not in {int, float, str, bool}:
            raise PolicyError("parameters must be numbers, strings or booleans")
        if isinstance(value, (int, float)) and (abs(value) > 1e12 or not math.isfinite(value)):
            raise PolicyError("parameter number exceeds supported bounds")
        if isinstance(value, str) and len(value) > 4096:
            raise PolicyError("parameter string exceeds 4096 characters")
    return payload


def bounded_range(*args):
    result = range(*args)
    if len(result) > 100000:
        raise PolicyError("range is limited to 100000 iterations")
    return result


_NODE_NAMES = """
Module Import ImportFrom alias Assign AnnAssign AugAssign Expr For If IfExp
FunctionDef arguments arg Return
List Tuple Dict Set ListComp SetComp DictComp GeneratorExp comprehension
Call Name Load Store Attribute Subscript Slice Constant BinOp UnaryOp Compare
BoolOp keyword Pass Break Continue JoinedStr FormattedValue
Add Sub Mult Div FloorDiv Mod BitOr BitAnd BitXor LShift RShift
UAdd USub Not Invert Eq NotEq Lt LtE Gt GtE In NotIn Is IsNot And Or
""".split()
ALLOWED_NODES = tuple(getattr(ast, n) for n in _NODE_NAMES)


def validate_script(script):
    if not isinstance(script, str) or not script.strip():
        raise PolicyError("script must be a non-empty Python string")
    if len(script.encode("utf-8")) > MAX_SCRIPT_BYTES:
        raise PolicyError("script exceeds 64 KiB")
    try:
        tree = ast.parse(script, filename="<hongtu-ai>", mode="exec")
    except SyntaxError as exc:
        raise PolicyError(f"Python syntax error on line {exc.lineno}: {exc.msg}") from None
    nodes = list(ast.walk(tree))
    if len(nodes) > MAX_AST_NODES:
        raise PolicyError("script AST is too large")
    for node in nodes:
        if not isinstance(node, ALLOWED_NODES):
            raise PolicyError(f"{type(node).__name__} is not enabled for AI scripts")
        if isinstance(node, ast.Name) and node.id.startswith("_"):
            raise PolicyError("private names are not allowed")
        if isinstance(node, ast.FunctionDef) and (node.name.startswith("_") or node.decorator_list):
            raise PolicyError("private functions and decorators are not enabled")
        if isinstance(node, ast.arg) and node.arg.startswith("_"):
            raise PolicyError("private argument names are not allowed")
        if isinstance(node, ast.Attribute) and node.attr not in ALLOWED_ATTRS:
            raise PolicyError(f"attribute '{node.attr}' is not in the geometry API allowlist")
        if isinstance(node, ast.Import):
            for item in node.names:
                if item.name not in {"hongtu", "klayout.db", "math"}:
                    raise PolicyError(f"import '{item.name}' is not allowed")
                if item.asname and item.asname.startswith("_"):
                    raise PolicyError("private import aliases are not allowed")
        if isinstance(node, ast.ImportFrom):
            if node.level or node.module not in {"hongtu", "klayout.db", "math"}:
                raise PolicyError("only hongtu, klayout.db and math imports are allowed")
            allowed = MATH_NAMES if node.module == "math" else CLASS_NAMES | HELPER_NAMES | {"db"}
            for item in node.names:
                if item.name != "*" and item.name not in allowed:
                    raise PolicyError(f"import name '{item.name}' is not allowed")
                if item.asname and item.asname.startswith("_"):
                    raise PolicyError("private import aliases are not allowed")
        if isinstance(node, ast.Call) and any(k.arg is None for k in node.keywords):
            raise PolicyError("keyword expansion is not enabled")
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
            if not math.isfinite(node.value) or abs(node.value) > 1e12:
                raise PolicyError("numeric literal is outside the supported range")
    try:
        return compile(tree, "<hongtu-ai>", "exec")
    except SyntaxError as exc:
        raise PolicyError(f"Python syntax error on line {exc.lineno}: {exc.msg}") from None


def script_environment(db, print_fn):
    from hongtu.generic_cmos import generic_cmos_inverter
    from hongtu.ports import add_port, get_ports, update_port, remove_port
    geometry = types.ModuleType("hongtu")
    for name in CLASS_NAMES:
        setattr(geometry, name, getattr(db, name))
    geometry.db = geometry
    geometry.generic_cmos_inverter = generic_cmos_inverter
    geometry.add_port = add_port
    geometry.get_ports = get_ports
    geometry.update_port = update_port
    geometry.remove_port = remove_port
    geometry.__all__ = sorted(CLASS_NAMES | HELPER_NAMES)
    maths = types.ModuleType("math")
    for name in MATH_NAMES:
        setattr(maths, name, getattr(math, name))
    maths.__all__ = sorted(MATH_NAMES)
    klayout = types.ModuleType("klayout")
    klayout.db = geometry

    def allowed_import(name, globals=None, locals=None, fromlist=(), level=0):
        if level:
            raise PolicyError("relative imports are disabled")
        if name == "math":
            return maths
        if name == "hongtu":
            return geometry
        if name == "klayout.db":
            return geometry if fromlist else klayout
        raise PolicyError("import is not allowed")

    builtins = dict(SAFE_BUILTINS, range=bounded_range, print=print_fn)
    builtins["__import__"] = allowed_import
    return {"__builtins__": builtins}
