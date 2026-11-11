"""Pin an unsigned simulator unit-test host to loopback, without credentials."""
import argparse
import plistlib
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("products", type=Path)
args = parser.parse_args()
sources = [
    path for path in args.products.glob("Paperview_*.xctestrun")
    if path.stem not in {"Paperview_unit", "Paperview_fixture"}
]
if len(sources) != 1:
    raise SystemExit("Expected one Paperview xctestrun; use a fresh build directory.")
data = plistlib.loads(sources[0].read_bytes())
data["PaperviewTests"]["CommandLineArguments"] = [
    "--space-test-origin=http://127.0.0.1:18749",
    "--accounts-test-origin=http://localhost:18860",
]
data["PaperviewTests"]["EnvironmentVariables"] = {
    key: value for key, value in data["PaperviewTests"].get("EnvironmentVariables", {}).items()
    if not key.startswith("PAPERVIEW_TEST_")
}
data["PaperviewTests"]["InProcessParallelizationEnabled"] = False
output = args.products / "Paperview_unit.xctestrun"
output.write_bytes(plistlib.dumps(data))
print(f"Configured credential-free loopback unit tests: {output}")
