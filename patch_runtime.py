"""Avoid the desktop-only builtin-loader addon in the pinned mobile payload."""
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


def patch(payload):
    root = Path(payload).resolve()
    package = root / 'node_modules/@deepseek-ai/dsh-app-boot'
    if json.loads((package / 'package.json').read_text(encoding='utf-8'))['version'] != '0.2.1-rc.5':
        raise ValueError('This adapter is limited to the reviewed dsh version')
    changes = []
    # Validate both inputs before mutating either file.
    planned = []
    for name in FILES:
        path = package / name
        data = path.read_bytes()
        text = data.decode('utf-8')
        if text.count(OLD) != 1 or NEW in text:
            raise ValueError(f'Unexpected upstream source or already patched: {name}')
        updated = text.replace(OLD, NEW).encode('utf-8')
        planned.append((path, updated))
        changes.append({'file': name, 'before_sha256': hashlib.sha256(data).hexdigest(),
                        'after_sha256': hashlib.sha256(updated).hexdigest()})
    for path, updated in planned:
        path.write_bytes(updated)
    (root / 'iphone-adapter-report.json').write_text(json.dumps(changes, indent=2), encoding='utf-8')
    print('Applied two explicit mobile adapter changes; upstream package version unchanged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('payload', type=Path)
    patch(parser.parse_args().payload)
