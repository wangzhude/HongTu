"""Official KLayout demo MOS4 CMOS LVS extraction for HongTu companion verification.

Layers follow KLayout's official ``testdata/lvs/inv.oas`` demo technology:
- 1/0: NWELL
- 2/0: ACTIVE
- 3/0: PPLUS
- 4/0: NPLUS
- 5/0: POLY
- 6/0: CONTACT
- 7/0: METAL1, 7/1: METAL1_LABEL
- 8/0: VIA1
- 9/0: METAL2, 9/1: METAL2_LABEL

This deck is strictly for the bundled KLayout demo technology and never claims
SKY130 or commercial foundry signoff.
"""
from __future__ import annotations

from pathlib import Path


def _layer_or_empty(l2n, layout, layer_number: int, datatype: int, name: str):
    index = layout.find_layer(layer_number, datatype)
    if index is None:
        return l2n.make_layer(name)
    return l2n.make_layer(index, name)


def _text_layer_or_empty(l2n, layout, layer_number: int, datatype: int, name: str):
    index = layout.find_layer(layer_number, datatype)
    if index is None:
        return l2n.make_layer(name)
    return l2n.make_text_layer(index, name)


def _has_well_tie(layout, top) -> bool:
    import klayout.db as db

    nwell_idx = layout.find_layer(1, 0)
    active_idx = layout.find_layer(2, 0)
    nplus_idx = layout.find_layer(4, 0)
    if nwell_idx is None or active_idx is None or nplus_idx is None:
        return False
    nwell_reg = db.Region(top.begin_shapes_rec(nwell_idx))
    active_reg = db.Region(top.begin_shapes_rec(active_idx))
    nplus_reg = db.Region(top.begin_shapes_rec(nplus_idx))
    return not (active_reg & nwell_reg & nplus_reg).is_empty()


def extract(path, cell_name: str = ""):
    """Extract a simplified 4-terminal MOS netlist ``(l2n, netlist)`` from *path*."""
    import klayout.db as db

    layout = db.Layout()
    layout.read(str(Path(path)))
    top = layout.cell(cell_name) if cell_name else layout.top_cell()
    if top is None:
        raise ValueError("demo extraction does not contain the requested top circuit")

    l2n = db.LayoutToNetlist(db.RecursiveShapeIterator(layout, top, []))

    nwell = _layer_or_empty(l2n, layout, 1, 0, "nwell")
    active = _layer_or_empty(l2n, layout, 2, 0, "active")
    pplus = _layer_or_empty(l2n, layout, 3, 0, "pplus")
    nplus = _layer_or_empty(l2n, layout, 4, 0, "nplus")
    poly = _layer_or_empty(l2n, layout, 5, 0, "poly")
    contact = _layer_or_empty(l2n, layout, 6, 0, "contact")
    metal1 = _layer_or_empty(l2n, layout, 7, 0, "metal1")
    metal1_lbl = _text_layer_or_empty(l2n, layout, 7, 1, "metal1_label")
    via1 = _layer_or_empty(l2n, layout, 8, 0, "via1")
    metal2 = _layer_or_empty(l2n, layout, 9, 0, "metal2")
    metal2_lbl = _text_layer_or_empty(l2n, layout, 9, 1, "metal2_label")
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

    pmos = db.DeviceExtractorMOS4Transistor("PMOS")
    nmos = db.DeviceExtractorMOS4Transistor("NMOS")
    l2n.extract_devices(pmos, {"SD": psd, "G": pgate, "P": poly, "W": nwell,
                               "tS": psd, "tD": psd, "tG": poly, "tB": nwell})
    l2n.extract_devices(nmos, {"SD": nsd, "G": ngate, "P": poly, "W": bulk,
                               "tS": nsd, "tD": nsd, "tG": poly, "tB": bulk})

    for layer in (psd, nsd, poly, ntie, ptie, contact, metal1, via1, metal2, nwell):
        l2n.connect(layer)

    l2n.connect(psd, contact)
    l2n.connect(nsd, contact)
    l2n.connect(poly, contact)
    l2n.connect(ntie, contact)
    l2n.connect(ntie, nwell)
    l2n.connect(ptie, contact)
    l2n.connect(contact, metal1)
    l2n.connect(metal1, metal1_lbl)
    l2n.connect(metal1, via1)
    l2n.connect(via1, metal2)
    l2n.connect(metal2, metal2_lbl)

    # Also honor text labels placed directly on conductor layers 7/0 or 9/0.
    m1_direct_lbl = _text_layer_or_empty(l2n, layout, 7, 0, "metal1_direct_label")
    m2_direct_lbl = _text_layer_or_empty(l2n, layout, 9, 0, "metal2_direct_label")
    l2n.connect(metal1, m1_direct_lbl)
    l2n.connect(metal2, m2_direct_lbl)

    l2n.connect_global(ptie, "SUBSTRATE")
    l2n.connect_global(bulk, "SUBSTRATE")
    if not _has_well_tie(layout, top):
        l2n.connect_global(nwell, "NWELL")

    l2n.extract_netlist()
    netlist = l2n.netlist()
    netlist.make_top_level_pins()
    netlist.simplify()
    return l2n, netlist
