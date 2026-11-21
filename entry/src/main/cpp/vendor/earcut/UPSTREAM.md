# Mapbox earcut.hpp

- Official source: https://github.com/mapbox/earcut.hpp
- Tag: `v2.2.4`; commit: `4811a2b69b91f6127a75e780de6e2113609ddabb`
- Unmodified `include/mapbox/earcut.hpp` and `LICENSE` (ISC).
- SHA256 earcut.hpp: `3b838bc3f643d34ced850b6d53b19e2d9abdf6c2c067425b02868d131379b3cc`
- SHA256 LICENSE: `828f2aed51b6526881a236758ec9b08cd69928fbfc70346d9d44a0b3a3444fe1`

Used only to fracture normalized editing results into hole-free polygons.
Output is checked against the original Clipper2 region before any edit is
committed. Earcut alone is not treated as a correctness oracle.
