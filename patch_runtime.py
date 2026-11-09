"""Adapt the pinned Harness loader and session locking for the iPhone host."""
import argparse
import hashlib
import json
from pathlib import Path

FILES = ('lib/index.js', 'lib/worker/profile-resolution-bootstrap.js')
OLD = 'const addon = createRequire(import.meta.url)("node-addon-require-builtin");'
NEW = '''// iPhone adapter: Node starts with --expose-internals; no desktop addon.
\tconst exposedRequire = createRequire(import.meta.url);
\tconst addon = process.execArgv.includes("--expose-internals")
\t\t? { requireBuiltin: (id) => exposedRequire(id) }
\t\t: exposedRequire("node-addon-require-builtin");'''
FLOCK_PACKAGE = '@deepseek-ai/node-addon-system'
FLOCK_FILE = 'lib/flock.js'
FLOCK_OLD = '''    const errno = await new Promise((resolve) => {
        loadBinding().tryLock(fd, resolve);
    });'''
FLOCK_NEW = '''    const native = process.platform === 'ios' ? globalThis[Symbol.for('iphone-harness.flock')] : undefined;
    const errno = native ? await native(fd) : await new Promise((resolve) => {
        loadBinding().tryLock(fd, resolve);
    });'''


def patch(payload):
    root = Path(payload).resolve()
    loader = '@deepseek-ai/dsh-app-boot'
    packages = root / 'node_modules'
    for package, version in ((loader, '0.2.1-rc.5'), (FLOCK_PACKAGE, '0.1.2')):
        if json.loads((packages / package / 'package.json').read_text(encoding='utf-8'))['version'] != version:
            raise ValueError(f'Unexpected upstream version: {package}')
    changes = []
    # Validate every input before mutating any file.
    planned = []
    edits = [(loader, name, OLD, NEW) for name in FILES]
    edits.append((FLOCK_PACKAGE, FLOCK_FILE, FLOCK_OLD, FLOCK_NEW))
    for package, name, before, after in edits:
        path = packages / package / name
        data = path.read_bytes()
        text = data.decode('utf-8')
        if text.count(before) != 1 or after in text:
            raise ValueError(f'Unexpected upstream source or already patched: {package}/{name}')
        updated = text.replace(before, after).encode('utf-8')
        planned.append((path, updated))
        changes.append({'package': package, 'file': name, 'before_sha256': hashlib.sha256(data).hexdigest(),
                        'after_sha256': hashlib.sha256(updated).hexdigest()})
    for path, updated in planned:
        path.write_bytes(updated)
    (root / 'iphone-adapter-report.json').write_text(json.dumps(changes, indent=2), encoding='utf-8')
    print('Applied two loader adapters and one iOS file-lock adapter')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('payload', type=Path)
    patch(parser.parse_args().payload)
