"""Bounded native tool contracts, shared with the ArkTS editor (no reflection)."""
import json
import math
from pathlib import Path

CATALOG = json.loads(Path(__file__).with_name('native_tools.json').read_text(encoding='utf-8'))
TOOLS = {tool['name']: tool for tool in CATALOG['tools']}

def validate_value(value, schema, path='arguments', depth=0):
    if depth > 16 or value is None:
        raise ValueError(f'{path}: null or excessive nesting')
    if 'oneOf' in schema:
        matched = 0
        for choice in schema['oneOf']:
            try:
                validate_value(value, choice, path, depth+1)
                matched += 1
            except ValueError:
                pass
        if matched != 1:
            raise ValueError(f'{path}: incorrect value type')
        return
    if 'enum' in schema and value not in schema['enum']:
        raise ValueError(f'{path}: unsupported value')
    kind = schema.get('type')
    if kind == 'object':
        if type(value) is not dict or len(value)>128:
            raise ValueError(f'{path}: expected bounded object')
        if set(schema.get('required', [])) - set(value):
            raise ValueError(f'{path}: required fields missing')
        for key, item in value.items():
            field = schema.get('properties', {}).get(key, schema.get('additionalProperties', False))
            if key in {'__proto__','constructor','prototype'} or not isinstance(field, dict):
                raise ValueError(f'{path}.{key}: unknown field')
            validate_value(item, field, path+'.'+key, depth+1)
    elif kind == 'array':
        if type(value) is not list or not schema.get('minItems',0)<=len(value)<=schema.get('maxItems',512):
            raise ValueError(f'{path}: invalid array')
        for index,item in enumerate(value):
            validate_value(item,schema['items'],f'{path}[{index}]',depth+1)
    elif kind in {'number','integer'}:
        if type(value) not in {int,float} or not math.isfinite(value) or (kind=='integer' and (int(value)!=value or abs(value)>9007199254740991)) or not schema.get('minimum',-1e9)<=value<=schema.get('maximum',1e9):
            raise ValueError(f'{path}: invalid finite number')
    elif kind == 'string':
        if type(value) is not str or not schema.get('minLength',0)<=len(value)<=schema.get('maxLength',60000):
            raise ValueError(f'{path}: invalid text')
    elif kind == 'boolean':
        if type(value) is not bool: raise ValueError(f'{path}: expected boolean')
    else:
        raise ValueError(f'{path}: unsupported schema')

def validate_call(name, arguments):
    if name not in TOOLS: raise ValueError('Unknown native tool')
    if len(json.dumps(arguments,ensure_ascii=False,allow_nan=False))>60000: raise ValueError('Native tool arguments too large')
    validate_value(arguments,TOOLS[name]['parameters'])
    return TOOLS[name]

def validate_batch(calls):
    if not 1<=len(calls)<=32: raise ValueError('Native batch must contain 1-32 operations')
    definitions=[validate_call(call.name,call.arguments) for call in calls]
    if any(tool['mode']=='read' for tool in definitions): raise ValueError('Read tools must use read_native_tool')
    if len(calls)>1 and any(tool['mode']!='edit' for tool in definitions): raise ValueError('Application actions require a separate proposal')
    return definitions
