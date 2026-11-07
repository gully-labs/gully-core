import json, os, sys
out, pkg, prof = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
for root, dirs, files in os.walk(out):
    if 'build-info' in root: continue
    for f in files:
        if not f.endswith('.json'): continue
        p = os.path.join(root, f)
        try: j = json.load(open(p, encoding='utf-8'))
        except Exception: continue
        db = (j.get('deployedBytecode') or {}).get('object') or '0x'
        b = (j.get('bytecode') or {}).get('object') or '0x'
        rt = (len(db) - 2) // 2
        if rt <= 0: continue
        md = j.get('metadata') or {}
        tgt = (md.get('settings') or {}).get('compilationTarget') or {}
        src = next(iter(tgt.keys()), '?')
        name = next(iter(tgt.values()), f[:-5])
        runs = ((md.get('settings') or {}).get('optimizer') or {}).get('runs')
        rows.append((src, name, rt, (len(b)-2)//2, runs))
seen = set()
for src, name, rt, ic, runs in sorted(rows):
    k = (src, name, rt, runs)
    if k in seen: continue
    seen.add(k)
    print(f"{pkg}\t{prof}\t{src}\t{name}\t{rt}\t{ic}\t{24576-rt}\t{runs}")
