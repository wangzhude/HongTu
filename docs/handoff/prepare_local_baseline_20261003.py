"""Save actual current bytes and the sealed R16 artifacts to local Git."""
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
META = ROOT / '.git' / 'codex-parallel17'
META.mkdir(exist_ok=True)

def git(*args, raw=False):
    r = subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, check=True)
    return r.stdout if raw else r.stdout.decode('utf-8', errors='replace').strip()

assert git('rev-parse', '--show-toplevel').replace('\\', '/').casefold() == ROOT.as_posix().casefold()
assert git('branch', '--show-current') == 'master'
assert not git('remote'), 'Local baseline must not alter or use any remote'
manifest = ROOT / 'docs/validation/closure16-20261003/publication-integrity.json'
assert hashlib.sha256(manifest.read_bytes()).hexdigest().upper() == '8BEA3C490D42EC2BD8650C88DCE777EFBCF34D080513A3EDEFF1E3150CE68A96'
artifacts = json.loads(manifest.read_text(encoding='utf-8'))['artifacts']
assert len(artifacts) == 6411
exclude = ROOT / '.git/info/exclude'
old = exclude.read_text(encoding='utf-8')
extra = ['/*.obj', '/*.pdb', '**/__pycache__/', '**/*.pyc', '**/.pytest_cache/',
         '/python/.venv/', '**/.venv/', '/python/.env', '/signing/', '/credentials/']
missing = [v for v in extra if v not in old.splitlines()]
if missing:
    with exclude.open('a', encoding='utf-8', newline='\n') as f:
        f.write('\n# Local parallel-development exclusions; preserve sealed .gitignore\n' + '\n'.join(missing) + '\n')
tracked_raw = git('ls-files', '-z', raw=True)
tracked = [v.decode('utf-8') for v in tracked_raw.split(b'\0') if v]
others_raw = git('ls-files', '--others', '--exclude-standard', '-z', raw=True)
others = [v.decode('utf-8') for v in others_raw.split(b'\0') if v]
sealed = [r['path'] for r in artifacts] + [manifest.relative_to(ROOT).as_posix()]
allnames = sorted(set(tracked + others + sealed))
blocked = []
secret = re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|sk-(?:proj|svcacct)-[A-Za-z0-9_-]{24,}')
text_ext = {'.py', '.ps1', '.sh', '.js', '.mjs', '.cjs', '.ts', '.ets', '.cpp', '.h', '.inc', '.md', '.txt', '.json', '.json5', '.toml', '.yaml', '.yml', '.xml', '.lyrdb'}
for name in allnames:
    p = (ROOT / name).resolve()
    assert p.is_relative_to(ROOT), 'Do not stage outside repository'
    if not p.exists():
        continue  # tracked deletion remains explicit Git pathspec
    if p.suffix.lower() in {'.p12', '.pfx', '.jks', '.keystore', '.key'} or p.name == '.env':
        blocked.append(name)
    elif p.suffix.lower() in text_ext and secret.search(p.read_bytes()):
        blocked.append(name)
assert not blocked, 'Credential-like content blocked at paths: ' + ', '.join(blocked)
for row in artifacts:
    p = ROOT / row['path']
    assert p.is_file() and p.stat().st_size == row['bytes']
    assert hashlib.sha256(p.read_bytes()).hexdigest().upper() == row['sha256'].upper(), 'Sealed bytes drifted: ' + row['path']
git('config', '--local', 'core.autocrlf', 'false')
for label, names in [('tracked', tracked), ('ordinary', others), ('sealed', sealed)]:
    path = META / (label + '.nul')
    assert not path.exists(), 'Preserve previous staging inventory'
    path.write_bytes(b'\0'.join(v.encode('utf-8') for v in names) + b'\0')
    args = ['add']
    if label == 'tracked':
        args.append('--renormalize')
    if label == 'sealed':
        args.append('-f')
    args.extend(['--pathspec-from-file=' + str(path), '--pathspec-file-nul'])
    git(*args)
receipt = {'passed': True, 'scope': 'Local index contains actual bytes of sources/documents and all immutable R16 artifacts; no remote/push.',
           'trackedPaths': len(tracked), 'ordinaryPaths': len(others), 'sealedPaths': len(sealed),
           'uniqueCandidatePaths': len(allnames), 'credentialLikePaths': blocked,
           'sealedManifestSha256': hashlib.sha256(manifest.read_bytes()).hexdigest().upper(),
           'coreAutocrlf': git('config', '--local', '--get', 'core.autocrlf')}
(META / 'staging-receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
print(json.dumps(receipt))
