#!/usr/bin/env python3
"""Deterministic hierarchical geometry benchmarks, NOT electrical/mask designs.

Requires klayout==0.30.12 (the project's python/.venv already supplies it).
All cell geometry is original synthetic test material. No external PDK cell is
embedded, so there is no implied process-rule or transistor-model compatibility.

Example:
  python/.venv/Scripts/python.exe python/benchmarks/generate_complex_layouts.py
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import random
import shutil
import time
import xml.etree.ElementTree as ET

import klayout.db as db

REPO = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = REPO / "artifacts" / "complex-layout-20260930"
TARGETS = {"small": 10_000, "medium": 100_000, "large": 500_000}
SEEDS = {"sram": 20260930, "processor": 20260931}
LAYERS = {
    "nwell": (64, 20, "#ae7cc5"), "active": (65, 20, "#62bd83"),
    "poly": (66, 20, "#e06b76"), "contact": (66, 44, "#33546c"),
    "local": (67, 20, "#ad8b5a"), "local_pin": (67, 44, "#e2ba70"),
    "via1": (67, 40, "#275c7d"), "metal1": (68, 20, "#4c99ce"),
    "metal1_pin": (68, 16, "#90d5f0"), "via2": (68, 44, "#254f94"),
    "metal2": (69, 20, "#9273c5"), "via3": (69, 44, "#6b448f"),
    "metal3": (70, 20, "#c38c50"), "via4": (70, 44, "#a8593c"),
    "metal4": (71, 20, "#44aaa3"), "metal5": (72, 20, "#9f7cd0"),
    "pad": (76, 20, "#ba8c42"), "boundary": (235, 4, "#afb7c4"),
    "label": (200, 5, "#c7cfda"),
}
DISCLAIMER = "Synthetic geometry/tool stress fixture; NOT a functional circuit, PDK-compliant layout, or manufacturable mask."


class Builder:
    def __init__(self, seed: int):
        self.layout = db.Layout()
        self.layout.dbu = 0.001  # micrometres/DBU: every coordinate below is integer nm
        self.rng = random.Random(seed)
        self.layers = {name: self.layout.layer(db.LayerInfo(layer, datatype, name))
                       for name, (layer, datatype, _) in LAYERS.items()}

    def cell(self, name):
        return self.layout.create_cell(name)

    def box(self, cell, layer, x, y, w, h):
        assert w > 0 and h > 0
        cell.shapes(self.layers[layer]).insert(db.Box(int(x), int(y), int(x+w), int(y+h)))

    def path(self, cell, layer, points, width):
        cell.shapes(self.layers[layer]).insert(db.Path([db.Point(int(x), int(y)) for x, y in points], int(width)))

    def label(self, cell, text, x, y):
        cell.shapes(self.layers["label"]).insert(db.Text(text, db.Trans(int(x), int(y))))

    def polygon(self, cell, layer, points):
        cell.shapes(self.layers[layer]).insert(db.Polygon([db.Point(int(x), int(y)) for x, y in points]))

    def place(self, parent, child, x, y, cols=1, rows=1, dx=0, dy=0, rotation=0, mirror=False):
        transform = db.Trans(rotation, mirror, int(x), int(y))
        if cols == 1 and rows == 1:
            parent.insert(db.CellInstArray(child.cell_index(), transform))
        else:
            parent.insert(db.CellInstArray(child.cell_index(), transform, db.Vector(int(dx), 0),
                                           db.Vector(0, int(dy)), int(cols), int(rows)))


def six_transistor_cell(b: Builder, name="SRAM_BIT6"):
    """Six distinct active/poly crossings; connectivity is deliberately schematic."""
    c = b.cell(name)
    w, h = 3000, 4200
    b.box(c, "nwell", 90, 2150, 2820, 1930)
    for i, (x, y) in enumerate([(320, 700), (1760, 700), (320, 2800), (1760, 2800), (320, 1680), (1760, 1680)]):
        b.box(c, "active", x, y, 920, 420)
        b.box(c, "poly", x+350, y-190, 170, 800)
        for contact_x in [x+95, x+695]:
            b.box(c, "contact", contact_x, y+120, 150, 150)
            b.box(c, "local", contact_x-35, y+70, 220, 260)
        b.box(c, "via1", x+710, y+135, 120, 120)
    for y in [120, 3860]:
        b.box(c, "metal1", 100, y, 2800, 220)
        b.box(c, "metal1_pin", 260, y+35, 260, 150)
    for x in [160, 2660]:
        b.box(c, "metal2", x, 300, 170, 3520)
        b.box(c, "via2", x+20, 980, 130, 130)
    b.path(c, "metal1", [(900, 1000), (1420, 1000), (1420, 2930), (2150, 2930)], 150)
    b.path(c, "metal1", [(2150, 1000), (1590, 1000), (1590, 3190), (900, 3190)], 150)
    b.box(c, "local_pin", 1260, 1710, 170, 160)
    b.box(c, "local_pin", 1550, 1710, 170, 160)
    return c, w, h


def logic_cell(b: Builder, name: str, gates: int):
    c = b.cell(name)
    width, height = 1800 + gates*500, 2800
    b.box(c, "nwell", 50, 1470, width-100, 1260)
    for y in [520, 1840]:
        b.box(c, "active", 250, y, width-500, 360)
        for i in range(gates):
            x = 460 + i*500
            b.box(c, "poly", x, y-210, 160, 800)
            b.box(c, "contact", x-155, y+100, 130, 130)
            b.box(c, "local", x-180, y+45, 190, 250)
            b.box(c, "via1", x-145, y+110, 110, 110)
    for y in [100, 2460]:
        b.box(c, "metal1", 60, y, width-120, 200)
    b.path(c, "metal1", [(width-320, 650), (width-320, 1970)], 170)
    b.box(c, "metal2", width-480, 1110, 300, 170)
    b.box(c, "via2", width-370, 1130, 130, 130)
    b.box(c, "metal1_pin", 220, 1040, 170, 200)
    return c, width, height


def support_cells(b: Builder):
    inv, iw, ih = logic_cell(b, "INV_SYNTH", 1)
    nand, nw, nh = logic_cell(b, "NAND2_SYNTH", 2)
    sense = b.cell("SENSE_AMPLIFIER_STYLE")
    b.place(sense, inv, 0, 0)
    b.place(sense, inv, 5600, ih, rotation=2)
    b.path(sense, "metal2", [(700, 1350), (4900, 1350)], 200)
    b.box(sense, "via3", 2700, 1260, 180, 180)
    return inv, nand, sense


def sram_layout(level: str, rows: int):
    rank = list(TARGETS).index(level)
    banks, cols = [4, 8, 16][rank], [4, 8, 16][rank]
    b = Builder(SEEDS["sram"])
    bit, bw, bh = six_transistor_cell(b)
    inv, nand, sense = support_cells(b)
    mat = b.cell("SRAM_MAT")
    # Alternate rows are mirrored, while the array's pitch stays in parent coordinates.
    even_rows, odd_rows = (rows+1)//2, rows//2
    b.place(mat, bit, 0, 0, cols, even_rows, bw, 2*bh)
    if odd_rows:
        b.place(mat, bit, 0, 2*bh, cols, odd_rows, bw, 2*bh, mirror=True)
    mw, mh = cols*bw, rows*bh
    for r in range(rows):
        b.path(mat, "metal3", [(-900, r*bh+2100), (mw+900, r*bh+2100)], 160)
        for x in [400, mw-600]:
            b.box(mat, "via3", x, r*bh+2010, 180, 180)
    for col in range(cols):
        for x in [col*bw+245, col*bw+2745]:
            b.path(mat, "metal2", [(x, -800), (x, mh+800)], 170)
    decoder = b.cell("SRAM_ROW_DECODER")
    b.place(decoder, nand, 0, 0, 1, rows, 0, bh)
    for r in range(rows):
        b.path(decoder, "metal3", [(2500, r*bh+1400), (5200, r*bh+1400)], 180)
    bank = b.cell("SRAM_BANK")
    mx, my, gap = 7600, 7200, 5000
    b.place(bank, mat, mx, my, 2, 1, mw+gap, 0)
    b.place(bank, decoder, 800, my)
    b.place(bank, sense, mx, 1600, cols, 1, bw, 0)
    b.place(bank, sense, mx+mw+gap, 1600, cols, 1, bw, 0)
    bankw, bankh = mx+2*mw+gap+3000, my+mh+3000
    for x in [300, bankw-700]:
        b.box(bank, "metal4", x, 300, 400, bankh-600)
    for y in [400, bankh-800]:
        b.box(bank, "metal4", 300, y, bankw-600, 400)
    b.label(bank, "SYNTH SRAM BANK", 7600, bankh+300)
    top = b.cell("SRAM_TOP")
    bank_cols = [2, 4, 4][rank]
    bank_rows = math.ceil(banks/bank_cols)
    px, py = bankw+10000, bankh+10000
    b.place(top, bank, 15000, 15000, bank_cols, bank_rows, px, py)
    width, height = bank_cols*px+22000, bank_rows*py+22000
    b.box(top, "boundary", 0, 0, width, height)
    for x in range(6000, width, max(6000, width//12)):
        b.path(top, "metal5", [(x, 7000), (x, height-7000)], 700)
        b.box(top, "via4", x-200, 7100, 400, 400)
    for y in [6500, height-6500]:
        b.box(top, "metal4", 5500, y, width-11000, 900)
    for i in range(12):
        x = 9000+i*(width-18000)//11
        for y in [1000, height-5000]:
            b.box(top, "pad", x, y, 3500, 3500)
    b.label(top, f"GEOMETRY ONLY / SRAM {level.upper()} / {banks} BANKS", 12000, height-5200)
    # A deterministic orthogonal test bus gives each seed a geometry effect.
    route = 2500+b.rng.randrange(0, 1000, 50)
    b.path(top, "metal3", [(route, 8000), (route, height-10000), (width-8000, height-10000)], 220)
    return b.layout, {"banks": banks, "mats_per_bank": 2, "bitcell_rows": rows,
                      "bitcell_columns": cols, "bitcells_expanded": banks*2*rows*cols,
                      "bitcell_nm": [bw, bh], "preview_detail_cell": bit.name,
                      "description": "6T-style bitcell, alternating mirrored rows, word/bit lines, decoder, sense/periphery and AREF banks"}


def processor_layout(level: str, rows: int):
    rank = list(TARGETS).index(level)
    cores, columns = [4, 4, 8][rank], [6, 14, 24][rank]
    b = Builder(SEEDS["processor"])
    inv, nand, sense = support_cells(b)
    mux, _, _ = logic_cell(b, "MUX_STYLE_SYNTH", 3)
    # Top -> core -> logic tile -> alternating rows -> gate (5 cell levels).
    row_a, row_b = b.cell("LOGIC_ROW_A"), b.cell("LOGIC_ROW_B")
    pitch_x, pitch_y = 3700, 3200
    for row, a, z in [(row_a, inv, nand), (row_b, nand, mux)]:
        b.place(row, a, 0, 0, (columns+1)//2, 1, 2*pitch_x, 0)
        if columns//2:
            b.place(row, z, pitch_x, 0, columns//2, 1, 2*pitch_x, 0)
        b.box(row, "metal1", 0, 50, columns*pitch_x, 180)
        b.box(row, "metal1", 0, 2560, columns*pitch_x, 180)
    tile = b.cell("LOGIC_TILE")
    b.place(tile, row_a, 0, 0, 1, (rows+1)//2, 0, 2*pitch_y)
    if rows//2:
        b.place(tile, row_b, 0, 2*pitch_y-400, 1, rows//2, 0, 2*pitch_y, mirror=True)
    tilew, tileh = columns*pitch_x, rows*pitch_y
    for x in range(600, tilew, 3700):
        b.path(tile, "metal2", [(x, 150), (x, tileh-150)], 160)
        for y in [750, max(750,tileh-900)]:
            b.box(tile, "via2", x-60, y, 120, 120)
    for r in range(0, rows, 3):
        y=r*pitch_y+1400
        b.path(tile, "metal3", [(300,y),(tilew-300,y)], 220)
        b.box(tile, "via3", tilew//2-90, y-90, 180, 180)
    bit, bw, bh = six_transistor_cell(b, "CACHE_BIT6")
    cache = b.cell("CACHE_BANK")
    cache_cols = max(2, columns//2)
    cache_rows = max(2, rows//3)
    b.place(cache, bit, 0, 0, cache_cols, cache_rows, bw, bh)
    for col in range(cache_cols):
        b.path(cache, "metal2", [(col*bw+280, -1000), (col*bw+280, cache_rows*bh+600)], 180)
    b.place(cache, sense, 0, -4200, max(1,cache_cols//2), 1, 2*bw, 0)
    core = b.cell("PROCESSOR_CORE")
    tx, ty, tg = 5500, 6500, 5000
    b.place(core, tile, tx, ty, 2, 2, tilew+tg, tileh+tg)
    cache_x = tx+2*tilew+tg+5000
    b.place(core, cache, cache_x, ty+5000, 1, 2, 0, cache_rows*bh+11000)
    corew = cache_x+cache_cols*bw+5000
    coreh = max(ty+2*tileh+tg+4000, ty+2*(cache_rows*bh+11000))
    for y in [1800, coreh-2000]:
        b.box(core, "metal4", 1200, y, corew-2400, 650)
    for x in [1800, corew-2200]:
        b.box(core, "metal5", x, 1200, 650, coreh-2400)
    # H-tree-style clock trunk, tile branches, irregular seeded Manhattan routes.
    cx, cy = corew//2, coreh//2
    b.path(core, "metal4", [(cx,2200),(cx,coreh-2200)], 350)
    for y in [ty+tileh//2, ty+tileh+tg+tileh//2]:
        b.path(core, "metal3", [(tx+tilew//2,y),(cx,y),(tx+tilew+tg+tilew//2,y)], 260)
        b.box(core, "via4", cx-140,y-140,280,280)
    for _ in range(12):
        x = b.rng.randrange(2500, max(2550, corew-2500), 50)
        y = b.rng.randrange(2500, max(2550, coreh-2500), 50)
        b.path(core, "metal3", [(x,2200),(x,y),(corew-2200,y)], 150)
    b.label(core, "CORE / CACHE / CLOCK", 6500, coreh-1000)
    pad = b.cell("IO_PAD")
    for layer,inset in [("pad",0),("metal5",500),("metal4",1000)]:
        b.box(pad,layer,inset,inset,7000-2*inset,7000-2*inset)
    b.place(pad, inv, 2400, 7600)
    top = b.cell("PROCESSOR_TOP")
    core_cols = 2 if cores==4 else 4
    core_rows = cores//core_cols
    px, py = corew+15000, coreh+15000
    b.place(top, core, 25000, 25000, core_cols, core_rows, px, py)
    width,height=core_cols*px+42000,core_rows*py+42000
    b.box(top,"boundary",0,0,width,height)
    # Frame is explicit bars (no artificial hole bridge) and upper-metal grid.
    for x in [13500,width-14500]: b.box(top,"metal5",x,13500,1000,height-27000)
    for y in [13500,height-14500]: b.box(top,"metal4",13500,y,width-27000,1000)
    for x in range(20000,width-10000,max(10000,width//16)):
        b.path(top,"metal5",[(x,14000),(x,height-14000)],700)
    for y in range(20000,height-10000,max(10000,height//12)):
        b.path(top,"metal4",[(14000,y),(width-14000,y)],650)
    pad_count = [8,12,16][rank]
    pad_pitch = max(10000,(width-40000)//(pad_count-1))
    b.place(top,pad,18000,1000,pad_count,1,pad_pitch,0)
    b.place(top,pad,18000,height-1000,pad_count,1,pad_pitch,0,mirror=True)
    b.label(top,f"GEOMETRY ONLY / PROCESSOR {level.upper()} / {cores} CORES",26000,height-18000)
    return b.layout, {"cores":cores,"logic_tiles_per_core":4,"logic_rows_per_tile":rows,
        "logic_columns_per_row":columns,"cache_banks_per_core":2,"cache_rows":cache_rows,
        "cache_columns":cache_cols,"pads":pad_count*2,"preview_detail_cell":"LOGIC_TILE",
        "description":"Multicore floorplan, synthetic inv/nand/mux rows, cache bitcells, clock tree, seeded routes, upper-metal power mesh and pads"}


def statistics(layout: db.Layout):
    top = layout.top_cell()
    assert top is not None and len(layout.top_cells()) == 1
    layers = list(layout.layer_indexes())
    memo = {}
    cell_records = []
    def recurse(cell):
        ci = cell.cell_index()
        if ci in memo: return memo[ci]
        counts = Counter({li: cell.shapes(li).size() for li in layers})
        geometry = Counter({li: sum(not s.is_text() for s in cell.shapes(li).each()) for li in layers})
        depth, placements = 1, 0
        for inst in cell.each_inst():
            multiplicity = inst.na*inst.nb if inst.is_regular_array() else 1
            child_counts, child_geometry, child_depth, child_placements = recurse(inst.cell)
            for li,n in child_counts.items(): counts[li] += multiplicity*n
            for li,n in child_geometry.items(): geometry[li] += multiplicity*n
            depth = max(depth,child_depth+1)
            placements += multiplicity*(1+child_placements)
        memo[ci] = counts,geometry,depth,placements
        return memo[ci]
    expanded, geometry, depth, placements = recurse(top)
    stored = Counter()
    for cell in layout.each_cell():
        stored_cell = {str(layout.get_info(li)):cell.shapes(li).size() for li in layers if cell.shapes(li).size()}
        insts = []
        for inst in cell.each_inst():
            insts.append({"cell":inst.cell.name,"transform":str(inst.cplx_trans),
                          "array":inst.is_regular_array(),"na":inst.na,"nb":inst.nb,
                          "a_nm":[inst.a.x,inst.a.y],"b_nm":[inst.b.x,inst.b.y]})
        for li in layers: stored[li] += cell.shapes(li).size()
        cell_records.append({"name":cell.name,"stored_shapes":sum(stored_cell.values()),
                             "stored_by_layer":stored_cell,"instances":insts})
    pair_records=[]
    for li in layers:
        if not stored[li] and not expanded[li]: continue
        info=layout.get_info(li)
        pair_records.append({"layer":info.layer,"datatype":info.datatype,
            "name":info.name,"stored_shapes":stored[li],"expanded_shapes":expanded[li],
            "expanded_geometry_shapes":geometry[li]})
    bbox=top.bbox()
    return {"top_cell":top.name,"dbu_um":layout.dbu,"cells":len(cell_records),
        "layer_datatype_pairs":len(pair_records),"layers":pair_records,
        "stored_shapes":sum(stored.values()),"expanded_shapes":sum(expanded.values()),
        "expanded_geometry_shapes":sum(geometry.values()),"hierarchy_levels":depth,
        "max_instance_depth":depth-1,"stored_instance_records":sum(len(c['instances']) for c in cell_records),
        "stored_array_records":sum(i['array'] for c in cell_records for i in c['instances']),
        "expanded_instance_placements":placements,
        "bbox_nm":[bbox.left,bbox.bottom,bbox.right,bbox.top],"cell_details":cell_records}


def fit_target(kind, level):
    build = sram_layout if kind=="sram" else processor_layout
    # Binary search a single integer array dimension, without flattening layouts.
    low, high, candidates = 1, 512, []
    target=TARGETS[level]
    while low<=high:
        rows=(low+high)//2
        layout,parameters=build(level,rows)
        stats=statistics(layout)
        candidates.append((abs(stats['expanded_shapes']-target),layout,parameters,stats))
        if stats['expanded_shapes']<target: low=rows+1
        else: high=rows-1
    _,layout,parameters,stats=min(candidates,key=lambda c:c[0])
    assert 0.75*target<=stats['expanded_shapes']<=1.25*target,(kind,level,stats['expanded_shapes'])
    assert 3<=stats['hierarchy_levels']<=5
    return layout,parameters,stats


def save_options(suffix):
    options=db.SaveLayoutOptions()
    options.format='OASIS' if suffix=='.oas' else 'GDS2'
    if suffix=='.oas':
        # Uncompressed OASIS also exercises HongTu's standard record parser.
        options.oasis_write_cblocks=False
        options.oasis_compression_level=0
    else:
        options.gds2_write_timestamps=False
    return options


def write_layout(layout, path):
    options=save_options(path.suffix)
    layout.write(str(path),options)
    return {"file":path.name,"bytes":path.stat().st_size,
            "sha256":hashlib.sha256(path.read_bytes()).hexdigest()}


def verify_reproducibility(output, manifest):
    """Rebuild without touching published stream files; check real recursive counts."""
    rows=[]
    for record in manifest['fixtures']:
        layout,_,stats=fit_target(record['kind'],record['size'])
        streams=[]
        for original in record['files']:
            suffix=Path(original['file']).suffix
            rebuilt=bytes(layout.write_bytes(save_options(suffix)))
            digest=hashlib.sha256(rebuilt).hexdigest()
            assert digest==original['sha256'],(record['name'],suffix,'rebuild hash differs')
            assert hashlib.sha256((output/original['file']).read_bytes()).hexdigest()==digest
            streams.append({'format':suffix,'sha256':digest,'matches':True})
        # Separate KLayout's actual expanded traversal from our memoized
        # multiplicity count (important when AREF axes and nesting are involved).
        top=layout.top_cell();direct_count=0;direct_geometry=0
        for li in layout.layer_indexes():
            for it in top.begin_shapes_rec(li).each():
                direct_count+=1
                direct_geometry+=not it.shape().is_text()
        assert direct_count==stats['expanded_shapes'],(record['name'],direct_count,stats['expanded_shapes'])
        assert direct_geometry==stats['expanded_geometry_shapes']
        rows.append({'fixture':record['name'],'seed':record['seed'],'streams':streams,
                     'actual_recursive_iterator_count':direct_count,
                     'actual_recursive_geometry_count':direct_geometry,
                     'multiplicity_count_matches_iterator':True})
    report={'status':'passed','klayout_version':db.__version__,'fixtures':rows}
    (output/'reproducibility.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    return 'reproducibility.json'


def write_layer_profile(output):
    root=ET.Element('layer-properties')
    for name,(layer,datatype,color) in LAYERS.items():
        p=ET.SubElement(root,'properties')
        values={'frame-color':color,'fill-color':color,'frame-brightness':'0','fill-brightness':'0',
                'dither-pattern':'I2' if name in ['active','nwell'] else 'I0','line-style':'I0',
                'valid':'true','visible':'false' if name in ['boundary','label'] else 'true',
                'transparent':'false','width':'1','marked':'false','xfill':'false','animation':'0',
                'name':f'{name} {layer}/{datatype}','source':f'{layer}/{datatype}@1'}
        for key,value in values.items():ET.SubElement(p,key).text=value
    ET.indent(root,space='  ')
    ET.ElementTree(root).write(output/'benchmark-layers.lyp',encoding='utf-8',xml_declaration=True)


def compare_streams(gds: Path, oasis: Path):
    start=time.perf_counter()
    a,b=db.Layout(),db.Layout();a.read(str(gds));b.read(str(oasis))
    ca,cb=a.top_cell(),b.top_cell()
    pairs=sorted(set((a.get_info(li).layer,a.get_info(li).datatype) for li in a.layer_indexes())|
                 set((b.get_info(li).layer,b.get_info(li).datatype) for li in b.layer_indexes()))
    records=[]
    for layer,datatype in pairs:
        la,lb=a.find_layer(layer,datatype),b.find_layer(layer,datatype)
        ra=db.Region(ca.begin_shapes_rec(la)) if la is not None else db.Region()
        rb=db.Region(cb.begin_shapes_rec(lb)) if lb is not None else db.Region()
        xor=ra^rb
        if not xor.is_empty():raise AssertionError((gds.name,layer,datatype,xor.area()))
        records.append({"layer":layer,"datatype":datatype,"xor_empty":True,"xor_area_nm2":0,
                        "gds_top_cell_direct_shapes":ca.shapes(la).size() if la is not None else 0,
                        "geometry_polygons_before_merge":ra.size()})
    sa,sb=statistics(a),statistics(b)
    for key in ['top_cell','expanded_shapes','expanded_geometry_shapes','bbox_nm','hierarchy_levels']:
        assert sa[key]==sb[key],(key,sa[key],sb[key])
    return {"status":"passed","scope":"all top-cell recursive layer/datatype regions, text excluded from Region",
            "layer_checks":records,"elapsed_seconds":round(time.perf_counter()-start,4),
            "expanded_shapes_equal":True,"bounds_equal":True,"hierarchy_depth_equal":True}


def preview(path: Path, output: Path, detail_cell: str):
    import klayout.lay as lay
    view=lay.LayoutView()
    cv=view.load_layout(str(path),False)
    view.max_hier_levels=10
    view.set_config('background-color','#111827')
    view.set_config('grid-visible','false')
    view.set_config('text-visible','false')
    view.add_missing_layers()
    for item in view.each_layer():
        for name,(layer,datatype,color) in LAYERS.items():
            if item.source_layer==layer and item.source_datatype==datatype:
                item.fill_color=int(color[1:],16)
                item.frame_color=item.fill_color
                item.dither_pattern=0 if name not in ['nwell','active'] else 2
                item.visible=name not in ['boundary','label']
    view.zoom_fit()
    view.save_image(str(output),1600,1100)
    cell=view.cellview(cv).layout().cell(detail_cell)
    if cell is not None:
        view.select_cell(cell.cell_index(),cv)
        view.zoom_fit()
        view.save_image(str(output.with_name(output.stem+'-detail.png')),1100,900)
    view.destroy()


def write_readme(output, records):
    rows=['| Fixture | Expanded shapes | Stored shapes | Cells | Pairs | Levels | GDS bytes | OAS bytes |',
          '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for r in records:
        s=r['statistics'];f=r['files']
        rows.append(f"| {r['name']} | {s['expanded_shapes']:,} | {s['stored_shapes']:,} | {s['cells']} | {s['layer_datatype_pairs']} | {s['hierarchy_levels']} | {f[0]['bytes']:,} | {f[1]['bytes']:,} |")
    content='''# Hierarchical geometry stress fixtures

**These are synthetic geometry/tool verification samples, not functional circuits,
PDK-qualified layouts or manufacturable masks.** “6T SRAM style”, “logic rows” and
“processor cores” describe their organization and visual motifs only. No electrical
connectivity or foundry rules are asserted. Layer numbers resemble common IC layer
maps solely to exercise layer/datatype handling; they do not establish SKY130 compatibility.

All geometry is generated locally from original synthetic primitives. No public
SKY130 library cell is embedded. Project GPLv3 source/license terms apply; the
project license is copied here as PROJECT-LICENSE.txt. KLayout is a verification
dependency, not embedded code in the layouts.

## Files and actual measured counts

'''+ '\n'.join(rows)+'''

Counts come from KLayout's actual stored cells and instance multiplicities. Expanded
counts include text shape records; expanded_geometry_shapes excludes text and is
reported separately in manifest.json. “Levels” includes the top and leaf cells.
Regular arrays remain compressed; no flat 500,000-shape cell is written. Metadata
and per-cell instance transforms, array vectors and dimensions are in manifest.json.

## Reproduce

From the repository root:

```powershell
& python/.venv/Scripts/python.exe python/benchmarks/generate_complex_layouts.py
```

Optional: --kind sram|processor --sizes small medium large --no-preview;
--verify-max-expanded defaults to 150000 and bounds full recursive GDS/OASIS XOR.
Seeds are 20260930 (SRAM) and 20260931 (processor). KLayout is pinned to 0.30.12.
GDS timestamps are zeroed; SHA-256 identifies the exact generated stream. OASIS
uses uncompressed standard records to exercise the application parser.

Small/medium interoperability compares every recursive layer/datatype region using
KLayout XOR, plus expanded counts, hierarchy depth and bounds. Text contributes to
record counts but is excluded from geometric Region comparison. Large levels get
both stream readbacks and count/bounds checks; recursive XOR is marked skipped if
above the explicit threshold. Native HongTu roundtrip/UI results are separate gates,
owned by the application validation run, not inferred from the KLayout self-check.

PNG previews are direct KLayout renders of the GDS files, including detail views;
no image-generation model or hand-drawn replacement is used.
`benchmark-layers.lyp` supplies the same 19 colors to KLayout/HongTu; the die
boundary and labels are hidden by default to avoid covering the layout.
`reproducibility.json` records an in-memory rebuild of every GDS/OAS stream with
identical SHA-256, plus actual recursive-iterator shape counts independent of
the memoized hierarchy-multiplicity calculation.

Official API references:
- https://www.klayout.de/doc/code/class_CellInstArray.html
- https://www.klayout.de/doc/code/class_Cell.html
- https://www.klayout.de/doc/code/class_Layout.html
'''
    (output/'README.md').write_text(content,encoding='utf-8')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=DEFAULT_OUTPUT)
    parser.add_argument('--kind',choices=['sram','processor','both'],default='both')
    parser.add_argument('--sizes',nargs='+',choices=list(TARGETS),default=list(TARGETS))
    parser.add_argument('--no-preview',action='store_true')
    parser.add_argument('--verify-max-expanded',type=int,default=150000)
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    if db.__version__!='0.30.12':raise RuntimeError('Use pinned klayout==0.30.12 for reproducible streams')
    manifest={"schema":"hongtu-complex-geometry-v1","disclaimer":DISCLAIMER,"klayout_version":db.__version__,
        "generator":"python/benchmarks/generate_complex_layouts.py","seeds":SEEDS,"fixtures":[]}
    for kind in (['sram','processor'] if args.kind=='both' else [args.kind]):
        for level in args.sizes:
            name=kind+'-'+level
            layout,parameters,stats=fit_target(kind,level)
            files=[write_layout(layout,args.output/(name+suffix)) for suffix in ['.gds','.oas']]
            record={"name":name,"kind":kind,"size":level,"seed":SEEDS[kind],"target_shapes":TARGETS[level],
                "parameters":parameters,"statistics":stats,"files":files}
            # Always re-read BOTH files, even when large XOR is outside the bound.
            readbacks={}
            for suffix in ['.gds','.oas']:
                restored=db.Layout();restored.read(str(args.output/(name+suffix)))
                observed=statistics(restored)
                for key in ['expanded_shapes','expanded_geometry_shapes','bbox_nm','hierarchy_levels']:
                    assert observed[key]==stats[key],(name,suffix,key,observed[key],stats[key])
                readbacks[suffix]={'counts_bounds_depth_match':True,'cells':observed['cells'],
                    'stored_instance_records':observed['stored_instance_records'],'stored_array_records':observed['stored_array_records']}
            record['readback']=readbacks
            if stats['expanded_shapes']<=args.verify_max_expanded:
                record['gds_oasis_interop']=compare_streams(args.output/(name+'.gds'),args.output/(name+'.oas'))
            else:
                record['gds_oasis_interop']={'status':'recursive_xor_skipped','reason':'above configured expanded-shape limit',
                    'limit':args.verify_max_expanded,'stream_readbacks_passed':True}
            if not args.no_preview:
                preview(args.output/(name+'.gds'),args.output/(name+'.png'),parameters['preview_detail_cell'])
                record['previews']=[name+'.png',name+'-detail.png']
            manifest['fixtures'].append(record)
            (args.output/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
            write_readme(args.output,manifest['fixtures'])
            print(json.dumps({'fixture':name,'stored':stats['stored_shapes'],'expanded':stats['expanded_shapes'],
                              'pairs':stats['layer_datatype_pairs'],'levels':stats['hierarchy_levels'],
                              'gds_bytes':files[0]['bytes'],'oas_bytes':files[1]['bytes'],
                              'interop':record['gds_oasis_interop']['status']}),flush=True)
    shutil.copyfile(REPO/'LICENSE',args.output/'PROJECT-LICENSE.txt')
    write_layer_profile(args.output)
    manifest['layer_profile']='benchmark-layers.lyp'
    manifest['reproducibility_file']=verify_reproducibility(args.output,manifest)
    manifest['generator_sha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    (args.output/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print('Manifest:',args.output/'manifest.json',flush=True)


if __name__=='__main__':main()
