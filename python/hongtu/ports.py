"""Bounded typed port API and KFactory v3 transport using real klayout.db.

No gdsfactory/kfactory dependency is required in the production companion.
The foreign representation is verified separately against fixed real packages.
"""
import copy
import hashlib
import json
import math
import re
import struct
import uuid

from .policy import PolicyError, MAX_OUTPUT_BYTES

CELL_KEY = 'hongtu:cell_key:v1'
CELL_PORTS = 'hongtu:ports:v1'
CROSS_SECTIONS = 'hongtu:cross_sections:v1'
LOCAL_EDIT = 'hongtu:ports_local_edit:transient'
MAX_PORTS = 100000
MAX_SECTIONS = 4096
MAX_INFO_BYTES = 65536
MAX_DEFINITION_BYTES = 262144
MAX_META_NODES = 300000
MAX_META_DEPTH = 32
GRID_REL_TOL = 1e-9
GRID_ABS_TOL = 1e-6
OBLIQUE_WIDTH_DBU_TOL = 0.75


def _json(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False)


def _metadata_value_budget(value, label, variant=False):
    """Match native Parser value nodes, separately for JSON and TL Variant.

    JSON object keys are parsed strings and do not count as values. TL Variant
    dictionary keys do count. Typed KLayout values and JSON-valued strings are
    atomic here; an owned carrier's inner JSON is checked independently.
    """
    stack = [(value, 0)]
    nodes = 0
    while stack:
        item, depth = stack.pop()
        nodes += 1
        if nodes > MAX_META_NODES:
            raise PolicyError(label + ' exceeds the known META 300000 value-node budget')
        if depth > MAX_META_DEPTH:
            raise PolicyError(label + ' exceeds the known META depth 32 budget')
        if isinstance(item, dict):
            for key, child in item.items():
                if variant:
                    stack.append((key, depth + 1))
                stack.append((child, depth + 1))
        elif isinstance(item, (list, tuple)):
            stack.extend((child, depth + 1) for child in item)


def _owned_json(value, label):
    _metadata_value_budget(value, label)
    return _json(value)


def _text(value, budget, label, empty=False):
    if not isinstance(value, str) or (not value and not empty) or '\0' in value:
        raise PolicyError(label + ' must be text without NUL')
    try:
        size = len(value.encode('utf8'))
    except UnicodeError:
        raise PolicyError(label + ' must contain valid Unicode') from None
    if size > budget:
        raise PolicyError(label + ' exceeds its UTF-8 byte budget')
    return value


def _inert(value, label, budget):
    if not isinstance(value, dict):
        raise PolicyError(label + ' must be an inert JSON object')
    _metadata_value_budget(value, label)
    queue = [value]
    at = 0
    while at < len(queue):
        item = queue[at]
        at += 1
        if at > 8192:
            raise PolicyError(label + ' exceeds 8192 JSON value nodes')
        if not isinstance(item, (dict, list)):
            continue
        children = item.items() if isinstance(item, dict) else enumerate(item)
        for key, child in children:
            if isinstance(item, dict):
                if not isinstance(key, str) or key in {'__proto__', 'constructor', 'prototype'}:
                    raise PolicyError(label + ' contains an unsupported/reserved key')
            if child is None or type(child) in (str, bool, int):
                pass
            elif type(child) is float:
                if not math.isfinite(child):
                    raise PolicyError(label + ' contains a nonfinite number')
            elif isinstance(child, (dict, list)):
                pass
            else:
                raise PolicyError(label + ' contains an unsupported typed value')
            # Match native/model inert JSON: every scalar/null/container is a
            # value node, while dictionary-key text is not. Bound the queue too.
            if len(queue) >= 8192:
                raise PolicyError(label + ' exceeds 8192 JSON value nodes')
            queue.append(child)
    try:
        text = _json(value)
    except (ValueError, RecursionError):
        raise PolicyError(label + ' exceeds the supported JSON nesting depth') from None
    _text(text, budget, label)
    return text


def _object(text, label, budget):
    _text(text, budget, label)
    try:
        value = json.loads(text)
    except (ValueError, RecursionError):
        raise PolicyError(label + ' is invalid JSON') from None
    _inert(value, label, budget)
    return value


def _carrier(text, label):
    _text(text, MAX_OUTPUT_BYTES, label)
    try:
        value = json.loads(text)
    except (ValueError, RecursionError):
        raise PolicyError(label + ' is invalid JSON') from None
    if not isinstance(value, dict):
        raise PolicyError(label + ' must be an object')
    _metadata_value_budget(value, label)
    return value


def _finite(value, label, positive=False):
    if type(value) not in (int, float) or not math.isfinite(value) or (positive and value <= 0):
        raise PolicyError(label + ' must be finite' + (' and positive' if positive else ''))
    return value


def _normalize_angle(value):
    angle = _finite(value, 'Port orientation') % 360.0
    if abs(angle) <= 1e-9 or abs(angle - 360.0) <= 1e-9:
        return 0
    nearest = round(angle)
    if abs(angle - nearest) <= 1e-9:
        return int(nearest) % 360
    return round(angle, 9)


def _is_orthogonal_angle(degrees):
    rem = (_finite(degrees, 'Port orientation') % 90.0)
    return rem <= 1e-6 or abs(rem - 90.0) <= 1e-6


def _clean_nm(value, layout=None):
    """Snap near-DBU values to exact grid nm and strip IEEE-754 mantissa tails."""
    if layout is not None:
        dbu_nm = layout.dbu * 1000.0
        scaled = float(value) / dbu_nm
        nearest = round(scaled)
        if abs(scaled - nearest) <= max(GRID_ABS_TOL, abs(scaled) * GRID_REL_TOL):
            snapped = round(nearest * dbu_nm, 9)
            if abs(snapped - round(snapped)) <= 1e-12 and abs(snapped) <= 9007199254740991:
                return int(round(snapped))
            return snapped
    if type(value) is int:
        return value
    cleaned = round(float(value), 6)
    if cleaned == 0.0:
        return 0
    if abs(cleaned - round(cleaned)) <= 1e-12 and abs(cleaned) <= 9007199254740991:
        return int(round(cleaned))
    return cleaned


def _normalize_port_width_nm(width_nm, orientation_deg, layout=None):
    """Normalize port width: strict DBU tolerance for orthogonal ports, rounded DBU for oblique facets."""
    w = _finite(width_nm, 'Port width', True)
    if layout is None:
        return _clean_nm(w)
    dbu_nm = layout.dbu * 1000.0
    scaled = w / dbu_nm
    nearest = round(scaled)
    if _is_orthogonal_angle(orientation_deg):
        if nearest >= 1 and abs(scaled - nearest) <= max(GRID_ABS_TOL, abs(scaled) * GRID_REL_TOL):
            return _clean_nm(nearest * dbu_nm, layout)
        return w
    # Oblique rotated facet endpoints quantized on the Cartesian DBU grid can
    # deviate from an integer DBU width by up to sqrt(2)/2 DBU (~0.7071 DBU).
    if scaled < 0.5 - GRID_ABS_TOL:
        raise PolicyError('CrossSection width cannot be represented in this layout DBU')
    target_dbu = max(1, nearest)
    return _clean_nm(target_dbu * dbu_nm, layout)


def _layer(layer, datatype):
    if any(type(v) is not int or not 0 <= v <= 32767 for v in (layer, datatype)):
        raise PolicyError('port layer/datatype must be integers in 0..32767')


def _identity(prefix):
    return prefix + '-' + str(uuid.uuid4())


def _meta(owner, key):
    return owner.meta_info_value(key)


def _set_meta(owner, key, value):
    import klayout.db as db
    _metadata_value_budget(value, key, variant=True)
    owner.add_meta_info(db.LayoutMetaInfo(key, value, '', True))


def _cell(cell):
    import klayout.db as db
    if not isinstance(cell, db.Cell) or cell.destroyed():
        raise PolicyError('port API needs a live Cell owned by a Layout')
    layout = cell.layout()
    _finite(layout.dbu, 'layout DBU', True)
    return layout


def _key(cell):
    value = _meta(cell, CELL_KEY)
    if value is None:
        value = _identity('cell')
        _set_meta(cell, CELL_KEY, value)
    return _text(value, 512, 'Cell key')


def _validate_port(port, cell_id, key, layout=None):
    if not isinstance(port, dict):
        raise PolicyError('port must be an object')
    result = copy.deepcopy(port)
    _text(result.get('id'), 512, 'Port id')
    if result.get('ownerCellKey') != key:
        raise PolicyError('Port stable owner key does not match its Cell')
    result['ownerCellId'] = cell_id
    _text(result.get('name'), 512, 'Port name')
    center = result.get('centerNm')
    if not isinstance(center, dict):
        raise PolicyError('port centerNm must be an object')
    cx = _clean_nm(_finite(center.get('x'), 'Port x'), layout)
    cy = _clean_nm(_finite(center.get('y'), 'Port y'), layout)
    result['centerNm'] = {'x': cx, 'y': cy}
    result['orientationDeg'] = _normalize_angle(result.get('orientationDeg'))
    width = _normalize_port_width_nm(result.get('widthNm'), result['orientationDeg'], layout)
    result['widthNm'] = width
    _layer(result.get('layerNumber'), result.get('datatype'))
    _text(result.get('portType'), 128, 'Port type')
    if type(result.get('frameMirror')) is not bool:
        raise PolicyError('port frameMirror must be boolean')
    mag = _finite(result.get('frameMagnification'), 'Port frame magnification', True)
    _finite(width * mag, 'Effective port width', True)
    info = _object(result.get('infoJson'), 'Port info', MAX_INFO_BYTES)
    # Fixed KF port.info is one level below its TL dictionary root. A standalone
    # JSON depth 32 would therefore be guaranteed to fail its next export.
    _metadata_value_budget({'info': info}, 'Port info in generated TL', variant=True)
    if ('crossSectionKey' in result) != ('crossSectionVersion' in result):
        raise PolicyError('port CrossSection key/version must be supplied together')
    if 'crossSectionKey' in result:
        _text(result['crossSectionKey'], 512, 'CrossSection key')
        v = result['crossSectionVersion']
        if type(v) is not int or not 1 <= v <= 9007199254740991:
            raise PolicyError('CrossSection version must be a positive safe integer')
    if 'provenance' in result:
        _object(result['provenance'], 'Port provenance', MAX_INFO_BYTES)
    return result


def _sections(layout):
    value = _meta(layout, CROSS_SECTIONS)
    if value is None:
        return []
    body = _carrier(value, 'CrossSection carrier')
    if body.get('schemaVersion') != 1 or not isinstance(body.get('crossSections'), list):
        raise PolicyError('unsupported HongTu CrossSection carrier schema')
    sections, seen = copy.deepcopy(body['crossSections']), set()
    if len(sections) > MAX_SECTIONS:
        raise PolicyError('CrossSection count exceeds 4096')
    for xs in sections:
        if not isinstance(xs, dict):
            raise PolicyError('CrossSection must be an object')
        _text(xs.get('key'), 512, 'CrossSection key')
        _text(xs.get('name'), 512, 'CrossSection name')
        v = xs.get('version')
        if type(v) is not int or not 1 <= v <= 9007199254740991 or (xs['key'], v) in seen:
            raise PolicyError('CrossSection identity/version is invalid or duplicated')
        seen.add((xs['key'], v))
        _object(xs.get('definitionJson'), 'CrossSection definition', MAX_DEFINITION_BYTES)
        for optional in ('sourceFormat', 'sourceVersion'):
            if optional in xs:
                _text(xs[optional], 128, optional)
    return sections


def _save_sections(layout, sections):
    _set_meta(layout, CROSS_SECTIONS, _owned_json({'schemaVersion': 1, 'crossSections': sections}, CROSS_SECTIONS))


def _layer_pair(info):
    import klayout.db as db
    if not isinstance(info, db.LayerInfo):
        raise PolicyError('KFactory CrossSection must carry actual LayerInfo')
    _layer(info.layer, info.datatype)
    return {'layerNumber': info.layer, 'datatype': info.datatype}


def _foreign_section(layout, name, sections):
    for xs in sections:
        definition = _object(xs['definitionJson'], 'CrossSection definition', MAX_DEFINITION_BYTES)
        if definition.get('source', {}).get('format') == 'kfactory' and definition['source'].get('name') == name:
            return xs
    value = _meta(layout, 'kfactory:cross_section:' + name)
    asym = value is None
    if asym:
        value = _meta(layout, 'kfactory:asymmetrical_cross_section:' + name)
    if not isinstance(value, dict):
        raise PolicyError('KFactory port references missing CrossSection: ' + name[:512])
    scale = layout.dbu * 1000
    if asym:
        pair = _layer_pair(value.get('layer'))
        low = _clean_nm(_finite(value.get('section_min'), 'Asymmetric section_min') * scale, layout)
        high = _clean_nm(_finite(value.get('section_max'), 'Asymmetric section_max') * scale, layout)
        if high <= low:
            raise PolicyError('Asymmetric section extent is invalid')
        definition = {'schemaVersion': 1, 'kind': 'asymmetric', 'widthNm': _clean_nm(high - low, layout),
                      **pair, 'sectionMinNm': low, 'sectionMaxNm': high,
                      'sections': [{'layerNumber': s['layer'].layer, 'datatype': s['layer'].datatype,
                                    'minNm': _clean_nm(s['section_min'] * scale, layout),
                                    'maxNm': _clean_nm(s['section_max'] * scale, layout)}
                                   for s in value.get('sections', [])],
                      'enclosure': {'name': name, 'sections': [], 'bboxSections': []}}
        definition['enclosure']['bboxSections'] = [dict(_layer_pair(k), offsetNm=_clean_nm(v * scale, layout))
                                                   for k, v in value.get('bbox_sections', {}).items()]
    else:
        enc_name = _text(value.get('layer_enclosure'), 512, 'KFactory enclosure name')
        enclosure = _meta(layout, 'kfactory:layer_enclosure:' + enc_name)
        if not isinstance(enclosure, dict):
            raise PolicyError('KFactory CrossSection references missing layer enclosure')
        pair = _layer_pair(enclosure.get('main_layer'))
        entries = []
        for s in enclosure.get('sections', []):
            if not isinstance(s, (list, tuple)) or len(s) not in (2, 3):
                raise PolicyError('KFactory enclosure section is invalid')
            entry = dict(_layer_pair(s[0]), maxNm=_clean_nm(_finite(s[-1], 'Enclosure max') * scale, layout))
            if len(s) == 3:
                entry['minNm'] = _clean_nm(_finite(s[1], 'Enclosure min') * scale, layout)
            entries.append(entry)
        definition = {'schemaVersion': 1, 'kind': 'symmetric',
                      'widthNm': _clean_nm(_finite(value.get('width'), 'CrossSection width', True) * scale, layout),
                      **pair, 'enclosure': {'name': enc_name, 'sections': entries,
                                           'bboxSections': [dict(_layer_pair(s[0]), offsetNm=_clean_nm(s[1] * scale, layout))
                                                            for s in enclosure.get('bbox_sections', [])]}}
    for raw_key, key in [('radius', 'radiusNm'), ('radius_min', 'radiusMinNm')]:
        if value.get(raw_key) is not None:
            definition[key] = _clean_nm(_finite(value[raw_key], raw_key) * scale, layout)
    definition['source'] = {'format': 'kfactory', 'metaFormat': 'v3', 'name': name, 'dbuUm': layout.dbu}
    _finite(definition['widthNm'], 'CrossSection width', True)
    xs = {'key': _identity('xs'), 'version': 1, 'name': name,
          'definitionJson': _inert(definition, 'CrossSection definition', MAX_DEFINITION_BYTES),
          'sourceFormat': 'kfactory', 'sourceVersion': '3.0.4/v3'}
    sections.append(xs)
    return xs


def _port_frame(layout, value):
    import klayout.db as db
    t, dt = value.get('trans'), value.get('dcplx_trans')
    if t is not None and dt is not None:
        raise PolicyError('KFactory port contains both transform representations')
    if isinstance(t, db.Trans):
        return db.DCplxTrans(t.to_dtype(layout.dbu))
    if not isinstance(dt, db.DCplxTrans):
        raise PolicyError('KFactory v3 port transform has an unsupported type')
    return dt


def _local_edit(cell):
    marker = cell.meta_info(LOCAL_EDIT)
    return marker is not None and marker.value is True and not marker.persisted


def _mark_local_edit(cell):
    import klayout.db as db
    # This trusted, transient flag cannot be supplied by persisted GDS META. It
    # permits a local API transaction to update its derived records at serialize.
    cell.add_meta_info(db.LayoutMetaInfo(LOCAL_EDIT, True, '', False))


def _same_angle(a, b):
    diff = abs((float(a) - float(b)) % 360.0)
    return min(diff, 360.0 - diff) <= 1e-6


def _same_value(a, b):
    if type(a) in (int, float) and type(b) in (int, float):
        # KLayout serializes DCplxTrans to GDS META text using ~12 significant digits.
        return math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-5)
    if isinstance(a, dict) and isinstance(b, dict):
        if set(a) != set(b):
            return False
        return all(_same_angle(a[k], b[k]) if k == 'orientationDeg' else _same_value(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_same_value(x, y) for x, y in zip(a, b))
    return type(a) is type(b) and a == b


def _descriptor_semantics(definition):
    result = copy.deepcopy(definition)
    result.pop('source', None)
    if isinstance(result.get('enclosure'), dict):
        result['enclosure'].pop('name', None)
    return result


def _check_foreign_carrier(cell, ports, foreign, sections):
    """Persisted owned and fixed foreign carriers must agree before any edit."""
    if _local_edit(cell):
        return
    if not foreign:
        if any(_source_index(port) is not None for port in ports):
            raise PolicyError('dual port descriptions are inconsistent: foreign port records are missing')
        return
    layout = cell.layout()
    mapped = {}
    for meta in foreign:
        if not re.fullmatch(r'kfactory:ports:\d+', meta.name) or not isinstance(meta.value, dict):
            raise PolicyError('dual port descriptions are inconsistent: invalid foreign port')
        mapped[int(meta.name.rsplit(':', 1)[1])] = meta.value
    indices = []
    for port in ports:
        index = _source_index(port)
        if index is None:
            candidates = [i for i, value in mapped.items() if value.get('name') == port['name']]
            if len(candidates) == 1:
                index = candidates[0]
        indices.append(index)
    if None in indices or len(set(indices)) != len(indices) or set(indices) != set(mapped):
        raise PolicyError('dual port descriptions are inconsistent: owner/index correspondence differs')
    xs_lookup = {(x['key'], x['version']): x for x in sections}
    for port, index in zip(ports, indices):
        value = mapped[index]
        frame = _port_frame(layout, value)
        foreign_xs = _foreign_section(layout, _text(value.get('cross_section'), 512, 'Foreign CrossSection'), [])
        definition = _object(foreign_xs['definitionJson'], 'Foreign CrossSection definition', MAX_DEFINITION_BYTES)
        actual = {'name': value.get('name'), 'portType': value.get('port_type'),
                  'centerNm': {'x': _clean_nm(frame.disp.x * 1000, layout), 'y': _clean_nm(frame.disp.y * 1000, layout)},
                  'orientationDeg': _normalize_angle(frame.angle), 'frameMirror': frame.mirror, 'frameMagnification': frame.mag,
                  'widthNm': definition['widthNm'], 'layerNumber': definition['layerNumber'], 'datatype': definition['datatype'],
                  'info': _object(_inert(value.get('info', {}), 'Foreign port info', MAX_INFO_BYTES), 'Foreign port info', MAX_INFO_BYTES)}
        expected = {k: port[k] for k in actual if k != 'info'}
        expected['info'] = _object(port['infoJson'], 'Port info', MAX_INFO_BYTES)
        if not _same_value(expected, actual):
            raise PolicyError('dual port descriptions are inconsistent: foreign frame/name/info differs from owned port')
        own_xs = xs_lookup.get((port.get('crossSectionKey'), port.get('crossSectionVersion')))
        if own_xs is None or own_xs['name'] != value.get('cross_section'):
            raise PolicyError('dual port descriptions are inconsistent: CrossSection correspondence differs')
        own_definition = _object(own_xs['definitionJson'], 'CrossSection definition', MAX_DEFINITION_BYTES)
        if own_definition.get('schemaVersion') == 1 and own_definition.get('kind') in {'symmetric', 'asymmetric'}:
            if not _same_value(_descriptor_semantics(own_definition), _descriptor_semantics(definition)):
                raise PolicyError('dual port descriptions are inconsistent: CrossSection definitions differ')


def _load_ports(cell, sections=None, diagnostics=None):
    layout = _cell(cell)
    key = _key(cell)
    sections = _sections(layout) if sections is None else sections
    foreign = [m for m in cell.each_meta_info() if m.name.startswith('kfactory:ports:')]
    version = _meta(layout, 'kfactory:settings:meta_format')
    package_version = _meta(layout, 'kfactory:settings:version')
    unsupported = bool(foreign) and (version != 'v3' or package_version != '3.0.4')
    if unsupported and diagnostics is not None:
        diagnostics.append('preserved unsupported KFactory metadata ' + str(package_version)[:128] + '/' + str(version)[:128] + ' in Cell ' + cell.name)
    value = _meta(cell, CELL_PORTS)
    if value is not None:
        body = _carrier(value, 'Port carrier')
        if body.get('schemaVersion') != 1 or not isinstance(body.get('ports'), list):
            raise PolicyError('unsupported HongTu port carrier schema')
        ports = [_validate_port(p, cell.cell_index(), key, layout) for p in body['ports']]
        if not unsupported:
            _check_foreign_carrier(cell, ports, foreign, sections)
    else:
        ports = []
        if unsupported:
            return ports
        for meta in foreign:
            value = meta.value
            if not isinstance(value, dict) or not re.fullmatch(r'kfactory:ports:\d+', meta.name):
                raise PolicyError('invalid KFactory v3 port metadata')
            xs = _foreign_section(layout, _text(value.get('cross_section'), 512, 'Foreign CrossSection'), sections)
            definition = _object(xs['definitionJson'], 'CrossSection definition', MAX_DEFINITION_BYTES)
            dt = _port_frame(layout, value)
            p = {'id': _identity('port'), 'ownerCellId': cell.cell_index(), 'ownerCellKey': key,
                 'name': value.get('name'),
                 'centerNm': {'x': _clean_nm(dt.disp.x * 1000, layout), 'y': _clean_nm(dt.disp.y * 1000, layout)},
                 'orientationDeg': _normalize_angle(dt.angle), 'widthNm': definition['widthNm'],
                 'layerNumber': definition['layerNumber'], 'datatype': definition['datatype'],
                 'portType': value.get('port_type'), 'frameMirror': dt.mirror, 'frameMagnification': dt.mag,
                 'crossSectionKey': xs['key'], 'crossSectionVersion': xs['version'],
                 'infoJson': _inert(value.get('info', {}), 'Port info', MAX_INFO_BYTES),
                 'provenance': _json({'kind': 'foreign', 'format': 'kfactory', 'metaFormat': 'v3',
                                     'metaName': meta.name, 'portIndex': int(meta.name.rsplit(':', 1)[1]),
                                     'ownerCellKey': key})}
            ports.append(_validate_port(p, cell.cell_index(), key, layout))
    if len(ports) > MAX_PORTS:
        raise PolicyError('port count exceeds 100000')
    ids, names = set(), set()
    for p in ports:
        if p['id'] in ids or p['name'] in names:
            raise PolicyError('port id/name is duplicated in its Cell')
        ids.add(p['id']); names.add(p['name'])
    return ports


def _save_ports(cell, ports):
    _set_meta(cell, CELL_PORTS, _owned_json({'schemaVersion': 1, 'ports': ports}, CELL_PORTS))


def _source_index(port):
    if 'provenance' not in port:
        return None
    source = _object(port['provenance'], 'Port provenance', MAX_INFO_BYTES)
    index = source.get('portIndex')
    if (source.get('kind') == 'foreign' and source.get('format') == 'kfactory' and source.get('metaFormat') == 'v3' and
        source.get('ownerCellKey') == port['ownerCellKey'] and type(index) is int and index >= 0 and
        source.get('metaName') == 'kfactory:ports:' + str(index)):
        return index
    return None


def _port_indices(ports):
    indices, used = [], set()
    for port in ports:
        index = _source_index(port)
        if index is not None and index in used:
            raise PolicyError('duplicate KFactory source port index')
        if index is not None:
            used.add(index)
        indices.append(index)
    next_index = 0
    for position, index in enumerate(indices):
        if index is None:
            while next_index in used:
                next_index += 1
            indices[position] = next_index
            used.add(next_index)
    return indices


def _emitted_provenance(port, index):
    previous = _object(port['provenance'], 'Port provenance', MAX_INFO_BYTES) if 'provenance' in port else None
    original_index = _source_index(port)
    source = copy.deepcopy(previous) if previous is not None and original_index is not None else {}
    source.update({'kind': 'foreign', 'format': 'kfactory', 'metaFormat': 'v3',
                   'metaName': 'kfactory:ports:' + str(index), 'portIndex': index,
                   'ownerCellKey': port['ownerCellKey']})
    if previous is not None and original_index is None:
        source['previous'] = previous
    return _inert(source, 'Generated port provenance', MAX_INFO_BYTES)


def _pin_references(cell):
    indices = set()
    for meta in cell.each_meta_info():
        if not meta.name.startswith('kfactory:pins:'):
            continue
        value = meta.value
        if not isinstance(value, dict) or not isinstance(value.get('ports'), list):
            raise PolicyError('foreign pin metadata is invalid')
        for index in value['ports']:
            if type(index) is not int or index < 0:
                raise PolicyError('foreign pin port index is invalid')
            indices.add(index)
    return indices


def get_ports(cell):
    """Return independent canonical port dictionaries, with intrinsic nm width."""
    layout = _cell(cell)
    sections = _sections(layout)
    ports = _load_ports(cell, sections)
    _save_sections(layout, sections)
    _save_ports(cell, ports)
    return copy.deepcopy(ports)


def add_port(cell, name, center_nm, width_nm, orientation_deg, layer_number, datatype=0,
             port_type='optical', frame_mirror=False, frame_magnification=1.0, info=None):
    """Create a stable definition in one Cell, independent of instance projection."""
    layout = _cell(cell)
    ports = get_ports(cell)
    if not isinstance(center_nm, (list, tuple)) or len(center_nm) != 2:
        raise PolicyError('center_nm must contain x,y in nanometers')
    p = {'id': _identity('port'), 'ownerCellId': cell.cell_index(), 'ownerCellKey': _key(cell),
         'name': name, 'centerNm': {'x': center_nm[0], 'y': center_nm[1]}, 'widthNm': width_nm,
         'orientationDeg': orientation_deg, 'layerNumber': layer_number, 'datatype': datatype,
         'portType': port_type, 'frameMirror': frame_mirror, 'frameMagnification': frame_magnification,
         'infoJson': _inert({} if info is None else info, 'Port info', MAX_INFO_BYTES)}
    p = _validate_port(p, cell.cell_index(), _key(cell), layout)
    if any(v['name'] == p['name'] for v in ports) or len(ports) >= MAX_PORTS:
        raise PolicyError('new port name is duplicated or port count exceeds budget')
    layout.layer(layer_number, datatype)
    ports.append(p)
    _save_ports(cell, ports)
    _mark_local_edit(cell)
    return copy.deepcopy(p)


def update_port(cell, port_id, changes):
    """Update using canonical field names; stable id and ownership cannot change."""
    if not isinstance(changes, dict) or set(changes) - {'name', 'centerNm', 'orientationDeg', 'widthNm',
          'layerNumber', 'datatype', 'portType', 'frameMirror', 'frameMagnification', 'infoJson', 'provenance'}:
        raise PolicyError('unsupported port update field')
    layout = _cell(cell)
    ports = get_ports(cell)
    found = next((i for i, p in enumerate(ports) if p['id'] == port_id), None)
    if found is None:
        raise PolicyError('port id is not owned by this Cell')
    prior = ports[found]
    updated = _validate_port(dict(prior, **copy.deepcopy(changes)), cell.cell_index(), _key(cell), layout)
    if any(i != found and p['name'] == updated['name'] for i, p in enumerate(ports)):
        raise PolicyError('port name is duplicated')
    candidate_ports = list(ports)
    candidate_ports[found] = updated
    # Match the actual conversion branch before changing any original Cell/XS.
    # Same-owner foreign provenance depth 32 is retained. Other provenance is
    # wrapped in previous and may exceed the export bound after that extra level.
    _emitted_provenance(updated, _port_indices(candidate_ports)[found])
    width_or_layer_changed = (not _same_value(prior['widthNm'], updated['widthNm']) or
                              prior['layerNumber'] != updated['layerNumber'] or
                              prior['datatype'] != updated['datatype'])
    if width_or_layer_changed and 'crossSectionKey' in prior:
        sections = _sections(layout)
        xs = next((s for s in sections if s['key'] == prior['crossSectionKey'] and s['version'] == prior['crossSectionVersion']), None)
        if xs is None:
            raise PolicyError('port references a missing CrossSection')
        definition = _object(xs['definitionJson'], 'CrossSection definition', MAX_DEFINITION_BYTES)
        if definition.get('schemaVersion') != 1 or definition.get('kind') != 'symmetric':
            raise PolicyError('width/layer edit for opaque/asymmetric CrossSection requires an explicit descriptor transaction')
        new_xs = copy.deepcopy(xs)
        new_xs['key'], new_xs['version'] = _identity('xs'), 1
        new_xs['name'] = new_xs['key']
        definition.update({k: updated[k] for k in ('widthNm', 'layerNumber', 'datatype')})
        definition.pop('source', None)
        new_xs.pop('sourceFormat', None); new_xs.pop('sourceVersion', None)
        new_xs['definitionJson'] = _inert(definition, 'CrossSection definition', MAX_DEFINITION_BYTES)
        if len(sections) >= MAX_SECTIONS:
            raise PolicyError('CrossSection count exceeds 4096')
        sections.append(new_xs)
        updated['crossSectionKey'], updated['crossSectionVersion'] = new_xs['key'], 1
        _save_sections(layout, sections)
    ports[found] = updated
    layout.layer(updated['layerNumber'], updated['datatype'])
    _save_ports(cell, ports)
    _mark_local_edit(cell)
    return copy.deepcopy(updated)


def remove_port(cell, port_id):
    ports = get_ports(cell)
    target = next((p for p in ports if p['id'] == port_id), None)
    if target is not None and _source_index(target) in _pin_references(cell):
        raise PolicyError('port is referenced by a foreign pin; remove requires an explicit pin transaction')
    remaining = [p for p in ports if p['id'] != port_id]
    if len(remaining) == len(ports):
        raise PolicyError('port id is not owned by this Cell')
    _save_ports(cell, remaining)
    _mark_local_edit(cell)
    return True


def _dbu(value, layout, label, oblique=False):
    scaled = _finite(value, label) / (layout.dbu * 1000.0)
    rounded = round(scaled)
    tol = max(OBLIQUE_WIDTH_DBU_TOL, abs(scaled) * GRID_REL_TOL) if oblique else max(GRID_ABS_TOL, abs(scaled) * GRID_REL_TOL)
    if abs(scaled - rounded) > tol or abs(rounded) > 2147483647:
        raise PolicyError(label + ' cannot be represented in this layout DBU')
    return rounded


def _emit_foreign_section(layout, xs, oblique=False):
    import klayout.db as db
    definition = _object(xs['definitionJson'], 'CrossSection definition', MAX_DEFINITION_BYTES)
    if definition.get('schemaVersion') != 1 or definition.get('kind') not in {'symmetric', 'asymmetric'}:
        raise PolicyError('opaque CrossSection cannot be re-encoded as KFactory v3')
    name = xs['name']
    layer = db.LayerInfo(definition['layerNumber'], definition['datatype'])
    scale = lambda v, key, allow_oblique=False: _dbu(v, layout, key, oblique=allow_oblique)
    enc = definition.get('enclosure', {})
    if definition['kind'] == 'symmetric':
        enc_name = enc.get('name') or 'hongtu_enc_' + hashlib.sha256(xs['key'].encode()).hexdigest()[:24]
        if definition.get('source', {}).get('format') != 'kfactory':
            # An edited intrinsic layer must not mutate an enclosure shared by other ports.
            enc_name = enc_name + '_' + hashlib.sha256(_json([xs['key'], layer.layer, layer.datatype]).encode()).hexdigest()[:12]
        sections = []
        for s in enc.get('sections', []):
            values = [db.LayerInfo(s['layerNumber'], s['datatype'])]
            if 'minNm' in s:
                values.append(scale(s['minNm'], 'Enclosure min'))
            values.append(scale(s['maxNm'], 'Enclosure max'))
            sections.append(values)
        previous = _meta(layout, 'kfactory:layer_enclosure:' + enc_name)
        enclosure = copy.deepcopy(previous) if isinstance(previous, dict) else {}
        enclosure.update({'name': enc_name, 'main_layer': layer, 'sections': sections})
        if enc.get('bboxSections'):
            enclosure['bbox_sections'] = [[db.LayerInfo(s['layerNumber'], s['datatype']), scale(s['offsetNm'], 'BBox offset')]
                                           for s in enc['bboxSections']]
        _set_meta(layout, 'kfactory:layer_enclosure:' + enc_name, enclosure)
        previous = _meta(layout, 'kfactory:cross_section:' + name)
        value = copy.deepcopy(previous) if isinstance(previous, dict) else {}
        value.update({'width': scale(definition['widthNm'], 'CrossSection width', oblique), 'layer_enclosure': enc_name})
        namespace = 'kfactory:cross_section:'
    else:
        previous = _meta(layout, 'kfactory:asymmetrical_cross_section:' + name)
        value = copy.deepcopy(previous) if isinstance(previous, dict) else {}
        value.update({'layer': layer, 'section_min': scale(definition['sectionMinNm'], 'Section min', oblique),
                 'section_max': scale(definition['sectionMaxNm'], 'Section max', oblique),
                 'sections': [{'layer': db.LayerInfo(s['layerNumber'], s['datatype']),
                               'section_min': scale(s['minNm'], 'Section min', oblique),
                               'section_max': scale(s['maxNm'], 'Section max', oblique)}
                              for s in definition.get('sections', [])],
                 'bbox_sections': {db.LayerInfo(s['layerNumber'], s['datatype']): scale(s['offsetNm'], 'BBox offset')
                                   for s in enc.get('bboxSections', [])}})
        namespace = 'kfactory:asymmetrical_cross_section:'
    for key, out in [('radiusNm', 'radius'), ('radiusMinNm', 'radius_min')]:
        if key in definition:
            value[out] = scale(definition[key], key)
    _set_meta(layout, namespace + name, value)
    return name


def prepare_ports(layout):
    """Validate global identities, persist canonical truth, derive KF v3 records."""
    sections, diagnostics, ports, cells = _sections(layout), [], [], list(layout.each_cell())
    foreign_format = _meta(layout, 'kfactory:settings:meta_format')
    foreign_version = _meta(layout, 'kfactory:settings:version')
    has_marker = foreign_format is not None or foreign_version is not None
    unsupported_layout = has_marker and (foreign_format != 'v3' or foreign_version != '3.0.4')
    if unsupported_layout and not any(m.name.startswith('kfactory:ports:') for cell in cells for m in cell.each_meta_info()):
        diagnostics.append('preserved unsupported KFactory metadata ' + str(foreign_version)[:128] + '/' + str(foreign_format)[:128])
    keys, seen_ids, seen_names = [], set(), set()
    by_cell = []
    for logical_id, cell in enumerate(cells):
        _text(cell.name, 256, 'Cell name')
        if cell.name == '$$$CONTEXT_INFO$$$':
            raise PolicyError('Cell name is reserved for KLayout context transport')
        key = _key(cell)
        if key in keys:
            raise PolicyError('duplicate stable Cell key')
        keys.append(key)
        local = _load_ports(cell, sections, diagnostics)
        for p in local:
            # Empty layers are not declared by GDS geometry records. Recreate the
            # authoritative port layer when reading a valid port-only document.
            layout.layer(p['layerNumber'], p['datatype'])
            p['ownerCellId'] = logical_id
            if p['id'] in seen_ids or (key, p['name']) in seen_names:
                raise PolicyError('duplicate global port identity or Cell port name')
            seen_ids.add(p['id']); seen_names.add((key, p['name']))
        ports.extend(local); by_cell.append(local)
    if len(ports) > MAX_PORTS or len(sections) > MAX_SECTIONS:
        raise PolicyError('port/CrossSection count exceeds budget')
    lookup = {(x['key'], x['version']): x for x in sections}
    foreign_names = {}
    for cell, local in zip(cells, by_cell):
        if unsupported_layout and local:
            raise PolicyError('cannot merge canonical ports into unsupported KFactory metadata format')
        # Unsupported foreign versions remain opaque and are not destructively rewritten.
        unsupported = unsupported_layout or any(d.endswith(' in Cell ' + cell.name) for d in diagnostics)
        if unsupported:
            continue
        previous_ports = {meta.name: meta.value for meta in cell.each_meta_info()
                          if meta.name.startswith('kfactory:ports:') and isinstance(meta.value, dict)}
        if _pin_references(cell) and any(_source_index(port) is None for port in local):
            raise PolicyError('foreign pins in a new/copied port owner require an explicit pin transaction')
        indices = _port_indices(local)
        used = set(indices)
        if _pin_references(cell) - used:
            raise PolicyError('foreign pin references a removed/missing port index')
        for meta in list(cell.each_meta_info()):
            if meta.name.startswith('kfactory:ports:'):
                cell.remove_meta_info(meta.name)
        for index, p in zip(indices, local):
            oblique = not _is_orthogonal_angle(p['orientationDeg'])
            if 'crossSectionKey' not in p:
                width_dbu = _dbu(p['widthNm'], layout, 'CrossSection width', oblique=oblique)
                p['widthNm'] = _clean_nm(width_dbu * layout.dbu * 1000.0, layout)
                definition = {'schemaVersion': 1, 'kind': 'symmetric', 'widthNm': p['widthNm'],
                              'layerNumber': p['layerNumber'], 'datatype': p['datatype'],
                              'enclosure': {'name': '', 'sections': [], 'bboxSections': []}}
                xs = {'key': _identity('xs'), 'version': 1, 'name': _identity('hongtu_xs'),
                      'definitionJson': _inert(definition, 'CrossSection definition', MAX_DEFINITION_BYTES)}
                if len(sections) >= MAX_SECTIONS:
                    raise PolicyError('CrossSection count exceeds 4096')
                sections.append(xs); lookup[(xs['key'], 1)] = xs
                p['crossSectionKey'], p['crossSectionVersion'] = xs['key'], 1
            pair = (p['crossSectionKey'], p['crossSectionVersion'])
            xs = lookup.get(pair)
            if xs is None:
                raise PolicyError('port references missing CrossSection')
            definition = _object(xs['definitionJson'], 'CrossSection definition', MAX_DEFINITION_BYTES)
            if (not _same_value(definition.get('widthNm'), p['widthNm']) or
                    definition.get('layerNumber') != p['layerNumber'] or
                    definition.get('datatype') != p['datatype']):
                raise PolicyError('port and CrossSection width/layer are inconsistent')
            name = _emit_foreign_section(layout, xs, oblique=oblique)
            if name in foreign_names and foreign_names[name] != xs['definitionJson']:
                raise PolicyError('CrossSection foreign name conflicts with a different definition')
            foreign_names[name] = xs['definitionJson']
            import klayout.db as db
            prior = previous_ports.get('kfactory:ports:' + str(index)) if _source_index(p) is not None else None
            value = copy.deepcopy(prior) if isinstance(prior, dict) else {}
            value.pop('trans', None)
            value.update({'name': p['name'], 'cross_section': name, 'port_type': p['portType'],
                     'info': _object(p['infoJson'], 'Port info', MAX_INFO_BYTES),
                     'dcplx_trans': db.DCplxTrans(p['frameMagnification'], p['orientationDeg'], p['frameMirror'],
                                                 p['centerNm']['x'] / 1000, p['centerNm']['y'] / 1000)})
            _set_meta(cell, 'kfactory:ports:' + str(index), value)
            p['provenance'] = _emitted_provenance(p, index)
        _save_ports(cell, local)
        cell.remove_meta_info(LOCAL_EDIT)
    if ports and not diagnostics:
        # Compatibility markers describe the derived on-disk format. Production
        # uses only klayout.db and does not import the KFactory package.
        _set_meta(layout, 'kfactory:settings:version', '3.0.4')
        _set_meta(layout, 'kfactory:settings:meta_format', 'v3')
        _set_meta(layout, 'kfactory:settings:klayout_version', '0.30.12')
    _save_sections(layout, sections)
    return {'schemaVersion': 1, 'cellNames': [c.name for c in cells], 'cellKeys': keys,
            'ports': ports, 'crossSections': sections, 'diagnostics': diagnostics}


def wire_record(raw):
    try:
        return {'encoding': 'utf8', 'value': raw.decode('utf8')}
    except UnicodeError:
        return {'encoding': 'hex', 'value': raw.hex()}


def _records(raw):
    at = 0
    while at < len(raw):
        if at + 4 > len(raw):
            raise PolicyError('truncated GDS context record')
        length, typ, dtype = struct.unpack('>HBB', raw[at:at + 4])
        if length < 4 or length % 2 or at + length > len(raw):
            raise PolicyError('invalid GDS context record length')
        yield at, raw[at:at + length], typ, dtype, raw[at + 4:at + length]
        at += length


def read_gds_context(raw):
    """Extract raw context bytes, retaining arbitrary unknown namespace records."""
    groups, chunks = {None: []}, {}
    first, context, owner, start, extent = True, False, None, None, None
    for offset, record, typ, dtype, body in _records(raw):
        if typ == 5 and first:
            start = offset
        elif typ == 6:
            context = first and body.rstrip(b'\0') == b'$$$CONTEXT_INFO$$$'
        elif typ == 7:
            if context:
                extent = (start, offset + len(record))
            first = False; context = False
        elif context and typ == 8:
            owner = None
        elif context and typ == 18:
            try:
                owner = body.rstrip(b'\0').decode('utf8')
            except UnicodeError:
                raise PolicyError('context owner Cell name is not UTF-8') from None
            groups.setdefault(owner, [])
        elif context and typ == 44:
            value = body[:-1] if body.endswith(b'\0') else body
            match = re.match(rb'^#(\d+),(\d+):', value)
            if match:
                identity, part = map(int, match.groups())
                key = (owner, identity)
                if key not in chunks:
                    chunks[key] = {}; groups[owner].append(key)
                if part in chunks[key] or part > 4096:
                    raise PolicyError('duplicate/oversized GDS context chunk')
                chunks[key][part] = value[match.end():]
            else:
                groups[owner].append(value)
    for owner, values in groups.items():
        output = []
        for item in values:
            if isinstance(item, tuple):
                parts = chunks[item]
                if set(parts) != set(range(len(parts))):
                    raise PolicyError('GDS context chunk gap')
                item = b''.join(parts[i] for i in range(len(parts)))
            if len(item) > MAX_OUTPUT_BYTES:
                raise PolicyError('context record exceeds 8 MiB')
            output.append(item)
        groups[owner] = output
    if sum(len(v) for values in groups.values() for v in values) > MAX_OUTPUT_BYTES:
        raise PolicyError('Python context metadata exceeds 8 MiB combined budget')
    return groups, extent


def attach_context(metadata, raw):
    groups, unused = read_gds_context(raw)
    names = set(metadata['cellNames'])
    if any(owner is not None and owner not in names for owner in groups):
        raise PolicyError('context references a nonexistent Cell')
    metadata['layoutContextRecords'] = [wire_record(x) for x in groups[None]]
    metadata['cellContextRecords'] = [[wire_record(x) for x in groups.get(name, [])]
                                      for name in metadata['cellNames']]
    if len(_json(metadata).encode('utf8')) > MAX_OUTPUT_BYTES:
        raise PolicyError('Python port metadata exceeds 8 MiB response budget')
    return metadata


def capture_input_context(layout, raw):
    """Bind original raw byte records to stable Cell keys before generated edits."""
    groups, unused = read_gds_context(raw)
    original = {None: groups[None]}
    for name, records in groups.items():
        if name is None:
            continue
        cell = layout.cell(name)
        if cell is None:
            raise PolicyError('context references nonexistent input Cell')
        original[_key(cell)] = records
    return original


def _meta_name(raw):
    match = re.match(rb"^META\('([^'\\]*)'(?:,.*?)?\)=", raw)
    if match:
        return match.group(1).decode('ascii', errors='ignore')
    match = re.match(rb'^META\(([A-Za-z0-9_:.-]+)(?:,.*?)?\)=', raw)
    return match.group(1).decode('ascii') if match else None


def _derived_meta(name, v3):
    return name in {CELL_KEY, CELL_PORTS, CROSS_SECTIONS} or (v3 and name is not None and
          name.startswith(('kfactory:ports:', 'kfactory:cross_section:',
                           'kfactory:asymmetrical_cross_section:', 'kfactory:layer_enclosure:')))


def _merge_raw(original, current, v3):
    replacements = {_meta_name(raw): raw for raw in current if _derived_meta(_meta_name(raw), v3)}
    consumed, result, original_keys = set(), [], set()
    for raw in original:
        name = _meta_name(raw)
        if name is not None:
            original_keys.add(name)
        if _derived_meta(name, v3):
            if name in replacements:
                result.append(replacements[name]); consumed.add(name)
            # Removed canonical ports intentionally remove their derived metadata.
        else:
            result.append(raw)
    for raw in current:
        name = _meta_name(raw)
        if _derived_meta(name, v3):
            if name not in consumed:
                result.append(raw); consumed.add(name)
        elif name not in original_keys:
            # Newly created ordinary META (e.g. kfactory's format marker).
            result.append(raw)
    return result


def preserve_input_context(raw, original, metadata):
    """Merge untouched raw context without replacing the native file codec.

    The worker still writes geometry with real KLayout. This bounded GDS envelope
    merge prevents KLayout's META normalization/unknown-record consumption from
    dropping context when a current-document script edits that geometry.
    """
    current, extent = read_gds_context(raw)
    v3 = not metadata['diagnostics']
    merged = {None: _merge_raw(original.get(None, []), current[None], v3)}
    for name, key in zip(metadata['cellNames'], metadata['cellKeys']):
        merged[name] = _merge_raw(original.get(key, []), current.get(name, []), v3)
    if sum(len(value) for values in merged.values() for value in values) > MAX_OUTPUT_BYTES:
        raise PolicyError('combined raw context exceeds Python 8 MiB budget')
    if any(len(values) > 65536 for values in merged.values()):
        raise PolicyError('context owner exceeds 65536 records')

    def record(typ, dtype=0, body=b''):
        if len(body) % 2:
            body += b'\0'
        if len(body) + 4 > 65534:
            raise PolicyError('GDS record exceeds stream length')
        return struct.pack('>HBB', len(body) + 4, typ, dtype) + body

    def properties(values):
        result = bytearray()
        for index, value in enumerate(values):
            parts = [value[i:i + 32000] for i in range(0, len(value), 32000)] or [b'']
            for part, piece in enumerate(parts):
                if len(parts) > 1:
                    piece = f'#{index},{part}:'.encode() + piece
                result.extend(record(43, 2, struct.pack('>H', index)))
                result.extend(record(44, 6, piece))
        return bytes(result)

    first = next((offset for offset, unused, typ, dtype, body in _records(raw) if typ == 5), None)
    if first is None:
        raise PolicyError('GDS has no Cell structure')
    timestamp = raw[first:first + 28]
    if len(timestamp) != 28 or timestamp[:4] != b'\x00\x1c\x05\x02':
        raise PolicyError('GDS Cell timestamp record is invalid')
    envelope = bytearray(timestamp)
    envelope.extend(record(6, 6, b'$$$CONTEXT_INFO$$$'))
    if merged[None]:
        envelope.extend(record(8)); envelope.extend(record(13, 2, b'\0\0'))
        envelope.extend(record(14, 2, b'\0\0')); envelope.extend(record(16, 3, b'\0' * 40))
        envelope.extend(properties(merged[None])); envelope.extend(record(17))
    for name in metadata['cellNames']:
        if not merged[name]:
            continue
        envelope.extend(record(10)); envelope.extend(record(18, 6, name.encode('utf8')))
        envelope.extend(record(16, 3, b'\0' * 8)); envelope.extend(properties(merged[name])); envelope.extend(record(17))
    envelope.extend(record(7))
    start, end = extent if extent is not None else (first, first)
    result = raw[:start] + bytes(envelope) + raw[end:]
    if len(result) > MAX_OUTPUT_BYTES:
        raise PolicyError('generated GDS and context exceed 8 MiB')
    return result
