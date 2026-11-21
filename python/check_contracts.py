"""Cross-end Python <-> ArkTS contract & repository hygiene static checks for HongTu."""
from __future__ import annotations

from pathlib import Path
import re
import sys

PYTHON_ROOT = Path(__file__).resolve().parent
REPO_ROOT = PYTHON_ROOT.parent


def _bootstrap_local_venv(root: Path) -> None:
    ver = f"python{sys.version_info.major}.{sys.version_info.minor}"
    candidates: list[Path] = []
    for venv in (root / ".venv", root.parent / ".venv", Path(sys.prefix)):
        candidates.append(venv / "Lib" / "site-packages")
        candidates.append(venv / "lib" / ver / "site-packages")
        candidates.append(venv / "lib64" / ver / "site-packages")
        lib_dir = venv / "lib"
        if lib_dir.is_dir():
            candidates.extend(sorted(lib_dir.glob("python*/site-packages")))
    for candidate in reversed(candidates):
        s = str(candidate)
        if candidate.is_dir() and s not in sys.path:
            sys.path.insert(0, s)
    root_s = str(root)
    if root_s not in sys.path:
        sys.path.insert(0, root_s)


_bootstrap_local_venv(PYTHON_ROOT)


def _load_bridge_contracts(bridge_src: str):
    try:
        from hongtu.bridge import ARTIFACT_ID_PATTERN, validate_companion_endpoint
        return ARTIFACT_ID_PATTERN, validate_companion_endpoint
    except ModuleNotFoundError:
        m = re.search(r'ARTIFACT_ID_PATTERN\s*=\s*r"([^"]+)"', bridge_src)
        pattern = m.group(1) if m else ""
        return pattern, None


def run_all_checks(repo_root: Path = REPO_ROOT) -> list[str]:
    errors: list[str] = []

    ets_service = repo_root / "entry/src/main/ets/services/PythonBridgeService.ets"
    bridge_py = repo_root / "python/hongtu/bridge.py"
    verification_py = repo_root / "python/hongtu/verification.py"
    worker_py = repo_root / "python/hongtu/worker.py"
    bridge_entry_py = repo_root / "python/bridge_entry.py"
    lvs_py = repo_root / "python/verify_klayout_lvs.py"
    hypium_list = repo_root / "entry/src/test/List.test.ets"
    hypium_unit = repo_root / "entry/src/test/LocalUnit.test.ets"
    ci_yml = repo_root / ".github/workflows/ci.yml"
    agents_md = repo_root / "AGENTS.md"

    for required in (ets_service, bridge_py, verification_py, worker_py, bridge_entry_py,
                     lvs_py, hypium_list, hypium_unit, ci_yml, agents_md):
        if not required.is_file():
            errors.append(f"Missing required file: {required.relative_to(repo_root)}")
    if errors:
        return errors

    ets_src = ets_service.read_text(encoding="utf-8")
    bridge_src = bridge_py.read_text(encoding="utf-8")
    ver_src = verification_py.read_text(encoding="utf-8")
    worker_src = worker_py.read_text(encoding="utf-8")
    entry_src = bridge_entry_py.read_text(encoding="utf-8")
    unit_src = hypium_unit.read_text(encoding="utf-8")
    ci_src = ci_yml.read_text(encoding="utf-8")
    agents_src = agents_md.read_text(encoding="utf-8")

    artifact_pattern, validate_endpoint = _load_bridge_contracts(bridge_src)

    # 1. /v1/verify maxLimit must be 16 MiB matching verification.py result budget
    if "PYTHON_VERIFY_MAX_RESPONSE_BYTES: number = 16 * 1024 * 1024;" not in ets_src:
        errors.append("PythonBridgeService.ets must define PYTHON_VERIFY_MAX_RESPONSE_BYTES = 16 * 1024 * 1024")
    verify_block = re.search(r"/v1/verify[\s\S]{0,420}?maxLimit:\s*PYTHON_VERIFY_MAX_RESPONSE_BYTES", ets_src)
    if verify_block is None:
        errors.append("PythonBridgeService.ets /v1/verify request must use maxLimit: PYTHON_VERIFY_MAX_RESPONSE_BYTES")
    if "16 * 1024 * 1024" not in ver_src:
        errors.append("verification.py must enforce 16 MiB verification result budget")

    # 2. Cross-end artifactId regex & normalization alignment
    regex_match = re.search(r"PYTHON_ARTIFACT_ID_REGEX:\s*RegExp\s*=\s*\n?\s*/([^/]+)/;", ets_src)
    if regex_match is None or regex_match.group(1) != artifact_pattern:
        errors.append("PYTHON_ARTIFACT_ID_REGEX in PythonBridgeService.ets does not match bridge.ARTIFACT_ID_PATTERN")
    if "normalizePythonArtifactId(" not in ets_src:
        errors.append("PythonBridgeService.ets must normalize 32-hex and 36-UUID artifactIds")

    # 3. LAN HTTPS + optional caPath + filesDir/cacheDir orphan cleanup in PythonBridgeService.ets
    for token in ("validatePythonBridgeEndpoint", "normalizePythonBridgeCaPath", "caPath",
                  "cleanupTemporaryFiles", "pruneFilesDirectory", "pruneCacheDirectory"):
        if token not in ets_src:
            errors.append(f"PythonBridgeService.ets missing expected contract symbol: {token}")
    if validate_endpoint is not None:
        if validate_endpoint("https://192.168.1.10:7865/") != ("https", "192.168.1.10", 7865):
            errors.append("bridge.validate_companion_endpoint failed LAN HTTPS normalization")

    # 4. Slow-body protection: bridge.py must have zero raw blocking self.rfile.read(...) calls
    raw_reads = re.findall(r"self\.rfile\.read\(([^)]*)\)", bridge_src)
    if raw_reads:
        errors.append(f"bridge.py contains unguarded blocking self.rfile.read calls: {raw_reads}")
    if "self.read_ordinary_body(length)" not in bridge_src or "self.rfile.read1(" not in bridge_src:
        errors.append("bridge.py must read POST bodies via read_ordinary_body using bounded rfile.read1")

    # 5. Cross-platform -I .venv/lib/pythonX.Y/site-packages bootstrap
    for name, content in (("worker.py", worker_src), ("verification.py", ver_src), ("bridge_entry.py", entry_src)):
        if '"site-packages"' not in content or '"lib"' not in content or '"Lib"' not in content:
            errors.append(f"{name} missing cross-platform Windows/POSIX .venv site-packages bootstrap")

    # 6. Hypium unit test suite coverage checks
    for required_suite in ("@ohos/hypium", "HongTuEditUndoRedoSuite",
                           "HongTuIncrementalSnapshotLargeCoordinateSuite",
                           "HongTuCrossTabInstanceValidationSuite",
                           "HongTuPythonBridgeContractSuite"):
        if required_suite not in unit_src:
            errors.append(f"LocalUnit.test.ets missing suite/import: {required_suite}")

    # 7. CI & AGENTS.md must not reference deleted/nonexistent scripts
    for stale in ("tools/run_smoke.sh", "tools/check_scripts.ps1",
                  "tools/check_docs_claims.sh", "ui_consistency_audit.py"):
        if stale in ci_src:
            errors.append(f".github/workflows/ci.yml still references nonexistent script: {stale}")
        if stale in agents_src:
            errors.append(f"AGENTS.md still references nonexistent script: {stale}")
    if "unittest discover -s python/tests" not in ci_src:
        errors.append(".github/workflows/ci.yml must run python -m unittest discover -s python/tests")

    return errors


def main() -> int:
    failures = run_all_checks()
    if failures:
        for item in failures:
            print(f"[CONTRACT FAIL] {item}", file=sys.stderr)
        return 1
    print("All cross-end Python/ArkTS contracts, Hypium test suites, and CI/docs checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
