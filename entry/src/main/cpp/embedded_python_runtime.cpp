#include "embedded_python_runtime.h"

#include "clipper_engine.h"
#include "gdsii_reader.h"
#include "gdsii_writer.h"
#include "image_export.h"
#include "scene_graph.h"
#include "vendor/pocketpy/pocketpy.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <map>
#include <mutex>
#include <set>
#include <sstream>

namespace hongtu {

namespace {

std::mutex g_pyVmMutex;
bool g_pkInitialized = false;
std::string* g_activeStdoutBuf = nullptr;
constexpr size_t kMaxStdoutChars = 65536;
constexpr int kMaxStoredShapes = 500000;

void pkPrintCallback(const char* text) {
    if (g_activeStdoutBuf == nullptr || text == nullptr) {
        return;
    }
    const size_t cur = g_activeStdoutBuf->size();
    if (cur >= kMaxStdoutChars) {
        return;
    }
    const size_t len = std::strlen(text);
    const size_t take = std::min(len, kMaxStdoutChars - cur);
    g_activeStdoutBuf->append(text, take);
}

void pkFlushCallback() {}

std::string jsonEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned int>(c));
                    out += buf;
                } else {
                    out.push_back(static_cast<char>(c));
                }
                break;
        }
    }
    return out;
}

// Probe optional full CPython 3.12 / 3.11 shared library if bundled in HAP libs
struct DynamicCPythonApi {
    void* handle = nullptr;
    std::string libName;
    const char* (*Py_GetVersion)() = nullptr;
    void (*Py_InitializeEx)(int) = nullptr;
    int (*Py_IsInitialized)() = nullptr;
    int (*PyRun_SimpleString)(const char*) = nullptr;

    bool load() {
        if (handle != nullptr) return true;
        const char* candidates[] = {
            "libpython3.13.so",
            "libpython3.12.so",
            "libpython3.11.so",
            "libpython3.so"
        };
        for (const char* name : candidates) {
            void* h = dlopen(name, RTLD_NOW | RTLD_GLOBAL);
            if (h != nullptr) {
                auto fnVer = reinterpret_cast<const char* (*)()>(dlsym(h, "Py_GetVersion"));
                auto fnInit = reinterpret_cast<void (*)(int)>(dlsym(h, "Py_InitializeEx"));
                auto fnIsInit = reinterpret_cast<int (*)()>(dlsym(h, "Py_IsInitialized"));
                auto fnRun = reinterpret_cast<int (*)(const char*)>(dlsym(h, "PyRun_SimpleString"));
                if (fnVer && fnInit && fnIsInit && fnRun) {
                    handle = h;
                    libName = name;
                    Py_GetVersion = fnVer;
                    Py_InitializeEx = fnInit;
                    Py_IsInitialized = fnIsInit;
                    PyRun_SimpleString = fnRun;
                    return true;
                }
                dlclose(h);
            }
        }
        return false;
    }
};

DynamicCPythonApi& cpythonApi() {
    static DynamicCPythonApi api;
    return api;
}

// Convert Python list of polygons `[[(x,y), ...], ...]` on PocketPy stack to Clipper Paths
bool readClipperPathsFromPy(py_Ref listRef, clipper::Paths& outPaths) {
    if (!py_islist(listRef)) {
        return TypeError("expected list of polygons");
    }
    const int polyCount = py_list_len(listRef);
    outPaths.reserve(static_cast<size_t>(polyCount));
    for (int i = 0; i < polyCount; ++i) {
        py_Ref ringRef = py_list_getitem(listRef, i);
        if (!py_islist(ringRef)) {
            return TypeError("polygon contour must be a list of [x, y] pairs");
        }
        const int ptCount = py_list_len(ringRef);
        clipper::Path path;
        path.reserve(static_cast<size_t>(ptCount));
        for (int j = 0; j < ptCount; ++j) {
            py_Ref ptRef = py_list_getitem(ringRef, j);
            py_Ref xRef = nullptr;
            py_Ref yRef = nullptr;
            if (py_islist(ptRef) && py_list_len(ptRef) >= 2) {
                xRef = py_list_getitem(ptRef, 0);
                yRef = py_list_getitem(ptRef, 1);
            } else if (py_istuple(ptRef) && py_tuple_len(ptRef) >= 2) {
                xRef = py_tuple_getitem(ptRef, 0);
                yRef = py_tuple_getitem(ptRef, 1);
            } else {
                return TypeError("point must be [x, y] or (x, y)");
            }
            double fx = 0.0;
            double fy = 0.0;
            if (!py_castfloat(xRef, &fx) || !py_castfloat(yRef, &fy)) {
                return false;
            }
            path.push_back({static_cast<int64_t>(std::llround(fx)), static_cast<int64_t>(std::llround(fy))});
        }
        if (path.size() >= 3) {
            outPaths.push_back(std::move(path));
        }
    }
    return true;
}

void writeClipperPathsToPy(const clipper::Paths& paths, py_OutRef out) {
    py_newlist(out);
    for (const auto& ring : paths) {
        if (ring.size() < 3) continue;
        py_ItemRef ringSlot = py_list_emplace(out);
        py_newlistn(ringSlot, static_cast<int>(ring.size()));
        for (size_t i = 0; i < ring.size(); ++i) {
            py_ItemRef ptSlot = py_list_getitem(ringSlot, static_cast<int>(i));
            py_newlistn(ptSlot, 2);
            py_newint(py_list_getitem(ptSlot, 0), ring[i].x);
            py_newint(py_list_getitem(ptSlot, 1), ring[i].y);
        }
    }
}

// _hongtu_native.clipper_boolean(polys_a, polys_b, op_str) -> list[list[[x,y]]]
bool nativeClipperBoolean(int argc, py_StackRef argv) {
    PY_CHECK_ARGC(3);
    PY_CHECK_ARG_TYPE(2, tp_str);
    clipper::Paths a;
    clipper::Paths b;
    if (!readClipperPathsFromPy(py_arg(0), a)) return false;
    if (!readClipperPathsFromPy(py_arg(1), b)) return false;
    const std::string opStr = py_tostr(py_arg(2));
    clipper::ClipType op = clipper::ClipType::UNION;
    if (opStr == "and" || opStr == "intersect") {
        op = clipper::ClipType::INTERSECTION;
    } else if (opStr == "sub" || opStr == "not" || opStr == "diff") {
        op = clipper::ClipType::DIFFERENCE;
    } else if (opStr == "xor") {
        op = clipper::ClipType::XOR;
    } else if (opStr == "merge") {
        clipper::Paths combined = a;
        combined.insert(combined.end(), b.begin(), b.end());
        auto merged = clipper::GeneralClipper::unite(combined);
        if (merged.approximated) {
            return RuntimeError("Clipper2 merge failed: %s", merged.note.c_str());
        }
        writeClipperPathsToPy(merged.contours, py_retval());
        return true;
    }
    auto res = clipper::GeneralClipper::executeNZ(a, b, op);
    if (res.approximated) {
        return RuntimeError("Clipper2 boolean failed: %s", res.note.c_str());
    }
    writeClipperPathsToPy(res.contours, py_retval());
    return true;
}

// _hongtu_native.clipper_offset(polys, delta_dbu) -> list[list[[x,y]]]
bool nativeClipperOffset(int argc, py_StackRef argv) {
    PY_CHECK_ARGC(2);
    clipper::Paths paths;
    if (!readClipperPathsFromPy(py_arg(0), paths)) return false;
    double delta = 0.0;
    if (!py_castfloat(py_arg(1), &delta)) return false;
    auto res = clipper::GeneralClipper::offset(paths, delta);
    if (res.approximated) {
        return RuntimeError("Clipper2 offset failed: %s", res.note.c_str());
    }
    writeClipperPathsToPy(res.contours, py_retval());
    return true;
}

// _hongtu_native.read_gds_json(path) -> str (JSON representation of GdsiiParseResult)
bool nativeReadGdsJson(int argc, py_StackRef argv) {
    PY_CHECK_ARGC(1);
    PY_CHECK_ARG_TYPE(0, tp_str);
    const std::string path = py_tostr(py_arg(0));
    GdsiiReader reader;
    GdsiiParseResult parsed = reader.parse(path, nullptr);
    if (!parsed.success) {
        return RuntimeError("read('%s') failed: %s", path.c_str(), parsed.errorMessage.c_str());
    }
    const double dbuUm = (parsed.physicalUnits > 0.0 ? parsed.physicalUnits : 1e-9) * 1e6;
    const double nmPerDbu = (parsed.physicalUnits > 0.0 ? parsed.physicalUnits : 1e-9) * 1e9;
    const double invDbu = nmPerDbu > 1e-12 ? (1.0 / nmPerDbu) : 1.0;

    std::ostringstream oss;
    oss << "{\"libName\":\"" << jsonEscape(parsed.libName) << "\","
        << "\"dbu\":" << dbuUm << ","
        << "\"cells\":[";
    for (size_t i = 0; i < parsed.cells.size(); ++i) {
        if (i > 0) oss << ",";
        oss << "\"" << jsonEscape(parsed.cells[i].name) << "\"";
    }
    oss << "],\"layers\":[";
    for (size_t i = 0; i < parsed.allLayers.size(); ++i) {
        if (i > 0) oss << ",";
        oss << "{\"layer\":" << parsed.allLayers[i].layerNumber
            << ",\"datatype\":" << parsed.allLayers[i].datatype
            << ",\"name\":\"" << jsonEscape(parsed.allLayers[i].sourceName) << "\"}";
    }
    oss << "],\"shapes\":[";
    for (size_t i = 0; i < parsed.shapes.size(); ++i) {
        const LayoutShape& s = parsed.shapes[i];
        if (i > 0) oss << ",";
        oss << "{\"type\":\"" << jsonEscape(s.type) << "\""
            << ",\"owner\":" << s.ownerCellId
            << ",\"layer\":" << s.layerNumber
            << ",\"datatype\":" << s.datatype
            << ",\"width\":" << std::llround(s.pathWidth * invDbu)
            << ",\"pathType\":" << s.pathType
            << ",\"bgnExt\":" << std::llround(s.pathBeginExtension * invDbu)
            << ",\"endExt\":" << std::llround(s.pathEndExtension * invDbu)
            << ",\"text\":\"" << jsonEscape(s.text) << "\""
            << ",\"cellId\":" << s.cellId
            << ",\"cellName\":\"" << jsonEscape(s.cellName) << "\""
            << ",\"rot\":" << s.rotation
            << ",\"mirror\":" << s.mirror
            << ",\"mag\":" << s.magnification
            << ",\"cols\":" << s.arrayCols
            << ",\"rows\":" << s.arrayRows
            << ",\"colX\":" << std::llround(s.arrayColStepX * invDbu)
            << ",\"colY\":" << std::llround(s.arrayColStepY * invDbu)
            << ",\"rowX\":" << std::llround(s.arrayRowStepX * invDbu)
            << ",\"rowY\":" << std::llround(s.arrayRowStepY * invDbu)
            << ",\"pts\":[";
        for (size_t p = 0; p < s.points.size(); ++p) {
            if (p > 0) oss << ",";
            oss << "[" << std::llround(s.points[p].x * invDbu) << ","
                << std::llround(s.points[p].y * invDbu) << "]";
        }
        oss << "]}";
    }
    oss << "]}";
    const std::string jsonStr = oss.str();
    py_newstr(py_retval(), jsonStr.c_str());
    return true;
}

// Complete KLayout/pya + HongTu Python 3 API bootstrap module
const char* kHongTuPythonBootstrap = R"PYBOOT(
import math
import json
import _hongtu_native

def _irot(x, y, rot90, mirrx):
    if mirrx:
        y = -y
    r = int(round(rot90)) % 4
    if r == 1:
        return -y, x
    if r == 2:
        return -x, -y
    if r == 3:
        return y, -x
    return x, y

class Point:
    def __init__(self, x=0, y=0):
        if isinstance(x, (Point, DPoint, Vector, DVector)):
            self.x = int(round(x.x))
            self.y = int(round(x.y))
        elif isinstance(x, (list, tuple)) and len(x) >= 2:
            self.x = int(round(x[0]))
            self.y = int(round(x[1]))
        else:
            self.x = int(round(x))
            self.y = int(round(y))
    def __add__(self, o):
        return Point(self.x + o.x, self.y + o.y)
    def __sub__(self, o):
        return Vector(self.x - o.x, self.y - o.y)
    def __repr__(self):
        return f"Point({self.x}, {self.y})"

class DPoint:
    def __init__(self, x=0.0, y=0.0):
        if isinstance(x, (Point, DPoint, Vector, DVector)):
            self.x = float(x.x)
            self.y = float(x.y)
        elif isinstance(x, (list, tuple)) and len(x) >= 2:
            self.x = float(x[0])
            self.y = float(x[1])
        else:
            self.x = float(x)
            self.y = float(y)
    def __add__(self, o):
        return DPoint(self.x + o.x, self.y + o.y)
    def __sub__(self, o):
        return DVector(self.x - o.x, self.y - o.y)
    def __repr__(self):
        return f"DPoint({self.x}, {self.y})"

class Vector(Point):
    def __mul__(self, k):
        return Vector(self.x * k, self.y * k)

class DVector(DPoint):
    def __mul__(self, k):
        return DVector(self.x * k, self.y * k)

class Trans:
    R0 = 0
    R90 = 1
    R180 = 2
    R270 = 3
    M0 = (0, True)
    M45 = (1, True)
    M90 = (2, True)
    M135 = (3, True)

    def __init__(self, a=0, b=False, c=0, d=0):
        self.rot = 0
        self.mirrx = False
        self.disp = Vector(0, 0)
        self.mag = 1.0
        self.angle_deg = 0.0
        if isinstance(a, (Vector, Point, DVector, DPoint)):
            self.disp = Vector(a.x, a.y)
        elif isinstance(a, tuple) and len(a) == 2 and isinstance(a[1], bool):
            self.rot = int(a[0]) % 4
            self.mirrx = bool(a[1])
            if isinstance(b, (Vector, Point)):
                self.disp = Vector(b.x, b.y)
            elif not isinstance(b, bool):
                self.disp = Vector(b, c)
        elif isinstance(b, bool):
            self.rot = int(a) % 4
            self.mirrx = b
            if isinstance(c, (Vector, Point)):
                self.disp = Vector(c.x, c.y)
            else:
                self.disp = Vector(c, d)
        else:
            # Trans(x, y) shorthand
            self.disp = Vector(a, b if not isinstance(b, bool) else 0)
        self.angle_deg = float(self.rot * 90)

    def transform_point(self, px, py):
        rx, ry = _irot(px * self.mag, py * self.mag, self.rot, self.mirrx)
        return int(round(rx + self.disp.x)), int(round(ry + self.disp.y))

class ICplxTrans(Trans):
    def __init__(self, mag=1.0, angle=0.0, mirrx=False, x=0, y=0):
        super().__init__(0, False, x, y)
        self.mag = float(mag)
        self.angle_deg = float(angle)
        self.rot = int(round(self.angle_deg / 90.0)) % 4
        self.mirrx = bool(mirrx)

class DCplxTrans(ICplxTrans):
    pass

class Box:
    _is_um = False
    def __init__(self, *args):
        if len(args) == 0:
            self.left = self.bottom = self.right = self.top = 0
        elif len(args) == 1 and isinstance(args[0], Box):
            b = args[0]
            self.left, self.bottom, self.right, self.top = b.left, b.bottom, b.right, b.top
        elif len(args) == 2 and isinstance(args[0], (Point, DPoint)):
            p1, p2 = args[0], args[1]
            self.left = int(round(min(p1.x, p2.x)))
            self.right = int(round(max(p1.x, p2.x)))
            self.bottom = int(round(min(p1.y, p2.y)))
            self.top = int(round(max(p1.y, p2.y)))
        elif len(args) == 2:
            w, h = int(round(args[0])), int(round(args[1]))
            self.left = -w // 2
            self.bottom = -h // 2
            self.right = self.left + w
            self.top = self.bottom + h
        else:
            x1, y1, x2, y2 = args[0], args[1], args[2], args[3]
            self.left = int(round(min(x1, x2)))
            self.right = int(round(max(x1, x2)))
            self.bottom = int(round(min(y1, y2)))
            self.top = int(round(max(y1, y2)))

    def width(self):
        return self.right - self.left
    def height(self):
        return self.top - self.bottom
    def center(self):
        return Point((self.left + self.right) // 2, (self.bottom + self.top) // 2)
    def area(self):
        return max(0, self.width()) * max(0, self.height())
    def moved(self, dx, dy=0):
        if isinstance(dx, (Vector, Point)):
            dx, dy = dx.x, dx.y
        return Box(self.left + dx, self.bottom + dy, self.right + dx, self.top + dy)
    def enlarged(self, dx, dy=None):
        if dy is None:
            dy = dx
        return Box(self.left - dx, self.bottom - dy, self.right + dx, self.top + dy)
    def to_pts(self, scale=1.0):
        l = int(round(self.left * scale))
        b = int(round(self.bottom * scale))
        r = int(round(self.right * scale))
        t = int(round(self.top * scale))
        return [[l, b], [r, b], [r, t], [l, t]]

class DBox:
    _is_um = True
    def __init__(self, *args):
        if len(args) == 2 and isinstance(args[0], (Point, DPoint)):
            p1, p2 = args[0], args[1]
            self.left, self.right = float(min(p1.x, p2.x)), float(max(p1.x, p2.x))
            self.bottom, self.top = float(min(p1.y, p2.y)), float(max(p1.y, p2.y))
        elif len(args) >= 4:
            x1, y1, x2, y2 = float(args[0]), float(args[1]), float(args[2]), float(args[3])
            self.left, self.right = min(x1, x2), max(x1, x2)
            self.bottom, self.top = min(y1, y2), max(y1, y2)
        else:
            self.left = self.bottom = self.right = self.top = 0.0
    def width(self):
        return self.right - self.left
    def height(self):
        return self.top - self.bottom
    def to_pts(self, scale=1.0):
        l = int(round(self.left * scale))
        b = int(round(self.bottom * scale))
        r = int(round(self.right * scale))
        t = int(round(self.top * scale))
        return [[l, b], [r, b], [r, t], [l, t]]

def _norm_pt(p, is_um=False):
    if isinstance(p, (Point, DPoint, Vector, DVector)):
        return [float(p.x) if is_um else int(round(p.x)), float(p.y) if is_um else int(round(p.y))]
    if isinstance(p, (list, tuple)) and len(p) >= 2:
        return [float(p[0]) if is_um else int(round(p[0])), float(p[1]) if is_um else int(round(p[1]))]
    raise TypeError("invalid point")

class Polygon:
    _is_um = False
    def __init__(self, pts=None):
        if isinstance(pts, Box):
            self._pts = pts.to_pts(1.0)
        elif pts is None:
            self._pts = []
        else:
            self._pts = [_norm_pt(p, self._is_um) for p in pts]
    def num_points(self):
        return len(self._pts)
    def each_point(self):
        return [Point(p[0], p[1]) for p in self._pts]
    def bbox(self):
        if not self._pts:
            return Box(0, 0, 0, 0)
        xs = [p[0] for p in self._pts]
        ys = [p[1] for p in self._pts]
        return Box(min(xs), min(ys), max(xs), max(ys))
    def area(self):
        n = len(self._pts)
        if n < 3:
            return 0
        s = 0
        for i in range(n):
            x1, y1 = self._pts[i]
            x2, y2 = self._pts[(i + 1) % n]
            s += x1 * y2 - x2 * y1
        return abs(s) // 2
    def moved(self, dx, dy=0):
        if isinstance(dx, (Vector, Point)):
            dx, dy = dx.x, dx.y
        return Polygon([[p[0] + dx, p[1] + dy] for p in self._pts])
    def transformed(self, tr):
        return Polygon([list(tr.transform_point(p[0], p[1])) for p in self._pts])
    def to_pts(self, scale=1.0):
        return [[int(round(p[0] * scale)), int(round(p[1] * scale))] for p in self._pts]

class SimplePolygon(Polygon):
    pass

class DPolygon(Polygon):
    _is_um = True

class Path:
    _is_um = False
    def __init__(self, pts=None, width=100, bgn_ext=0, end_ext=0, round_end=False):
        self._pts = [_norm_pt(p, self._is_um) for p in (pts or [])]
        self.width = float(width) if self._is_um else int(round(width))
        self.bgn_ext = float(bgn_ext) if self._is_um else int(round(bgn_ext))
        self.end_ext = float(end_ext) if self._is_um else int(round(end_ext))
        self.round = bool(round_end)
    def bbox(self):
        if not self._pts:
            return Box(0, 0, 0, 0)
        hw = int(round(self.width / 2))
        xs = [p[0] for p in self._pts]
        ys = [p[1] for p in self._pts]
        return Box(min(xs) - hw, min(ys) - hw, max(xs) + hw, max(ys) + hw)

class DPath(Path):
    _is_um = True

class Text:
    _is_um = False
    def __init__(self, string="", x=0, y=0):
        self.string = str(string)
        if isinstance(x, Trans):
            self.x = x.disp.x
            self.y = x.disp.y
            self.rot = x.angle_deg
        elif isinstance(x, (Point, DPoint, Vector, DVector)):
            self.x = x.x
            self.y = x.y
            self.rot = 0.0
        else:
            self.x = x
            self.y = y
            self.rot = 0.0

class DText(Text):
    _is_um = True

class LayerInfo:
    def __init__(self, layer=1, datatype=0, name=""):
        self.layer = int(layer)
        self.datatype = int(datatype)
        self.name = str(name) if name else ""

class SaveLayoutOptions:
    def __init__(self):
        self.format = "GDS2"
        self.gds2_max_vertex_count = 8000
        self.gds2_write_cell_properties = True
        self.gds2_write_file_properties = True
        self.write_context_info = True

class CellInstArray:
    _is_um = False
    def __init__(self, cell_index, trans=None, a=None, b=None, na=1, nb=1):
        if hasattr(cell_index, "cell_index"):
            self.cell_index = int(cell_index.cell_index())
        else:
            self.cell_index = int(cell_index)
        self.trans = trans if isinstance(trans, Trans) else Trans()
        self.a = a if a is not None else Vector(0, 0)
        self.b = b if b is not None else Vector(0, 0)
        self.na = max(1, int(na))
        self.nb = max(1, int(nb))
        self._props = {}
    def properties(self):
        return self._props
    def set_property(self, k, v):
        self._props[int(k)] = str(v)

class DCellInstArray(CellInstArray):
    _is_um = True

class Region:
    def __init__(self, src=None):
        self._polys = []
        if src is not None:
            self.insert(src)

    def insert(self, item):
        if isinstance(item, Region):
            for p in item._polys:
                self._polys.append([pt[:] for pt in p])
        elif isinstance(item, Shapes):
            for rec in item._items:
                if rec["type"] in ("rect", "polygon") and len(rec["pts"]) >= 3:
                    self._polys.append([pt[:] for pt in rec["pts"]])
        elif isinstance(item, (Box, DBox, Polygon, DPolygon)):
            pts = item.to_pts(1.0)
            if len(pts) >= 3:
                self._polys.append(pts)
        elif isinstance(item, (list, tuple)):
            for sub in item:
                self.insert(sub)
        return self

    def is_empty(self):
        return len(self._polys) == 0
    def count(self):
        return len(self._polys)
    def size(self):
        return len(self._polys)
    def __len__(self):
        return len(self._polys)
    def __iter__(self):
        return iter([Polygon(p) for p in self._polys])
    def each(self):
        return [Polygon(p) for p in self._polys]

    def merged(self):
        r = Region()
        if self._polys:
            r._polys = _hongtu_native.clipper_boolean(self._polys, [], "merge")
        return r
    def merge(self):
        if self._polys:
            self._polys = _hongtu_native.clipper_boolean(self._polys, [], "merge")
        return self
    def sized(self, dx, dy=None):
        r = Region()
        if self._polys:
            r._polys = _hongtu_native.clipper_offset(self._polys, float(dx))
        return r
    def __or__(self, other):
        r = Region()
        r._polys = _hongtu_native.clipper_boolean(self._polys, other._polys, "or")
        return r
    def __add__(self, other):
        return self.__or__(other)
    def __and__(self, other):
        r = Region()
        r._polys = _hongtu_native.clipper_boolean(self._polys, other._polys, "and")
        return r
    def __sub__(self, other):
        r = Region()
        r._polys = _hongtu_native.clipper_boolean(self._polys, other._polys, "sub")
        return r
    def __xor__(self, other):
        r = Region()
        r._polys = _hongtu_native.clipper_boolean(self._polys, other._polys, "xor")
        return r
    def area(self):
        total = 0
        for p in self._polys:
            total += Polygon(p).area()
        return total
    def bbox(self):
        if not self._polys:
            return Box(0, 0, 0, 0)
        xs = []
        ys = []
        for p in self._polys:
            for pt in p:
                xs.append(pt[0])
                ys.append(pt[1])
        return Box(min(xs), min(ys), max(xs), max(ys))

class _ShapeRef:
    def __init__(self, rec):
        self._rec = rec
    def properties(self):
        return self._rec.get("props", {})
    def set_property(self, k, v):
        if "props" not in self._rec:
            self._rec["props"] = {}
        self._rec["props"][int(k)] = str(v)
    def bbox(self):
        pts = self._rec.get("pts", [])
        if not pts:
            return Box(0, 0, 0, 0)
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        return Box(min(xs), min(ys), max(xs), max(ys))

class Shapes:
    def __init__(self, layout, cell_idx, layer_idx):
        self._layout = layout
        self._cell_idx = cell_idx
        self._layer_idx = layer_idx
        self._items = []

    def _um_scale(self):
        dbu = self._layout.dbu if self._layout.dbu > 0 else 0.001
        return 1.0 / dbu

    def insert(self, obj):
        scale = self._um_scale()
        if isinstance(obj, Region):
            for p in obj._polys:
                self._items.append({"type": "polygon", "pts": [pt[:] for pt in p], "props": {}})
            return None
        if isinstance(obj, (Box, DBox)):
            pts = obj.to_pts(scale if obj._is_um else 1.0)
            rec = {"type": "rect", "pts": [pts[0], pts[2]], "props": {}}
            self._items.append(rec)
            return _ShapeRef(rec)
        if isinstance(obj, (Polygon, DPolygon)):
            pts = obj.to_pts(scale if obj._is_um else 1.0)
            rec = {"type": "polygon", "pts": pts, "props": {}}
            self._items.append(rec)
            return _ShapeRef(rec)
        if isinstance(obj, (Path, DPath)):
            s = scale if obj._is_um else 1.0
            pts = [[int(round(p[0] * s)), int(round(p[1] * s))] for p in obj._pts]
            rec = {
                "type": "path",
                "pts": pts,
                "width": max(1, int(round(obj.width * s))),
                "pathType": 1 if obj.round else (4 if (obj.bgn_ext or obj.end_ext) else 0),
                "bgnExt": int(round(obj.bgn_ext * s)),
                "endExt": int(round(obj.end_ext * s)),
                "props": {}
            }
            self._items.append(rec)
            return _ShapeRef(rec)
        if isinstance(obj, (Text, DText)):
            s = scale if obj._is_um else 1.0
            rec = {
                "type": "text",
                "pts": [[int(round(obj.x * s)), int(round(obj.y * s))]],
                "text": obj.string,
                "rot": float(obj.rot),
                "props": {}
            }
            self._items.append(rec)
            return _ShapeRef(rec)
        raise TypeError(f"Unsupported shape type: {type(obj)}")

    def size(self):
        return len(self._items)
    def __len__(self):
        return len(self._items)
    def is_empty(self):
        return len(self._items) == 0
    def clear(self):
        self._items = []
    def each(self):
        return [_ShapeRef(r) for r in self._items]

class Cell:
    def __init__(self, layout, idx, name):
        self._layout = layout
        self._idx = int(idx)
        self.name = str(name)
        self._shapes_by_layer = {}
        self._insts = []
        self._props = {}
        self._ports = []

    def cell_index(self):
        return self._idx
    def shapes(self, layer_idx):
        li = int(layer_idx)
        if li not in self._shapes_by_layer:
            self._shapes_by_layer[li] = Shapes(self._layout, self._idx, li)
        return self._shapes_by_layer[li]
    def insert(self, inst):
        if not isinstance(inst, CellInstArray):
            raise TypeError("Cell.insert expects CellInstArray")
        self._insts.append(inst)
        return inst
    def each_inst(self):
        return list(self._insts)
    def properties(self):
        return self._props
    def set_property(self, k, v):
        self._props[int(k)] = str(v)
    def clear(self):
        self._shapes_by_layer = {}
        self._insts = []
    def bbox(self):
        xs, ys = [], []
        for sh in self._shapes_by_layer.values():
            for rec in sh._items:
                for pt in rec.get("pts", []):
                    xs.append(pt[0])
                    ys.append(pt[1])
        if not xs:
            return Box(0, 0, 0, 0)
        return Box(min(xs), min(ys), max(xs), max(ys))

class Layout:
    _last_created = None
    def __init__(self):
        self.dbu = 0.001
        self.prop_id = 0
        self._lib_name = "HONGTU_PY_LIB"
        self._cells = []
        self._cell_by_name = {}
        self._layers = []
        self._layer_map = {}
        self._lib_props = {}
        Layout._last_created = self

    def create_cell(self, name):
        nm = str(name)
        if nm in self._cell_by_name:
            base = nm
            k = 1
            while f"{base}_{k}" in self._cell_by_name:
                k += 1
            nm = f"{base}_{k}"
        idx = len(self._cells)
        c = Cell(self, idx, nm)
        self._cells.append(c)
        self._cell_by_name[nm] = c
        return c

    def has_cell(self, name):
        return str(name) in self._cell_by_name

    def cell(self, key):
        if isinstance(key, int):
            return self._cells[key] if 0 <= key < len(self._cells) else None
        return self._cell_by_name.get(str(key), None)

    def each_cell(self):
        return list(self._cells)

    def top_cells(self):
        referenced = set()
        for c in self._cells:
            for inst in c._insts:
                referenced.add(inst.cell_index)
        tops = [c for c in self._cells if c._idx not in referenced]
        return tops if tops else (self._cells[:1] if self._cells else [])

    def top_cell(self):
        tops = self.top_cells()
        return tops[0] if tops else None

    def layer(self, layer_or_info=1, datatype=0, name=""):
        if isinstance(layer_or_info, LayerInfo):
            ln, dt, nm = layer_or_info.layer, layer_or_info.datatype, layer_or_info.name
        else:
            ln, dt, nm = int(layer_or_info), int(datatype), str(name) if name else ""
        key = (ln, dt)
        if key in self._layer_map:
            idx = self._layer_map[key]
            if nm and not self._layers[idx].name:
                self._layers[idx].name = nm
            return idx
        idx = len(self._layers)
        self._layers.append(LayerInfo(ln, dt, nm))
        self._layer_map[key] = idx
        return idx

    def find_layer(self, layer_or_info, datatype=0):
        if isinstance(layer_or_info, LayerInfo):
            return self._layer_map.get((layer_or_info.layer, layer_or_info.datatype), None)
        return self._layer_map.get((int(layer_or_info), int(datatype)), None)

    def layer_indexes(self):
        return list(range(len(self._layers)))

    def get_info(self, layer_idx):
        return self._layers[int(layer_idx)]

    def properties_hash(self, _pid=0):
        return self._lib_props

    def read(self, path):
        raw_json = _hongtu_native.read_gds_json(str(path))
        data = json.loads(raw_json)
        self._lib_name = data.get("libName", "IMPORTED_LIB") or "IMPORTED_LIB"
        self.dbu = float(data.get("dbu", 0.001) or 0.001)
        self._cells = []
        self._cell_by_name = {}
        self._layers = []
        self._layer_map = {}
        for cname in data.get("cells", []):
            self.create_cell(cname)
        for lrec in data.get("layers", []):
            self.layer(lrec.get("layer", 0), lrec.get("datatype", 0), lrec.get("name", ""))
        for s in data.get("shapes", []):
            owner = int(s.get("owner", 0))
            if owner < 0 or owner >= len(self._cells):
                continue
            c = self._cells[owner]
            stype = s.get("type", "polygon")
            if stype == "instance":
                cid = int(s.get("cellId", -1))
                if cid < 0:
                    target_c = self.cell(s.get("cellName", ""))
                    cid = target_c._idx if target_c is not None else -1
                if cid >= 0:
                    pts = s.get("pts", [[0, 0]])
                    ox, oy = pts[0] if pts else [0, 0]
                    tr = ICplxTrans(s.get("mag", 1.0), s.get("rot", 0.0), bool(s.get("mirror", 0)), ox, oy)
                    cols = max(1, int(s.get("cols", 0) or 1))
                    rows = max(1, int(s.get("rows", 0) or 1))
                    avec = Vector(s.get("colX", 0), s.get("colY", 0))
                    bvec = Vector(s.get("rowX", 0), s.get("rowY", 0))
                    c.insert(CellInstArray(cid, tr, avec, bvec, cols, rows))
                continue
            li = self.layer(s.get("layer", 0), s.get("datatype", 0))
            pts = s.get("pts", [])
            if stype in ("rect", "box") and len(pts) >= 2:
                xs = [p[0] for p in pts]
                ys = [p[1] for p in pts]
                c.shapes(li).insert(Box(min(xs), min(ys), max(xs), max(ys)))
            elif stype == "path":
                c.shapes(li).insert(Path(pts, s.get("width", 1), s.get("bgnExt", 0), s.get("endExt", 0), s.get("pathType", 0) == 1))
            elif stype == "text" and pts:
                c.shapes(li).insert(Text(s.get("text", ""), pts[0][0], pts[0][1]))
            elif len(pts) >= 3:
                c.shapes(li).insert(Polygon(pts))
        return self

    def write(self, _path, _options=None):
        # Host C++ collects serialized layout after script execution and writes canonical GDSII
        return True

    def dup(self):
        copy = Layout()
        copy.dbu = self.dbu
        copy._lib_name = self._lib_name
        for linfo in self._layers:
            copy.layer(linfo.layer, linfo.datatype, linfo.name)
        for c in self._cells:
            nc = copy.create_cell(c.name)
            nc._props = c._props.copy()
            nc._ports = [p.copy() for p in c._ports]
        for c in self._cells:
            nc = copy._cells[c._idx]
            for li, sh in c._shapes_by_layer.items():
                target_sh = nc.shapes(li)
                for rec in sh._items:
                    target_sh._items.append({
                        "type": rec["type"],
                        "pts": [pt[:] for pt in rec.get("pts", [])],
                        "width": rec.get("width", 1),
                        "pathType": rec.get("pathType", 0),
                        "bgnExt": rec.get("bgnExt", 0),
                        "endExt": rec.get("endExt", 0),
                        "text": rec.get("text", ""),
                        "rot": rec.get("rot", 0.0),
                        "props": rec.get("props", {}).copy()
                    })
            for inst in c._insts:
                tr = ICplxTrans(inst.trans.mag, inst.trans.angle_deg, inst.trans.mirrx, inst.trans.disp.x, inst.trans.disp.y)
                nc.insert(CellInstArray(inst.cell_index, tr, Vector(inst.a.x, inst.a.y), Vector(inst.b.x, inst.b.y), inst.na, inst.nb))
        return copy

    def _to_host_dict(self):
        dbu_nm = (self.dbu if self.dbu > 0 else 0.001) * 1000.0
        cells_out = []
        shapes_out = []
        ports_out = []
        layers_out = [{"layerNumber": l.layer, "datatype": l.datatype, "name": l.name} for l in self._layers]
        for c in self._cells:
            cells_out.append(c.name)
            for p in c._ports:
                ports_out.append({
                    "ownerCellId": c._idx,
                    "name": p["name"],
                    "xNm": p["x"] * dbu_nm,
                    "yNm": p["y"] * dbu_nm,
                    "orientationDeg": p["orientation"],
                    "widthNm": p["width"] * dbu_nm,
                    "layerNumber": p["layer"],
                    "datatype": p["datatype"],
                    "portType": p["port_type"]
                })
            for li, sh in c._shapes_by_layer.items():
                linfo = self._layers[li]
                for rec in sh._items:
                    shapes_out.append({
                        "ownerCellId": c._idx,
                        "type": rec["type"],
                        "layer": linfo.layer,
                        "datatype": linfo.datatype,
                        "pts": [[pt[0] * dbu_nm, pt[1] * dbu_nm] for pt in rec.get("pts", [])],
                        "width": rec.get("width", 1) * dbu_nm,
                        "pathType": rec.get("pathType", 0),
                        "bgnExt": rec.get("bgnExt", 0) * dbu_nm,
                        "endExt": rec.get("endExt", 0) * dbu_nm,
                        "text": rec.get("text", ""),
                        "rot": rec.get("rot", 0.0)
                    })
            for inst in c._insts:
                scale_i = (1.0 / (self.dbu if self.dbu > 0 else 0.001)) if inst._is_um else 1.0
                ox = inst.trans.disp.x * scale_i * dbu_nm
                oy = inst.trans.disp.y * scale_i * dbu_nm
                shapes_out.append({
                    "ownerCellId": c._idx,
                    "type": "instance",
                    "cellId": inst.cell_index,
                    "pts": [[ox, oy]],
                    "rot": inst.trans.angle_deg,
                    "mirror": 1 if inst.trans.mirrx else 0,
                    "mag": inst.trans.mag,
                    "cols": inst.na if (inst.na > 1 or inst.nb > 1) else 0,
                    "rows": inst.nb if (inst.na > 1 or inst.nb > 1) else 0,
                    "colX": inst.a.x * scale_i * dbu_nm,
                    "colY": inst.a.y * scale_i * dbu_nm,
                    "rowX": inst.b.x * scale_i * dbu_nm,
                    "rowY": inst.b.y * scale_i * dbu_nm
                })
        tops = [c._idx for c in self.top_cells()]
        return {
            "libName": self._lib_name,
            "dbuUm": self.dbu,
            "topCellId": tops[0] if tops else 0,
            "cells": cells_out,
            "layers": layers_out,
            "shapes": shapes_out,
            "ports": ports_out
        }

def add_port(cell, name, center, width, orientation=0.0, layer=(1, 0), port_type="electrical"):
    cx, cy = (center.x, center.y) if hasattr(center, "x") else (center[0], center[1])
    ln, dt = (layer.layer, layer.datatype) if isinstance(layer, LayerInfo) else (layer[0], layer[1] if len(layer) > 1 else 0)
    cell._layout.layer(ln, dt)
    rec = {
        "name": str(name),
        "x": float(cx),
        "y": float(cy),
        "width": float(width),
        "orientation": float(orientation),
        "layer": int(ln),
        "datatype": int(dt),
        "port_type": str(port_type)
    }
    cell._ports.append(rec)
    return rec

def get_ports(cell):
    return list(cell._ports)

def update_port(cell, name, **kwargs):
    for p in cell._ports:
        if p["name"] == str(name):
            p.update(kwargs)
            return p
    raise KeyError(name)

def remove_port(cell, name):
    before = len(cell._ports)
    cell._ports = [p for p in cell._ports if p["name"] != str(name)]
    return len(cell._ports) < before

def generic_cmos_inverter(layout=None, cell_name="INVERTER", gate_length=200, nmos_width=600, pmos_width=1200):
    ly = layout if isinstance(layout, Layout) else Layout()
    ly.dbu = 0.001
    top = ly.create_cell(cell_name)
    l_nwell = ly.layer(1, 0, "NWELL")
    l_active = ly.layer(2, 0, "ACTIVE")
    l_poly = ly.layer(3, 0, "POLY")
    l_nplus = ly.layer(4, 0, "NPLUS")
    l_pplus = ly.layer(5, 0, "PPLUS")
    l_cont = ly.layer(6, 0, "CONTACT")
    l_m1 = ly.layer(7, 0, "METAL1")
    l_pin = ly.layer(8, 0, "PIN_LABEL")
    gl = max(60, int(gate_length))
    nw = max(200, int(nmos_width))
    pw = max(200, int(pmos_width))
    sd_ext = max(320, gl + 160)
    act_x0 = -gl // 2 - sd_ext
    act_x1 = gl // 2 + sd_ext
    n_y0 = 400
    n_y1 = n_y0 + nw
    p_y0 = n_y1 + 900
    p_y1 = p_y0 + pw
    top.shapes(l_nwell).insert(Box(act_x0 - 300, p_y0 - 300, act_x1 + 300, p_y1 + 600))
    top.shapes(l_active).insert(Box(act_x0, n_y0, act_x1, n_y1))
    top.shapes(l_active).insert(Box(act_x0, p_y0, act_x1, p_y1))
    top.shapes(l_nplus).insert(Box(act_x0 - 120, n_y0 - 120, act_x1 + 120, n_y1 + 120))
    top.shapes(l_pplus).insert(Box(act_x0 - 120, p_y0 - 120, act_x1 + 120, p_y1 + 120))
    top.shapes(l_poly).insert(Box(-gl // 2, n_y0 - 220, gl // 2, p_y1 + 220))
    # Contacts & Metal1 rails
    csz = 120
    src_cx = act_x0 + sd_ext // 2
    drn_cx = act_x1 - sd_ext // 2
    for cy in ((n_y0 + n_y1) // 2, (p_y0 + p_y1) // 2):
        top.shapes(l_cont).insert(Box(src_cx - csz // 2, cy - csz // 2, src_cx + csz // 2, cy + csz // 2))
        top.shapes(l_cont).insert(Box(drn_cx - csz // 2, cy - csz // 2, drn_cx + csz // 2, cy + csz // 2))
    # VSS / VDD rails + output strap + input poly contact
    vss_y = n_y0 - 480
    vdd_y = p_y1 + 480
    top.shapes(l_m1).insert(Box(act_x0 - 400, vss_y - 150, act_x1 + 400, vss_y + 150))
    top.shapes(l_m1).insert(Box(act_x0 - 400, vdd_y - 150, act_x1 + 400, vdd_y + 150))
    top.shapes(l_m1).insert(Box(src_cx - 110, vss_y, src_cx + 110, n_y1))
    top.shapes(l_m1).insert(Box(src_cx - 110, p_y0, src_cx + 110, vdd_y))
    top.shapes(l_m1).insert(Box(drn_cx - 110, n_y0, drn_cx + 110, p_y1))
    mid_y = (n_y1 + p_y0) // 2
    in_x = act_x0 - 260
    top.shapes(l_poly).insert(Box(in_x - 120, mid_y - 120, gl // 2, mid_y + 120))
    top.shapes(l_cont).insert(Box(in_x - 60, mid_y - 60, in_x + 60, mid_y + 60))
    top.shapes(l_m1).insert(Box(in_x - 140, mid_y - 140, in_x + 140, mid_y + 140))
    top.shapes(l_pin).insert(Text("IN", in_x, mid_y))
    top.shapes(l_pin).insert(Text("OUT", drn_cx, mid_y))
    top.shapes(l_pin).insert(Text("VSS", 0, vss_y))
    top.shapes(l_pin).insert(Text("VDD", 0, vdd_y))
    add_port(top, "IN", (in_x, mid_y), 240, 180.0, (7, 0))
    add_port(top, "OUT", (drn_cx, mid_y), 220, 0.0, (7, 0))
    add_port(top, "VSS", (0, vss_y), 300, 270.0, (7, 0))
    add_port(top, "VDD", (0, vdd_y), 300, 90.0, (7, 0))
    return ly, top
)PYBOOT";

const char* kHongTuExtractScript = R"PYEXTRACT(
def _hongtu_collect_result():
    import hongtu as _ht
    import json as _json
    g = globals()
    target = g["layout"] if "layout" in g else None
    if not isinstance(target, _ht.Layout):
        for cand_name in ("ly", "gds", "out_layout", "result_layout", "doc"):
            if cand_name in g and isinstance(g[cand_name], _ht.Layout):
                target = g[cand_name]
                break
    if not isinstance(target, _ht.Layout):
        target = _ht.Layout._last_created
    if not isinstance(target, _ht.Layout):
        raise RuntimeError("Python 脚本未创建或保留 Layout 对象（请赋值给变量 layout）")
    return _json.dumps(target._to_host_dict())
)PYEXTRACT";

bool readJsonNumberProp(py_Ref dictRef, const char* key, double* outVal) {
    int st = py_dict_getitem_by_str(dictRef, key);
    if (st <= 0) return false;
    py_Ref v = py_retval();
    return py_castfloat(v, outVal);
}

std::string readJsonStrProp(py_Ref dictRef, const char* key, const std::string& defVal = "") {
    int st = py_dict_getitem_by_str(dictRef, key);
    if (st <= 0) return defVal;
    py_Ref v = py_retval();
    if (py_isstr(v)) {
        return py_tostr(v);
    }
    return defVal;
}

int readJsonIntProp(py_Ref dictRef, const char* key, int defVal = 0) {
    double d = 0.0;
    if (readJsonNumberProp(dictRef, key, &d) && std::isfinite(d)) {
        return static_cast<int>(std::llround(d));
    }
    return defVal;
}

} // namespace

EmbeddedPythonRuntimeInfo EmbeddedPythonRuntime::queryInfo(const std::string& cpythonHomeDir) {
    (void)cpythonHomeDir;
    EmbeddedPythonRuntimeInfo info;
    info.available = true;
    DynamicCPythonApi& cpy = cpythonApi();
    info.hasCPython = cpy.load();
    if (info.hasCPython && cpy.Py_GetVersion != nullptr) {
        info.activeTier = "cpython-native";
        std::string rawVer = cpy.Py_GetVersion();
        const size_t nl = rawVer.find('\n');
        if (nl != std::string::npos) rawVer = rawVer.substr(0, nl);
        info.version = "CPython " + rawVer + " (" + cpy.libName + ") + PocketPy " + PK_VERSION;
        info.summary = "端侧内置双模 Python 引擎已就绪（CPython 原生动态库 + C++ Clipper2/GDSII 内核）";
    } else {
        info.activeTier = "pocketpy-native";
        info.version = std::string("PocketPy ") + PK_VERSION + " (Python 3.x C11 VM) + HongTu C++ Clipper2/GDSII";
        info.summary = "端侧内置 Python 3 引擎已就绪（无需外部桌面伴随服务，直接支持 hongtu / klayout.db / pya / Region）";
    }
    return info;
}

EmbeddedPythonResult EmbeddedPythonRuntime::execute(const EmbeddedPythonRequest& req) {
    EmbeddedPythonResult res;
    res.outputGdsPath = req.outputGdsPath;
    res.outputSvgPath = req.outputSvgPath;

    if (req.script.empty()) {
        res.errorMessage = "Python 脚本不能为空";
        return res;
    }

    std::lock_guard<std::mutex> lock(g_pyVmMutex);
    if (!g_pkInitialized) {
        py_initialize();
        g_pkInitialized = true;
    } else {
        py_resetvm();
    }

    std::string stdoutCaptured;
    g_activeStdoutBuf = &stdoutCaptured;
    py_Callbacks* cbs = py_callbacks();
    cbs->print = pkPrintCallback;
    cbs->flush = pkFlushCallback;

    struct ScopeGuard {
        ~ScopeGuard() {
            g_activeStdoutBuf = nullptr;
            if (py_checkexc()) {
                py_clearexc(nullptr);
            }
        }
    } guard;

    // 1. Register _hongtu_native C bindings
    py_GlobalRef nativeMod = py_newmodule("_hongtu_native");
    py_bindfunc(nativeMod, "clipper_boolean", nativeClipperBoolean);
    py_bindfunc(nativeMod, "clipper_offset", nativeClipperOffset);
    py_bindfunc(nativeMod, "read_gds_json", nativeReadGdsJson);

    // 2. Bootstrap hongtu module and alias klayout / klayout.db / pya
    py_GlobalRef hongtuMod = py_newmodule("hongtu");
    if (!py_exec(kHongTuPythonBootstrap, "<hongtu_bootstrap>", EXEC_MODE, hongtuMod)) {
        char* exc = py_formatexc();
        res.errorMessage = std::string("初始化内置 Python 模块失败: ") + (exc ? exc : "unknown");
        if (exc) py_free(exc);
        return res;
    }

    py_GlobalRef pyaMod = py_newmodule("pya");
    py_GlobalRef klMod = py_newmodule("klayout");
    py_GlobalRef kldbMod = py_newmodule("klayout.db");
    py_GlobalRef cmosMod = py_newmodule("hongtu.generic_cmos");
    py_GlobalRef portsMod = py_newmodule("hongtu.ports");
    const bool aliasOk =
        py_exec("from hongtu import *\n", "<pya>", EXEC_MODE, pyaMod) &&
        py_exec("from hongtu import *\nimport klayout.db as db\n", "<klayout>", EXEC_MODE, klMod) &&
        py_exec("from hongtu import *\n", "<klayout.db>", EXEC_MODE, kldbMod) &&
        py_exec("from hongtu import generic_cmos_inverter\n", "<cmos>", EXEC_MODE, cmosMod) &&
        py_exec("from hongtu import add_port, get_ports, update_port, remove_port\n", "<ports>", EXEC_MODE, portsMod) &&
        py_exec("import hongtu\nhongtu.__version__ = '0.4.0-ohos-native'\nhongtu.db = hongtu\n", "<hongtu_aliases>", EXEC_MODE, nullptr);
    if (!aliasOk) {
        char* exc = py_formatexc();
        res.errorMessage = std::string("注册 klayout.db/pya 别名失败: ") + (exc ? exc : "unknown");
        if (exc) py_free(exc);
        return res;
    }

    // 3. Inject parameters (`params` and `PARAMETERS`) + optional source/selection GDS layouts
    std::ostringstream preExec;
    preExec << "import json as _ht_json, hongtu as _ht_db\n"
            << "params = _ht_json.loads(" << "\"" << jsonEscape(req.parametersJson.empty() ? "{}" : req.parametersJson) << "\")\n"
            << "PARAMETERS = params.copy()\n";
    if (!req.sourceGdsPath.empty()) {
        preExec << "source_layout = _ht_db.Layout().read(\"" << jsonEscape(req.sourceGdsPath) << "\")\n";
    }
    if (!req.selectionGdsPath.empty()) {
        preExec << "selection_layout = _ht_db.Layout().read(\"" << jsonEscape(req.selectionGdsPath) << "\")\n";
    }
    if (req.inputMode == "document" && !req.sourceGdsPath.empty()) {
        preExec << "layout = source_layout.dup()\n";
        if (!req.currentCellName.empty()) {
            preExec << "current_cell = layout.cell(\"" << jsonEscape(req.currentCellName) << "\") or layout.top_cell()\n";
        } else {
            preExec << "current_cell = layout.top_cell()\n";
        }
    } else if (req.inputMode == "selection" && !req.selectionGdsPath.empty()) {
        preExec << "layout = selection_layout.dup()\n"
                << "current_cell = layout.top_cell()\n";
    }

    if (!py_exec(preExec.str().c_str(), "<hongtu_env>", EXEC_MODE, nullptr)) {
        char* exc = py_formatexc();
        res.errorMessage = std::string("准备版图输入上下文失败: ") + (exc ? exc : "unknown");
        if (exc) py_free(exc);
        return res;
    }

    // 4. Execute user / Agent script with watchdog protection if enabled
#if PK_ENABLE_WATCHDOG
    const int64_t budgetMs = std::max<int64_t>(1000, std::min<int64_t>(120000, req.timeoutMs));
    py_watchdog_begin(budgetMs);
#endif
    const bool execOk = py_exec(req.script.c_str(), "layout_script.py", EXEC_MODE, nullptr);
#if PK_ENABLE_WATCHDOG
    py_watchdog_end();
#endif

    res.stdoutText = stdoutCaptured;
    if (!execOk) {
        char* exc = py_formatexc();
        res.errorMessage = exc ? std::string(exc) : "Python 脚本运行异常";
        if (exc) py_free(exc);
        return res;
    }

    // 5. Extract resulting Layout object into structured C++ GdsiiParseResult
    if (!py_exec(kHongTuExtractScript, "<hongtu_extract>", EXEC_MODE, nullptr) ||
        !py_eval("_hongtu_collect_result()", nullptr)) {
        char* exc = py_formatexc();
        res.errorMessage = exc ? std::string(exc) : "提取 Python 生成的 Layout 对象失败";
        if (exc) py_free(exc);
        return res;
    }

    if (!py_isstr(py_retval())) {
        res.errorMessage = "内部错误：Layout 序列化未返回 JSON 字符串";
        return res;
    }
    const std::string hostJson = py_tostr(py_retval());
    if (!py_json_loads(hostJson.c_str())) {
        char* exc = py_formatexc();
        res.errorMessage = std::string("解析脚本输出几何失败: ") + (exc ? exc : "unknown");
        if (exc) py_free(exc);
        return res;
    }

    // Store root dict in register r0 so nested dict/list lookups never clobber it
    py_setreg(0, py_retval());
    py_Ref root = py_r0();

    GdsiiParseResult outLayout;
    outLayout.success = true;
    outLayout.version = 600;
    outLayout.libName = readJsonStrProp(root, "libName", "HONGTU_PY_LIB");
    double dbuUm = 0.001;
    readJsonNumberProp(root, "dbuUm", &dbuUm);
    if (!std::isfinite(dbuUm) || dbuUm <= 0.0) dbuUm = 0.001;
    outLayout.userUnits = dbuUm;
    outLayout.physicalUnits = dbuUm * 1e-6;
    outLayout.primaryTopCellId = readJsonIntProp(root, "topCellId", 0);

    // Cells
    if (py_dict_getitem_by_str(root, "cells") > 0 && py_islist(py_retval())) {
        py_setreg(1, py_retval());
        const int nCells = py_list_len(py_r1());
        for (int i = 0; i < nCells; ++i) {
            py_Ref cNameRef = py_list_getitem(py_r1(), i);
            CellInfo ci;
            ci.name = py_isstr(cNameRef) ? py_tostr(cNameRef) : ("CELL_" + std::to_string(i));
            outLayout.cells.push_back(ci);
            res.cellNames.push_back(ci.name);
        }
    }
    if (outLayout.cells.empty()) {
        res.errorMessage = "Python 脚本生成的 Layout 不包含任何 Cell";
        return res;
    }
    if (outLayout.primaryTopCellId < 0 || outLayout.primaryTopCellId >= static_cast<int>(outLayout.cells.size())) {
        outLayout.primaryTopCellId = 0;
    }
    outLayout.cellCount = static_cast<int>(outLayout.cells.size());

    // Layer definitions
    std::map<std::pair<int, int>, int> layerElemCounts;
    if (py_dict_getitem_by_str(root, "layers") > 0 && py_islist(py_retval())) {
        py_setreg(1, py_retval());
        const int nLayers = py_list_len(py_r1());
        for (int i = 0; i < nLayers; ++i) {
            py_setreg(2, py_list_getitem(py_r1(), i));
            const int ln = readJsonIntProp(py_r2(), "layerNumber", 0);
            const int dt = readJsonIntProp(py_r2(), "datatype", 0);
            const std::string nm = readJsonStrProp(py_r2(), "name", "");
            res.layerDefinitions.push_back({ln, dt, nm});
            layerElemCounts[{ln, dt}] = 0;
        }
    }

    // Shapes
    int nextShapeId = 1;
    if (py_dict_getitem_by_str(root, "shapes") > 0 && py_islist(py_retval())) {
        py_setreg(1, py_retval());
        const int nShapes = py_list_len(py_r1());
        if (nShapes > kMaxStoredShapes) {
            res.errorMessage = "脚本生成图元数量超出单次 500,000 上限";
            return res;
        }
        outLayout.shapes.reserve(static_cast<size_t>(nShapes));
        for (int i = 0; i < nShapes; ++i) {
            py_setreg(2, py_list_getitem(py_r1(), i));
            LayoutShape s;
            s.id = nextShapeId++;
            s.type = readJsonStrProp(py_r2(), "type", "polygon");
            s.ownerCellId = readJsonIntProp(py_r2(), "ownerCellId", outLayout.primaryTopCellId);
            s.layerNumber = readJsonIntProp(py_r2(), "layer", 1);
            s.datatype = readJsonIntProp(py_r2(), "datatype", 0);
            double w = 1.0;
            if (readJsonNumberProp(py_r2(), "width", &w)) s.pathWidth = w;
            s.pathType = readJsonIntProp(py_r2(), "pathType", 0);
            double bExt = 0.0, eExt = 0.0;
            if (readJsonNumberProp(py_r2(), "bgnExt", &bExt)) s.pathBeginExtension = bExt;
            if (readJsonNumberProp(py_r2(), "endExt", &eExt)) s.pathEndExtension = eExt;
            s.text = readJsonStrProp(py_r2(), "text", "");
            double rot = 0.0;
            if (readJsonNumberProp(py_r2(), "rot", &rot)) s.rotation = rot;

            if (s.type == "instance") {
                s.cellId = readJsonIntProp(py_r2(), "cellId", 0);
                if (s.cellId >= 0 && s.cellId < static_cast<int>(outLayout.cells.size())) {
                    s.cellName = outLayout.cells[static_cast<size_t>(s.cellId)].name;
                }
                s.mirror = readJsonIntProp(py_r2(), "mirror", 0);
                double mag = 1.0;
                if (readJsonNumberProp(py_r2(), "mag", &mag) && mag > 0.0) s.magnification = mag;
                s.arrayCols = readJsonIntProp(py_r2(), "cols", 0);
                s.arrayRows = readJsonIntProp(py_r2(), "rows", 0);
                readJsonNumberProp(py_r2(), "colX", &s.arrayColStepX);
                readJsonNumberProp(py_r2(), "colY", &s.arrayColStepY);
                readJsonNumberProp(py_r2(), "rowX", &s.arrayRowStepX);
                readJsonNumberProp(py_r2(), "rowY", &s.arrayRowStepY);
            } else {
                layerElemCounts[{s.layerNumber, s.datatype}]++;
            }

            if (py_dict_getitem_by_str(py_r2(), "pts") > 0 && py_islist(py_retval())) {
                py_setreg(3, py_retval());
                const int nPts = py_list_len(py_r3());
                s.points.reserve(static_cast<size_t>(nPts));
                for (int p = 0; p < nPts; ++p) {
                    py_Ref ptItem = py_list_getitem(py_r3(), p);
                    if (py_islist(ptItem) && py_list_len(ptItem) >= 2) {
                        double px = 0.0, pyVal = 0.0;
                        py_castfloat(py_list_getitem(ptItem, 0), &px);
                        py_castfloat(py_list_getitem(ptItem, 1), &pyVal);
                        s.points.push_back({px, pyVal});
                    }
                }
            }
            if (s.ownerCellId >= 0 && s.ownerCellId < static_cast<int>(outLayout.cells.size())) {
                outLayout.cells[static_cast<size_t>(s.ownerCellId)].elementCount++;
            }
            outLayout.shapes.push_back(std::move(s));
        }
    }

    // Ports
    if (py_dict_getitem_by_str(root, "ports") > 0 && py_islist(py_retval())) {
        py_setreg(1, py_retval());
        const int nPorts = py_list_len(py_r1());
        for (int i = 0; i < nPorts; ++i) {
            py_setreg(2, py_list_getitem(py_r1(), i));
            EmbeddedPythonPortDef port;
            port.id = "py_port_" + std::to_string(i + 1);
            port.ownerCellId = readJsonIntProp(py_r2(), "ownerCellId", outLayout.primaryTopCellId);
            if (port.ownerCellId >= 0 && port.ownerCellId < static_cast<int>(outLayout.cells.size())) {
                port.ownerCellKey = outLayout.cells[static_cast<size_t>(port.ownerCellId)].name;
            }
            port.name = readJsonStrProp(py_r2(), "name", "PORT");
            readJsonNumberProp(py_r2(), "xNm", &port.xNm);
            readJsonNumberProp(py_r2(), "yNm", &port.yNm);
            readJsonNumberProp(py_r2(), "orientationDeg", &port.orientationDeg);
            readJsonNumberProp(py_r2(), "widthNm", &port.widthNm);
            port.layerNumber = readJsonIntProp(py_r2(), "layerNumber", 1);
            port.datatype = readJsonIntProp(py_r2(), "datatype", 0);
            port.portType = readJsonStrProp(py_r2(), "portType", "electrical");
            res.ports.push_back(port);
        }
    }

    if (outLayout.shapes.empty() && res.ports.empty()) {
        res.errorMessage = "Python 脚本未向任何 Cell 插入几何图形或端口";
        return res;
    }

    for (const auto& kv : layerElemCounts) {
        LayerInfo li;
        li.layerNumber = kv.first.first;
        li.datatype = kv.first.second;
        li.elementCount = kv.second;
        for (const auto& def : res.layerDefinitions) {
            if (def.layerNumber == li.layerNumber && def.datatype == li.datatype && !def.name.empty()) {
                li.sourceName = def.name;
                break;
            }
        }
        outLayout.allLayers.push_back(li);
    }
    outLayout.layerCount = static_cast<int>(outLayout.allLayers.size());
    outLayout.totalElements = static_cast<int>(outLayout.shapes.size());

    // Derive sensible output filename from top cell
    const std::string topName = outLayout.cells[static_cast<size_t>(outLayout.primaryTopCellId)].name;
    std::string cleanStem;
    for (char c : topName) {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
            cleanStem.push_back(c);
        }
    }
    if (!cleanStem.empty() && cleanStem != "TOP" && cleanStem != "MAIN") {
        res.fileName = cleanStem + ".gds";
    }

    // 6. Write canonical GDSII to outputGdsPath (if requested)
    if (!req.outputGdsPath.empty()) {
        GdsiiWriteResult wr = WriteGdsii(outLayout, req.outputGdsPath);
        if (!wr.success) {
            res.errorMessage = "写出 GDSII 失败: " + wr.errorMessage;
            return res;
        }
        res.gdsBytes = wr.bytes;
    } else {
        std::vector<uint8_t> memBuf;
        GdsiiWriteResult wr = WriteGdsiiToBuffer(outLayout, memBuf);
        if (!wr.success) {
            res.errorMessage = "编码 GDSII 失败: " + wr.errorMessage;
            return res;
        }
        res.gdsBytes = wr.bytes;
    }

    // 7. Build temporary scene graph to compute expanded count & render SVG preview
    Layout sceneLayout;
    for (size_t i = 0; i < outLayout.cells.size(); ++i) {
        sceneLayout.addCellWithId(static_cast<int>(i), outLayout.cells[i].name);
    }
    sceneLayout.setTopCell(outLayout.primaryTopCellId);
    static const uint32_t kDefaultPalette[] = {
        0xFF3B82F6u, 0xFF10B981u, 0xFFF59E0Bu, 0xFFEF4444u,
        0xFF8B5CF6u, 0xFF06B6D4u, 0xFFEC4899u, 0xFF6366F1u
    };
    size_t colorIdx = 0;
    for (const auto& li : outLayout.allLayers) {
        LayerProperties lp;
        lp.key = {static_cast<int16_t>(li.layerNumber), static_cast<int16_t>(li.datatype)};
        lp.name = li.sourceName;
        lp.fillColor = kDefaultPalette[colorIdx % 8];
        lp.lineColor = kDefaultPalette[colorIdx % 8];
        lp.transparency = 0.35f;
        lp.visible = true;
        sceneLayout.layerProps[lp.key] = lp;
        ++colorIdx;
    }
    int expandedApprox = 0;
    for (const auto& ls : outLayout.shapes) {
        if (ls.type == "instance") {
            CellInstance ci{};
            ci.id = ls.id;
            ci.referencedCellId = ls.cellId;
            ci.referencedCellName = ls.cellName;
            ci.ownerCellId = ls.ownerCellId;
            if (!ls.points.empty()) {
                ci.transform.x = ls.points[0].x;
                ci.transform.y = ls.points[0].y;
            }
            ci.transform.rotation = ls.rotation;
            ci.transform.mirrorX = (ls.mirror != 0);
            ci.transform.magnification = ls.magnification;
            ci.transform.arrayCols = ls.arrayCols;
            ci.transform.arrayRows = ls.arrayRows;
            ci.transform.arrayPitchX = ls.arrayColStepX;
            ci.transform.arrayColStepY = ls.arrayColStepY;
            ci.transform.arrayRowStepX = ls.arrayRowStepX;
            ci.transform.arrayPitchY = ls.arrayRowStepY;
            sceneLayout.addInstance(ci);
            expandedApprox += std::max(1, ls.arrayCols) * std::max(1, ls.arrayRows);
        } else {
            SceneShape ss{};
            ss.id = ls.id;
            ss.ownerCellId = ls.ownerCellId;
            ss.layerKey = {static_cast<int16_t>(ls.layerNumber), static_cast<int16_t>(ls.datatype)};
            ss.pathWidth = ls.pathWidth;
            ss.pathType = ls.pathType;
            ss.pathBeginExtension = ls.pathBeginExtension;
            ss.pathEndExtension = ls.pathEndExtension;
            ss.text = ls.text;
            ss.textRotation = ls.rotation;
            if (ls.type == "rect" || ls.type == "box") ss.type = ShapeType::RECT;
            else if (ls.type == "path") ss.type = ShapeType::PATH;
            else if (ls.type == "text") ss.type = ShapeType::TEXT;
            else ss.type = ShapeType::POLYGON;
            for (const auto& pt : ls.points) {
                ss.points.push_back(Vec2(pt.x, pt.y));
            }
            sceneLayout.addShape(ss, Layout::SpatialIndexBuild::Deferred);
            expandedApprox++;
        }
    }

    SvgExporter::ExportOptions svgOpts;
    svgOpts.maxWidth = 640;
    svgOpts.maxHeight = 480;
    svgOpts.darkBackground = false;
    svgOpts.title = topName;
    res.previewSvg = SvgExporter::exportSvg(sceneLayout, svgOpts);
    if (!req.outputSvgPath.empty() && !res.previewSvg.empty()) {
        std::ofstream svgOut(req.outputSvgPath, std::ios::out | std::ios::binary | std::ios::trunc);
        if (svgOut) {
            svgOut.write(res.previewSvg.data(), static_cast<std::streamsize>(res.previewSvg.size()));
        }
    }

    res.success = true;
    res.engineTier = cpythonApi().load() ? "cpython-native" : "pocketpy-native";
    res.engineVersion = std::string("PocketPy ") + PK_VERSION + " + HongTu C++ Clipper2/GDSII";
    res.cellCount = outLayout.cellCount;
    res.shapeCount = outLayout.totalElements;
    res.expandedShapeCount = std::max(res.shapeCount, expandedApprox);
    res.layerCount = outLayout.layerCount;
    return res;
}

} // namespace hongtu
