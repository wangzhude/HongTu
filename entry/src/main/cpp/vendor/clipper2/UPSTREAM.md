# Clipper2 source provenance

- Official upstream: https://github.com/AngusJohnson/Clipper2
- Release: `Clipper2_2.0.1`
- Commit: `21ebba05db8894f0c7217ad35ea518080f324946`
- Downloaded: 2026-09-30, from raw.githubusercontent.com at that commit.
- License: Boost Software License 1.0, retained in `LICENSE` and upstream headers.
- `SHA256SUMS` retains the original upstream SHA-256 digests. All files remain
  unmodified except `include/clipper2/clipper.engine.h` and
  `src/clipper.engine.cpp`, which carry the HongTu cooperative-cancellation
  extension described in `HONGTU-CANCELLATION.md`. Current digests of these two
  files are recorded separately in `HONGTU-PATCH-SHA256SUMS`.
- HongTu builds only `clipper.engine.cpp`, `clipper.offset.cpp` and
  `clipper.rectclip.cpp`. Upstream triangulation declarations are transitive
  includes; upstream triangulation is not built or used.

The adapter is `../../clipper_engine.h`. It keeps the HongTu API, validates
coordinates, propagates errors without partial geometry, and documents fill
rules. Integer output remains quantized to the database-unit lattice. This
integration alone is not process qualification or sign-off certification.
