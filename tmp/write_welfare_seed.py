import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from parse_welfare_sheet import out  # type: ignore

target = Path(r"C:\Users\abiod\Desktop\ClassNote\oasis-club\welfare-ledger-seed.js")
target.write_text("window.WELFARE_LEDGER_SEED = " + json.dumps(out, ensure_ascii=False) + ";\n", encoding="utf-8")
print(target)
