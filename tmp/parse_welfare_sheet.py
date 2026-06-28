import json
import re
import zipfile
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta
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
target = None
for s in wb.find("a:sheets", ns):
    if s.attrib["name"] == "WELFARE":
        target = relmap[s.attrib["{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"]]
        break
if not target:
    raise SystemExit("WELFARE sheet not found")

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

def excel_date_to_iso(value):
    if value is None or value == "":
        return ""
    text = str(value).strip()
    if re.fullmatch(r"\d+(\.\d+)?", text):
        serial = float(text)
        # Excel 1900 date system (with the leap-year bug offset).
        dt = datetime(1899, 12, 30) + timedelta(days=serial)
        return dt.date().isoformat()
    if re.fullmatch(r"\d{1,2}/\d{1,2}/\d{4}", text):
        d, m, y = text.split("/")
        return datetime(int(y), int(m), int(d)).date().isoformat()
    if re.fullmatch(r"\d{1,2}/\d{1,2}/\d{2}", text):
        d, m, y = text.split("/")
        y = int(y)
        y += 2000 if y < 50 else 1900
        return datetime(y, int(m), int(d)).date().isoformat()
    return text

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

entries = []
running = 0
for i, row in enumerate(rows[2:], start=3):
    if len(row) < 5:
        row += [""] * (5 - len(row))
    date_raw, name, contrib_raw, expense_raw, balance_raw = row[:5]
    name = (name or "").strip()
    contrib = 0
    expense = 0
    if contrib_raw not in ("", None):
        contrib = int(float(str(contrib_raw).replace(",", "").replace("₦", "").strip()))
    if expense_raw not in ("", None):
        expense = int(float(str(expense_raw).replace(",", "").replace("₦", "").strip()))
    running = int(float(str(balance_raw).replace(",", "").replace("₦", "").strip())) if balance_raw not in ("", None) else running + contrib - expense
    entries.append({
        "date": excel_date_to_iso(date_raw),
        "name": name,
        "contribution": contrib if contrib else 0,
        "expense": expense if expense else 0,
        "balance": running,
    })

out = {
    "title": rows[0][0] if rows and rows[0] else "",
    "subtitle": rows[0][0] if rows and rows[0] else "",
    "entries": entries,
}

if __name__ == "__main__":
    print(json.dumps(out, indent=2))
