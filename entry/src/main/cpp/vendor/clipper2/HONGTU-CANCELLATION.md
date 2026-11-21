# HongTu cooperative-cancellation extension

Upstream remains Clipper2 2.0.1 at commit
`21ebba05db8894f0c7217ad35ea518080f324946`; its Boost license and attribution
remain in the original files. `SHA256SUMS` records the upstream baseline rather
than the modified checkout. `HONGTU-PATCH-SHA256SUMS` records only the two patched
engine files; all other upstream files must continue to match `SHA256SUMS`.

`ClipperBase::SetCheckpoint` attaches an optional callback to one engine
instance. `CheckpointContext` invokes it every 256 visited loop/comparison steps
and at explicit operation boundaries. The callback runs on the same computing
thread and may throw the caller's cancellation exception. It does not emit a
synthetic percentage or mark the caller's worker stopped.

Checkpoints cover path/vertex input, minima construction/sorting, active edges,
winding, scanlines, horizontal processing/joins, intersection generation/sort/
processing, output cleanup and contour construction. Output conversion and area
sorting in the HongTu adapter also poll. Disposal never invokes callbacks:
unwinding must finish disposing vertices, edges and output rings before the
caller can confirm that the worker stopped.

The input vertex allocation is owned before entering cancellable loops. Bounds
are owned until inserted into the active-edge list. Cancelled execution clears
partial output and cleans live intermediates, then rethrows the original
exception. A horizontal ring split repairs the remaining ring pointer if an
interruption occurs while assigning output owners. Default callbacks are empty;
geometry, fill rules, quantization, budgets and operation selection are preserved.

The integration is exercised by `tools/compare_clipper_cancel_smoke.cpp` using
real worker threads, deterministic cancellation inside 13 deep phases, deadlines,
thread joins, scoped authorization, engine reuse and exact exception propagation.
`tools/compare_clipper_cancel_oracle.py` independently compares 99 integral-grid
results using KLayout Region, including holes and all four Boolean operations.
The Microsoft AddressSanitizer run checks the cancellation/cleanup paths for
invalid memory access; it is not a general memory-leak or manufacturing signoff.

Comparison workers must still own cancellation and completion state. A callback
throw, an accepted cancellation request, or suppression of an obsolete result
does not itself prove `workerStopped`; that proof belongs to the asynchronous
worker completion/cleanup boundary.
