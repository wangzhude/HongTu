"""Trusted local CPython scripts, with the complete KLayout database API."""
import argparse
from pathlib import Path
import runpy
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("script", type=Path)
    parser.add_argument("--output", type=Path,
                        help="Optionally write the final global layout to GDS/OASIS")
    args = parser.parse_args()
    sys.path.insert(0, str(args.script.resolve().parent))
    namespace = runpy.run_path(str(args.script.resolve()), run_name="__main__")
    if args.output:
        import klayout.db as db
        layout = namespace.get("layout")
        if not isinstance(layout, db.Layout):
            parser.error("script must leave a klayout.db.Layout in global variable layout")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        layout.write(str(args.output))
        print(f"Wrote {args.output.resolve()}")


if __name__ == "__main__":
    main()
