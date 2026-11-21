# Root integration acceptance plan

Status: implementation running; no combined acceptance yet.
Baseline: 0edb7e1ab72bac5704fe250df88a585d1bc06e10.
Coordinator: integration/parallel17. All four Codex tasks use gpt-6.1-sol / ultra; see parallel17-tasks-20261003.json.

1. Read each final branch diff, explicit file ownership, source-bound results and handoff. A owns Index until it relinquishes the completed branch; root alone wires B/C/D afterwards.
2. Integrate a single authoritative storage path for report recovery, waiver ownership and engineering restore. Cover ordinary RDB actions as well as new actions; prove CAS failure, complete rollback and cold restore.
3. Add mandatory new module checks to the gate. Run those only as needed during integration, then one final complete tools/check_all.sh with HAP. Reuse the new run_validation.ps1 for source snapshots, terminal receipts and preserved HAP outputs.
4. Use that exact HAP for API24/2in1 emulator UI operations through existing business entries: three real sources, independent overlay transform/opacity/masks; clone/bookmark; project save cancellation/success/import/mapping; waiver apply/remove/export; recursive operation preview/apply/UndoRedo.
5. Run the cross-feature sequence: waiver apply -> ordinary report filtering/pagination/manual review -> engineering restore/new report IDs -> cold start -> waiver remove. Foreign/manual waivers cannot become library-owned, and stale records cannot overwrite the new reports.
6. Verify recursive expressions read only the active edit database; source overlay visibility does not affect geometry. Verify missing overlay references diagnose absence instead of silently rebinding by name.
7. Preserve original eight documents and original reports/views with complete field/type/missing/null comparisons before, warm and cold. Clean only objects created by this acceptance run.
8. Update the software structure tree and a new ledger with named evidence. C01/C06/C09 remain open where focus following, cross-technology migration, full attachment/collaboration or dynamic derived dependencies remain missing.

R16 preservation is complete: 6411 artifacts, 577 live bindings frozen with exact mapping. Inherited R16 evidence is historical/currentAcceptance=false in R17; current evidence must match current source and final HAP. Physical-device/manufacturing validation remains a separate requirement.

Read-only acceptance review identified root hooks:
- Index projectSaveContext must include view/bookmark/overlay/RDB state during asynchronous saves.
- A must remove the old active-document-only source read restriction and keep overlays non-editable.
- Recursive dialog must expose actual depth and show transformed occurrences rather than selecting original IDs.
- Root RDB persistence must not remain a standalone writer alongside B durable restore and C waiver envelope.
