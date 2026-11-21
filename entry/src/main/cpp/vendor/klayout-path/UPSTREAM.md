# KLayout PATH DCoord adaptation

Source is the fixed upstream tag **v0.30.12**, retrieved on 2026-10-06:

- [dbPath.cc](https://raw.githubusercontent.com/KLayout/klayout/v0.30.12/src/db/db/dbPath.cc): `real_points`, DCoord `dpx`, `create_shifted_points`.
- [dbPath.h](https://raw.githubusercontent.com/KLayout/klayout/v0.30.12/src/db/db/dbPath.h): `hull` and `polygon`.
- [dbTypes.h](https://raw.githubusercontent.com/KLayout/klayout/v0.30.12/src/db/db/dbTypes.h): DCoord comparison precision and epsilon.
- [dbEdge.h](https://raw.githubusercontent.com/KLayout/klayout/v0.30.12/src/db/db/dbEdge.h): `contains` for redundant collinear points.

Original copyright: **Copyright (C) 2006-2026 Matthias Koefferlein**. These source files permit GPL version 2 or, at the recipient's option, any later version. The adaptation elects GPL version 3; the full upstream GPLv3 text is supplied as COPYING. The HongTu repository declares GPLv3 or later. This choice follows the upstream files' explicit later-version permission and keeps their ownership and warranty notice. No db/tl binary or runtime is linked by this adaptation.

Changes made 2026-10-06: substitute array/vector math for db types; retain complete forward/reverse DCoord contour construction, cut-off corners, short-segment handling and reflection; retain HongTu input/range guards; quantize the complete contour once. The public route accepts only a simple integer contour: distinct vertices, exact nonadjacent-edge crossing/touch/overlap checks, no adjacent backtracking, bounded comparison work, and a canonical boundary unchanged by Clipper2 NonZero normalization. ROUND uses the upstream default 16 segments per semicircle, with an outer-cap error bound plus grid displacement. Complex contours and exhausted budgets fail explicitly. Unrestricted research execution/fracture APIs are absent from the product helper.

The explicit `PathEditRegion::executeWholeDPathSimple` / `pathRegionWholeDPathSimple` method is connected only to full-layer expression PATH collection through `NativeLayerRegionAdapter.expressionPath`. The existing `execute`, `pathRegionForEdit` and shared `shape` operations retain their material-union and 8-segment round-cap contracts for other callers. Full-layer expression rejects the entire preview on a failed PATH; it never falls back to the legacy operation. GPL ownership and license text accompany the implementation. Source-bound host validation is recorded under `docs/validation/manual-drawing-goal-20261006/p08-production-fix`; a newly built package still requires UI/device qualification. Earlier research and failures remain preserved under `p08-fix-prototype`.
