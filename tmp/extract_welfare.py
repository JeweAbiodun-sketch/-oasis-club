import zipfile
import re
import xml.etree.ElementTree as ET
from pathlib import Path

path = Path(r"C:\Users\abiod\Downloads\Telegram Desktop\OASIS STATEMENT OF ACCOUNT 27TH JUNE. 2026.xlsx")
z = zipfile.ZipFile(path)
ns = {
    "a": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
}

wb = ET.fromstring(z.read("xl/workbook.xml"))
rels = ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))
relmap = {rel.attrib["Id"]: rel.attrib["Target"] for rel in rels}
sheets = []
for s in wb.find("a:sheets", ns):
    sheets.append((s.attrib["name"], relmap[s.attrib["{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"]]))
print("SHEETS:", [s[0] for s in sheets])

shared = []
if "xl/sharedStrings.xml" in z.namelist():
    root = ET.fromstring(z.read("xl/sharedStrings.xml"))
    for si in root.findall("a:si", ns):
        shared.append("".join(t.text or "" for t in si.iter("{http://schemas.openxmlformats.org/spreadsheetml/2006/main}t")))

def colnum(ref):
    m = re.match(r"([A-Z]+)(\d+)", ref)
    s = m.group(1)
    n = 0
    for ch in s:
        n = n * 26 + ord(ch) - 64
    return n

for name, target in sheets:
    if name != "WELFARE":
        continue
    print("\nSHEET:", name)
    sheet = ET.fromstring(z.read("xl/" + target))
    rows = []
    for row in sheet.findall(".//a:sheetData/a:row", ns):
        vals = []
        last = 0
        for c in row.findall("a:c", ns):
            ref = c.attrib.get("r")
            idx = colnum(ref)
            vals.extend([""] * (idx - last - 1))
            last = idx
            t = c.attrib.get("t")
            v = c.find("a:v", ns)
            isel = c.find("a:is", ns)
            val = ""
            if t == "s" and v is not None:
                val = shared[int(v.text)]
            elif t == "inlineStr" and isel is not None:
                val = "".join(t.text or "" for t in isel.iter("{http://schemas.openxmlformats.org/spreadsheetml/2006/main}t"))
            elif v is not None:
                val = v.text
            vals.append(val)
        rows.append(vals)
    print("ROWS:", len(rows), "COLS:", max((len(r) for r in rows), default=0))
    for i, r in enumerate(rows, start=1):
        print(i, r)
