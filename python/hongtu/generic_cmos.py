"""Fixed generic bulk-CMOS geometric checks; never a foundry or formal LVS signoff."""
import re
import klayout.db as db

ALIASES = {
    "active": {"active", "diffusion", "diff", "od"},
    "poly": {"poly", "polysilicon", "gate"},
    "nwell": {"nwell", "nw"}, "pwell": {"pwell", "pw"},
    "nplus": {"nplus", "nimplant", "nimp", "nsdm"},
    "pplus": {"pplus", "pimplant", "pimp", "psdm"},
    "contact": {"contact", "contacts", "co", "cont"},
    "metal1": {"metal1", "met1", "m1"},
    "metal2": {"metal2", "met2", "m2"},
    "via1": {"via1", "via", "v1"},
    "metal1_label": {"metal1label", "metal1labels", "m1label", "m1labels"},
    "metal2_label": {"metal2label", "metal2labels", "m2label", "m2labels"},
    "poly_label": {"polylabel", "polylabels"},
    "labels": {"label", "labels", "text", "pinlabel", "pinlabels"},
}
REQUIRED = ("active", "poly", "nwell", "contact", "metal1")
MAX_SHAPES, MAX_POINTS, MAX_NODES = 20000, 200000, 2000


def normalize(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


def pair(value):
    if (not isinstance(value, (list, tuple)) or len(value) != 2
            or any(type(v) is not int or not 0 <= v <= 32767 for v in value)):
        raise ValueError("Layer mapping requires [integer layer, integer datatype] in 0..32767")
    return tuple(value)


def resolve_mapping(metadata, explicit):
    if set(explicit) - set(ALIASES):
        raise ValueError("Unknown mapping roles: " + ", ".join(sorted(set(explicit) - set(ALIASES))))
    definitions = metadata if isinstance(metadata, list) else metadata.get("layerDefinitions", [])
    result, evidence = {}, {}
    for role, aliases in ALIASES.items():
        candidates = [d for d in definitions if normalize(d.get("name", "")) in aliases]
        if role in explicit:
            result[role] = pair(explicit[role])
            evidence[role] = "explicit mapping"
        elif len(candidates) == 1:
            d = candidates[0]
            result[role] = pair([d["layerNumber"], d["datatype"]])
            evidence[role] = "exact named layer: " + d["name"]
        elif len(candidates) > 1:
            raise ValueError("Ambiguous named layer for " + role + "; supply explicit mapping")
    if len(set(result.values())) != len(result):
        raise ValueError("Each role must have a distinct layer/datatype; labels on conductor layers need no label role")
    return result, evidence


def expanded_budget(layout, cell, path=(), memo=None):
    memo = {} if memo is None else memo
    ci = cell.cell_index()
    if ci in path or len(path) >= 32:
        raise ValueError("Cyclic hierarchy or hierarchy depth exceeds 32")
    if ci in memo:
        return memo[ci]
    count = sum(cell.shapes(li).size() for li in layout.layer_indices())
    try:
        instances = list(cell.each_inst())
    except RuntimeError as exc:
        raise ValueError("Cyclic or invalid hierarchy rejected by KLayout") from exc
    for instance in instances:
        count += max(1, instance.na) * max(1, instance.nb) * expanded_budget(
            layout, layout.cell(instance.cell_index), path + (ci,), memo)
        if count > MAX_SHAPES:
            raise ValueError("Expanded geometry exceeds review budget")
    if count > MAX_SHAPES:
        raise ValueError("Expanded geometry exceeds review budget")
    memo[ci] = count
    return count


class Reviewer:
    def __init__(self, layout, top, mapping, port_names):
        self.layout, self.top, self.mapping = layout, top, mapping
        self.port_names = port_names
        self.findings, self.nodes, self.parents, self.devices = [], [], [], []
        self.regions = {}
        for role, (number, datatype) in mapping.items():
            li = layout.find_layer(number, datatype)
            region = db.Region() if li is None else db.Region(top.begin_shapes_rec(li))
            region.merge()
            self.regions[role] = region
        if sum(p.num_points() for r in self.regions.values() for p in r.each()) > MAX_POINTS:
            raise ValueError("Polygon complexity exceeds review budget")

    def issue(self, code, message, region=None, severity="error"):
        item = {"severity": severity, "code": code, "message": message}
        if region is not None and not region.is_empty():
            b, u = region.bbox(), self.layout.dbu
            item["bboxUm"] = [b.left*u, b.bottom*u, b.right*u, b.top*u]
        self.findings.append(item)

    def region(self, role):
        return self.regions.get(role, db.Region())

    def find(self, n):
        while self.parents[n] != n:
            self.parents[n] = self.parents[self.parents[n]]
            n = self.parents[n]
        return n

    def join(self, ids):
        if ids:
            target = self.find(ids[0])
            for n in ids[1:]:
                self.parents[self.find(n)] = target

    def add_nodes(self, role, region):
        for polygon in region.each():
            n = len(self.nodes)
            if n >= MAX_NODES:
                raise ValueError("Conductor component count exceeds review budget")
            self.nodes.append((role, db.Region(polygon)))
            self.parents.append(n)

    def hits(self, region, roles, touch=False):
        return [n for n, (role, node) in enumerate(self.nodes)
                if role in roles and (not node.interacting(region).is_empty() if touch
                                      else (node & region).area() > 0)]

    def cuts(self, role, lower_roles, upper_role):
        for polygon in self.region(role).each():
            cut = db.Region(polygon)
            lower = self.hits(cut, lower_roles)
            upper = self.hits(cut, [upper_role])
            lower_union = db.Region()
            for n in lower:
                lower_union += self.nodes[n][1]
            valid = (len(lower) == 1 and len(upper) == 1
                     and (cut - lower_union).is_empty()
                     and (cut - self.nodes[upper[0]][1]).is_empty())
            if not valid:
                self.issue("invalid_" + role,
                           role + " must be wholly covered by one lower conductor and one " + upper_role,
                           cut)
            else:
                self.join(lower + upper)

    def labels(self):
        found = {port: [] for port in self.port_names}
        inverse = {v.upper(): k for k, v in self.port_names.items()}
        if len(inverse) != len(self.port_names):
            raise ValueError("Port label names must be distinct")
        label_targets = {"metal1": ["metal1"], "metal2": ["metal2"], "poly": ["poly"],
                         "metal1_label": ["metal1"], "metal2_label": ["metal2"],
                         "poly_label": ["poly"], "labels": ["metal1", "metal2", "poly"]}
        for role, targets in label_targets.items():
            if role not in self.mapping:
                continue
            li = self.layout.find_layer(*self.mapping[role])
            if li is None:
                continue
            it = self.top.begin_shapes_rec(li)
            while not it.at_end():
                shape = it.shape()
                if shape.is_text():
                    text = shape.text.transformed(it.trans())
                    port = inverse.get(text.string.strip().upper())
                    if port:
                        point = text.trans.disp
                        ids = [n for n, (r, region) in enumerate(self.nodes) if r in targets
                               and any(p.inside(point) for p in region.each())]
                        nets = {self.find(n) for n in ids}
                        if len(nets) != 1:
                            self.issue("ambiguous_port", port + " label does not resolve to one conductor net")
                        else:
                            found[port].append(next(iter(nets)))
                it.next()
        ports = {}
        for port, ids in found.items():
            nets = set(ids)
            if len(nets) != 1:
                self.issue("missing_or_split_port", port + " has " + str(len(nets)) + " resolved nets")
            else:
                ports[port] = next(iter(nets))
        for i, a in enumerate(ports):
            for b in list(ports)[i + 1:]:
                if ports[a] == ports[b]:
                    connected = db.Region()
                    for n, (_role, region) in enumerate(self.nodes):
                        if self.find(n) == ports[a]:
                            connected += region
                    self.issue("shorted_ports", a + " and " + b + " are directly connected (bbox is the connected net extent)", connected)
        return ports

    def run(self):
        for role in REQUIRED:
            if role not in self.mapping or self.region(role).is_empty():
                self.issue("missing_layer", "Missing mapped geometry: " + role, severity="incomplete")
        active, poly, well = self.region("active"), self.region("poly"), self.region("nwell")
        if "pwell" in self.mapping:
            self.issue("pwell_model_unverified", "Explicit PWELL requires well-component body extraction beyond this bulk-substrate model", severity="incomplete")
        if "nplus" in self.mapping and "pplus" in self.mapping:
            overlap = active & self.region("nplus") & self.region("pplus")
            if not overlap.is_empty():
                self.issue("opposite_implants_overlap", "NPLUS and PPLUS overlap ACTIVE", overlap)
        channels = active & poly
        diffusion = active - poly
        self.add_nodes("diffusion", diffusion)
        for role in ("poly", "metal1", "metal2"):
            self.add_nodes(role, self.region(role))
        self.cuts("contact", ["diffusion", "poly"], "metal1")
        self.cuts("via1", ["metal1"], "metal2")
        ports = self.labels()
        known_nets = set(ports.values())
        for n, (role, region) in enumerate(self.nodes):
            if self.find(n) not in known_nets:
                self.issue("unassigned_conductor", role + " component has no resolved IN/OUT/VDD/VSS port", region)
        for polygon in channels.each():
            channel = db.Region(polygon)
            in_well, out_well = (channel - well).is_empty(), (channel & well).is_empty()
            kind = "PMOS" if in_well else "NMOS" if out_well else "ambiguous"
            sd = self.hits(channel, ["diffusion"], touch=True)
            gate = self.hits(channel, ["poly"])
            b, u = channel.bbox(), self.layout.dbu
            device = {"kind": kind, "bboxUm": [b.left*u, b.bottom*u, b.right*u, b.top*u],
                      "sdComponents": sd, "sdNets": [self.find(n) for n in sd],
                      "gateNets": [self.find(n) for n in gate]}
            self.devices.append(device)
            if kind == "ambiguous" or len(sd) != 2 or len(gate) != 1:
                self.issue("invalid_simple_channel", "Channel must be unambiguously inside/outside NWELL with two S/D regions and one gate", channel)
                continue
            implant = "pplus" if kind == "PMOS" else "nplus"
            if implant not in self.mapping:
                self.issue("implant_unverified", "Missing " + implant + " mapping for " + kind, channel, "incomplete")
            elif not (channel - self.region(implant)).is_empty():
                self.issue("channel_implant", kind + " channel not covered by " + implant, channel)
            if implant in self.mapping:
                for n in sd:
                    if not (self.nodes[n][1] - self.region(implant)).is_empty():
                        self.issue("source_drain_implant", kind + " S/D region not fully covered by " + implant, self.nodes[n][1])
            for n in sd:
                sd_region = self.nodes[n][1]
                outside_domain = (sd_region - well) if kind == "PMOS" else (sd_region & well)
                if not outside_domain.is_empty():
                    self.issue("source_drain_well_domain", kind + " S/D crosses its expected well domain", sd_region)
            if "IN" in ports and self.find(gate[0]) != ports["IN"]:
                self.issue("gate_disconnected", kind + " gate not connected to IN", channel)
            supply = "VDD" if kind == "PMOS" else "VSS"
            if supply in ports and "OUT" in ports:
                if {self.find(n) for n in sd} != {ports[supply], ports["OUT"]}:
                    self.issue("source_drain_connectivity", kind + " S/D do not connect separately to " + supply + " and OUT", channel)
        kinds = [d["kind"] for d in self.devices]
        if kinds.count("PMOS") != 1 or kinds.count("NMOS") != 1 or len(kinds) != 2:
            self.issue("inverter_device_count", "Simple inverter requires exactly one PMOS and one NMOS geometric candidate")
        for implant, domain, supply, title in (
            ("nplus", well, "VDD", "NWELL n+ tap"),
            ("pplus", active - well, "VSS", "outside-NWELL p+ substrate tap"),
        ):
            if implant not in self.mapping:
                self.issue("tap_unverified", "Missing " + implant + " mapping for " + title, severity="incomplete")
                continue
            taps = diffusion & domain & self.region(implant)
            connected_taps = db.Region()
            for n in self.hits(taps, ["diffusion"]):
                node = self.nodes[n][1]
                valid_tap = (node - domain).is_empty() and (node - self.region(implant)).is_empty()
                if valid_tap and supply in ports and self.find(n) == ports[supply]:
                    connected_taps += self.nodes[n][1] & taps
            if connected_taps.is_empty():
                self.issue("tap_missing", title + " not connected to " + supply)
            if supply == "VDD":
                for w in well.each():
                    wr = db.Region(w)
                    if not (wr & channels).is_empty() and (wr & connected_taps).is_empty():
                        self.issue("well_component_untied", "NWELL component containing a channel has no VDD n+ tap", wr)
        errors = any(f["severity"] == "error" for f in self.findings)
        incomplete = any(f["severity"] == "incomplete" for f in self.findings)
        return {"scope": "Generic geometric consistency for a simple bulk CMOS inverter",
                "foundrySignoff": False, "formalLvs": False,
                "genericConsistency": "issues" if errors else "incomplete" if incomplete else "consistent",
                "ports": ports, "devices": self.devices, "findings": self.findings,
                "layerGeometry": {k: {"components": r.count(), "areaUm2": r.area()*self.layout.dbu**2}
                                  for k, r in self.regions.items()},
                "assumptions": ["ACTIVE is one common diffusion mask; POLY crossing ACTIVE defines a candidate channel.",
                    "Direct CONTACT joins diffusion or poly to METAL1; VIA1 joins METAL1 to METAL2. Processes with local interconnect require a different explicit model.",
                    "NWELL interior is PMOS domain and exterior is bulk NMOS domain. Outside-NWELL p+ tap assumes a common p-type substrate.",
                    "Port texts must lie on their mapped conductor. Layout annotation by itself does not prove a pin.",
                    "This checks one PMOS plus one NMOS. Multi-finger, isolated/deep wells and other topologies require separate review."],
                "notVerified": ["Foundry DRC, implant/well enclosure and spacing rules, process-specific contact stacks, device models, W/L validity, body resistance, parasitics, manufacturability, circuit simulation"]}


class GenericInverterError(ValueError):
    pass


def validate_generic_inverter(layout, definitions):
    """Only a fixed profile may call this; the generated script cannot alter it."""
    tops = list(layout.top_cells())
    if len(tops) != 1:
        raise GenericInverterError("single_top_cell: requires exactly one top Cell")
    try:
        mapping, _ = resolve_mapping(definitions, {})
        expanded_budget(layout, tops[0])
        reviewer = Reviewer(layout, tops[0], mapping, {k: k for k in ("IN", "OUT", "VDD", "VSS")})
        mapped = set(mapping.values())
        for li in layout.layer_indexes():
            info = layout.get_info(li)
            if (info.layer, info.datatype) not in mapped:
                it = tops[0].begin_shapes_rec(li)
                if not it.at_end():
                    reviewer.issue("unmodeled_layer", "Nonempty layer has no supported role: " + info.name, severity="incomplete")
        report = reviewer.run()
    except (ValueError, RuntimeError) as exc:
        raise GenericInverterError("review_unavailable: " + str(exc)[:1000]) from None
    if report["genericConsistency"] != "consistent":
        # Codes, geometric locations and trusted messages only; no user script or paths.
        parts = []
        limit = 2800
        for finding in report["findings"]:
            part = finding["code"]
            if "bboxUm" in finding:
                part += " bboxUm=" + str([round(x, 6) for x in finding["bboxUm"]])
            part += ": " + finding["message"]
            if len("; ".join(parts + [part])) > limit:
                parts.append("additional_findings: " + str(len(report["findings"]) - len(parts)))
                break
            parts.append(part)
        raise GenericInverterError("; ".join(parts))
    return "generic_inverter: consistent; 1 PMOS + 1 NMOS; IN/OUT/VDD/VSS and body taps geometrically connected; formalLvs=false; foundrySignoff=false"


def generic_cmos_inverter(layout, cell_name="INVERTER", gate_length=200,
                          nmos_width=600, pmos_width=1200):
    """Generate an editable generic bulk-CMOS topology, dimensions in integer DBU.

    These are geometric proportions, not process design rules. Requires an empty
    Layout. No file access, reference geometry, fabrication claim or hidden PDK.
    The strict worker independently checks the resulting Layout before export.
    """
    if not isinstance(layout, db.Layout) or layout.cells() != 0:
        raise ValueError("generic_cmos_inverter requires an empty Layout")
    if not isinstance(cell_name, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,63}", cell_name):
        raise ValueError("cell_name must be an ASCII identifier of 1..64 characters")
    for name, value in (("gate_length", gate_length), ("nmos_width", nmos_width), ("pmos_width", pmos_width)):
        if type(value) is not int or not 100 <= value <= 100000:
            raise ValueError(name + " must be an integer in 100..100000 DBU")
    cell = layout.create_cell(cell_name)
    layers = {name: layout.layer(db.LayerInfo(i + 1, 0, name)) for i, name in enumerate(
        ("NWELL", "ACTIVE", "POLY", "NPLUS", "PPLUS", "CONTACT", "METAL1", "PIN_LABEL"))}

    def box(role, x1, y1, x2, y2):
        cell.shapes(layers[role]).insert(db.Box(x1, y1, x2, y2))

    def centered(role, x, y, width, height):
        box(role, x - width//2, y - height//2, x + (width+1)//2, y + (height+1)//2)

    unit = min(gate_length, nmos_width, pmos_width)
    cut = max(1, unit//3)
    metal = cut + 2*max(1, unit//3)
    sd_width = 4*unit
    span = 2*sd_width + gate_length
    gap = 6*unit
    py = nmos_width + gap
    ny_center, py_center = nmos_width//2, py + pmos_width//2
    gate_x, gate_y = sd_width + gate_length//2, nmos_width + gap//2
    source_x, drain_x = sd_width//2, sd_width + gate_length + sd_width//2
    tap_x = span + 4*unit + unit//2
    left, right = -4*unit, tap_x + 3*unit
    vss_y, vdd_y = -4*unit, py + pmos_width + 4*unit
    box("NWELL", -2*unit, py - 2*unit, tap_x + 3*unit, py + pmos_width + 2*unit)
    for y, width, implant in ((0, nmos_width, "NPLUS"), (py, pmos_width, "PPLUS")):
        box("ACTIVE", 0, y, span, y + width)
        box(implant, -unit//2, y - unit//2, span + unit//2, y + width + unit//2)
    for cy, implant in ((ny_center, "PPLUS"), (py_center, "NPLUS")):
        centered("ACTIVE", tap_x, cy, unit, unit)
        centered(implant, tap_x, cy, 2*unit, 2*unit)
    box("POLY", sd_width, -unit, sd_width + gate_length, py + pmos_width + unit)
    for cy in (ny_center, py_center):
        for x in (source_x, drain_x, tap_x):
            centered("CONTACT", x, cy, cut, cut)
    centered("CONTACT", gate_x, gate_y, cut, cut)
    for rail_y in (vss_y, vdd_y):
        box("METAL1", left, rail_y - metal//2, right, rail_y + (metal+1)//2)
    for cy, rail in ((ny_center, vss_y), (py_center, vdd_y)):
        for x in (source_x, tap_x):
            box("METAL1", x - metal//2, min(cy, rail) - metal//2,
                x + (metal+1)//2, max(cy, rail) + (metal+1)//2)
    box("METAL1", drain_x - metal//2, ny_center - metal//2,
        drain_x + (metal+1)//2, py_center + (metal+1)//2)
    box("METAL1", drain_x, gate_y - metal//2, right, gate_y + (metal+1)//2)
    box("METAL1", left, gate_y - metal//2, gate_x + (metal+1)//2, gate_y + (metal+1)//2)
    for name, x, y in (("IN", left + unit, gate_y), ("OUT", right - unit, gate_y),
                       ("VSS", left + unit, vss_y), ("VDD", left + unit, vdd_y)):
        cell.shapes(layers["PIN_LABEL"]).insert(db.Text(name, db.Trans(x, y)))
    return cell
