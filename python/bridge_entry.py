"""Stable absolute entry point used by the isolated host process manager."""
from pathlib import Path
import site
import sys


def _bootstrap_trusted_paths(root: Path) -> list[str]:
    inserted: list[str] = []
    candidates: list[Path] = []
    ver = f"python{sys.version_info.major}.{sys.version_info.minor}"
    for venv in (root / ".venv", root.parent / ".venv", root.parent.parent / ".venv", Path(sys.prefix)):
        candidates.append(venv / "Lib" / "site-packages")
        candidates.append(venv / "lib" / ver / "site-packages")
        candidates.append(venv / "lib64" / ver / "site-packages")
        lib_dir = venv / "lib"
        if lib_dir.is_dir():
            candidates.extend(sorted(lib_dir.glob("python*/site-packages")))
    seen: set[str] = set()
    for candidate in reversed(candidates):
        resolved = str(candidate)
        if resolved not in seen and candidate.is_dir():
            seen.add(resolved)
            site.addsitedir(resolved)
            if resolved in sys.path:
                sys.path.remove(resolved)
            sys.path.insert(0, resolved)
            inserted.append(resolved)
    root_str = str(root)
    if root_str not in sys.path:
        sys.path.insert(0, root_str)
    elif sys.path[0] != root_str:
        sys.path.remove(root_str)
        sys.path.insert(0, root_str)
    return inserted


root = Path(__file__).resolve().parent
_bootstrap_trusted_paths(root)
from hongtu.bridge import main  # noqa: E402

if __name__ == "__main__":
    main()
