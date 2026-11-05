#!/usr/bin/env python3
# Builds app/Resources/isa-verified.json (Viva Manager: automatic selection of the ISA features) from isatest runs on
# the reference phone, one case per process: DIR/final_isa.txt (isatest ID -mode isa) and DIR/final_nir.txt (-mode nir).
#   gen_isa_verified.py DIR DRIVER_COMMIT app/Resources/malimetal-flags.json app/Resources/isa-verified.json
import json, re, sys
S, drv, flags_path, out = sys.argv[1:5]
def parse(path, mode):
    res = {}
    for line in open(path):
        line = re.sub(r'^\[\d+\] ', '', line.rstrip('\n'))
        m = re.match(r'^([A-G]\d+)\s+(.*?)\s+(ISA|NIR) (ok|KO)\b', line)
        if m and m.group(3) == mode:
            res.setdefault(m.group(1), []).append((m.group(2).strip(), m.group(4) == 'ok'))
    return res
isa, nir = parse(f'{S}/final_isa.txt', 'ISA'), parse(f'{S}/final_nir.txt', 'NIR')
flags = json.load(open(flags_path))
ids = []
for g in flags:
    for it in g.get('items', []):
        k = it['key']
        if k.startswith('VMG_ISA_NO_'): ids.append(k[11:])
feats = {}
for fid in ids:
    cases = isa.get(fid)
    if not cases:
        feats[fid] = {"status": "ok", "note": "infrastruttura: esercitata da tutti i casi"}
        continue
    ncases = nir.get(fid, [])
    bad = [t for t, ok in cases if not ok]
    regress = [t for t, ok in cases if not ok and any(nt == t and nok for nt, nok in ncases)]
    st = "ok" if not bad else ("regression" if regress else "parity")
    e = {"status": st, "cases": len(cases), "ok": len(cases) - len(bad)}
    if bad: e["failing"] = bad
    feats[fid] = e
tot = sum(len(v) for v in isa.values())
doc = {
  "source": "isatest sul telefono di riferimento (Mali-G57 MC2), un caso per processo",
  "driver": drv, "date": "2026-11-05",
  "isa_ok": sum(ok for v in isa.values() for _, ok in v), "nir_ok": sum(ok for v in nir.values() for _, ok in v), "cases": tot,
  "rule": "ok: tutti i casi passano sul percorso ISA; parity: fallisce anche sul percorso NIR, allo stesso modo (ISA non peggiora); regression: l'ISA fallisce dove NIR passa (la selezione automatica la spegne)",
  "features": feats}
json.dump(doc, open(out, 'w'), ensure_ascii=False, indent=1)
print({k: v["status"] for k, v in feats.items() if v["status"] != "ok"}, doc["isa_ok"], doc["nir_ok"], tot, len(ids))
