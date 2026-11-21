# Generic inverter validation and parametric tool contract

## Production interface

- `PythonRunOptions.validationProfile?: 'generic_inverter'` passes through to `/v1/generate` as `validationProfile`. Omission or the wire value `""` retains the original manual execution behavior.
- `policy.validate_request` accepts only empty or `generic_inverter` strings. The strict profile requires `inputMode='new'` (including its default) with no nonempty document/selection snapshot. Unknown profiles/types fail before execution.
- After generated code runs, the worker validates layer definitions, stored/expanded budgets and exactly one top Cell, then calls `validate_generic_inverter` **before** `layout.write`. Validation failure returns only `success:false,error`; no GDS, successful layer metadata or review summary is emitted.
- The fixed failure prefix is `GenericInverterError:`. Trusted finding codes, messages and available `bboxUm` coordinates are retained in a bounded message below 3000 characters. `shorted_ports` bounds describe the connected net's extent, not an exact short point. Bridge preserves 3000 characters for this prefix and 1200 for other failures.
- A successful strict run returns optional `reviewSummary` beginning `generic_inverter: consistent;`, containing `formalLvs=false` and `foundrySignoff=false`. Bridge requires this attestation for strict runs before writing any app artifact; old servers cannot silently downgrade to unchecked execution. The optional string survives artifact/history serialization; older history remains compatible.

Parent restart is required: `bridge.py` imports `validate_request` at process startup and validates both the HTTP request and `generate()` with that bound function. Updating only the fresh worker cannot make the old parent accept the new field. This agent did not restart any production process or read credentials.

## Restricted public geometry tool

```python
import hongtu as db
layout = db.Layout()
layout.dbu = 0.001
cell = db.generic_cmos_inverter(
    layout, cell_name='INVERTER',
    gate_length=200, nmos_width=600, pmos_width=1200)
```

The helper requires an empty Layout. `cell_name` is an ASCII letter followed by up to 63 letters/digits/underscores. Each dimension is an integer from 100 through 100000, in **database units**, excluding bool. Default DBU 0.001 µm gives a 0.2 µm gate length, 0.6 µm NMOS width and 1.2 µm PMOS width. Helper proportions are convenient generic geometry, not foundry minimum rules. The returned Cell remains editable, and changing parameters genuinely changes the geometry.

The helper uses dimension formulas to construct 30 shapes on eight named layers (`NWELL`, `ACTIVE`, `POLY`, `NPLUS`, `PPLUS`, `CONTACT`, `METAL1`, `PIN_LABEL`), with separate body taps, full contact coverage and four labels anchored on distinct conductor nets. It never reads a GDS, imports a reference cell or writes files. The independent fixed validator checks the helper result under the same profile used for freely generated scripts.

The safe execution shim and import/attribute policy expose this one helper. This does not expose the checker, its globals, arbitrary imports, filesystem operations or a client-supplied rule deck. Trusted local `import hongtu` also exports it.

## Fixed validation scope

`python/hongtu/generic_cmos.py` owns the shared core. The artifact CLI now imports it, eliminating a duplicate production checker. Layer roles come only from unambiguous exact normalized names. Nonempty unmodeled layers, unsupported well topology and missing information cannot produce `consistent`.

The check handles the simple bulk-CMOS model with direct diffusion/POLY CONTACT to METAL1 and optional VIA1/METAL2. It checks channel and S/D separation, implant/well domains, full cut coverage, named port connectivity, unassigned conductors and body taps in the expected domains. It does **not** establish formal extracted-device LVS, foundry DRC, device models, parasitics, body resistance, simulation or manufacturability. Local-interconnect stacks and isolated/deep wells need a different explicit model.

## Files and verification

Production changes: `python/hongtu/generic_cmos.py`, `policy.py`, `worker.py`, `__init__.py`, and `entry/src/main/ets/services/PythonBridgeService.ets`. Regression files: `python/tests/test_generic_cmos.py`, `tools/python_layer_metadata_host_check.mjs`; `tools/check_all.sh` adds the Python suite to its existing list. No Index/AiService/harness/device edits were made by this change.

- Actual CPython/KLayout new suite: **8/8**, including helper parameter boundaries, independently measured channel dimensions, real restricted worker output, pre-export short rejection, default compatibility, missing/unknown layers, policy limits and authenticated temporary HTTP success/failure.
- Full existing Python gate plus new suite: **35/35**, `artifacts/ai-autodraw-20260930/generic-cmos-python-all.log` (25.620 seconds). Existing isolated base-Python HTTP verification also passed.
- Actual Bridge/history host: **12/12**, `generic-cmos-bridge-host.log`, including profile passthrough, summary persistence, missing attestation rejection and preserved bounded error text.
- Shared checker mechanisms: **8/8**, `generic-cmos-checker-mechanics.log`; synthetic in-memory fixtures only, not live output acceptance.

The first actual AI artifact remains unchanged with SHA-256 `457b91128c4c191e002bcf30f37511681fa5cc6cdac12ee7b991dd1252d72f2c`. Its concrete defects and geometric edit suggestions are in `artifacts/ai-autodraw-20260930/actual-ai-geometric-findings.md`. App rebuild, owned-parent restart and real new-harness/device acceptance remain the root task's responsibility.
