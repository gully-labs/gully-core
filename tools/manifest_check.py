import hashlib, sys
m = sys.argv[1] if len(sys.argv) > 1 else 'docs/UPSTREAM-IDENTICAL.sha256'
bad = 0
for l in open(m):
    if l.startswith('#') or not l.strip(): continue
    h, f = l.split(None, 1); f = f.strip()
    if hashlib.sha256(open(f, 'rb').read().replace(b'\r', b'')).hexdigest() != h:
        bad += 1; print('CHANGED', f)
print('upstream-identical files changed:', bad)
sys.exit(1 if bad else 0)
