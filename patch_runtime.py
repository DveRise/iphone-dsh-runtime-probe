"""Adapt the pinned Harness loader, session locking and settings for iPhone."""
import argparse
import hashlib
import json
import re
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
MODELS_PACKAGE = '@deepseek-ai/dsh-client-ui-settings-models'
MODELS_FILE = 'lib/client.js'


def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError(f'Unexpected upstream source: {before.splitlines()[0]}')
    return text.replace(before, after, 1)


def patch_models(text):
    text = replace_once(text, 'tag.textContent = css$3;',
                        'tag.textContent = css$3 + ".iphone-key-clear,.iphone-key-preview,.iphone-key-toggle-label{display:none}";')
    text = replace_once(text, 'if (ENV_LINE.test(value) || isQuoted(value)) return "keyIllegalCharacters";',
                        '''if (ENV_LINE.test(value)) return "keyHasAssignment";
\t\t\tif (isQuoted(value)) return "keyHasQuotes";
\t\t\tif (/\\s/.test(value)) return "keyHasSpaces";''')
    begin = text.index('\t\tfunction ApiKeyInput(')
    end = text.index('\n\t\t//#endregion', begin)
    field = text[begin:end]
    field = replace_once(field, 'function ApiKeyInput({ value, t, ...props })',
                         'function ApiKeyInput({ value, t, onClear, ...props })')
    field = replace_once(field, '''const [revealedValue, setRevealedValue] = (0, react.useState)();
\t\t\tconst revealed = value.length > 0 && revealedValue === value;''', '''const [show, setShow] = (0, react.useState)(false);
\t\t\tconst input = (0, react.useRef)(null);
\t\t\tconst revealed = value.length > 0 && show;''')
    field = replace_once(field, 'autoComplete: "new-password",', '''ref: input,
\t\t\t\t\tautoComplete: "off",
\t\t\t\t\tautoCapitalize: "none",
\t\t\t\t\tautoCorrect: "off",
\t\t\t\t\tspellCheck: false,''')
    field = replace_once(field, 'setRevealedValue(void 0);', 'if (event.target.value.length === 0) setShow(false);')
    field = replace_once(field, 'setRevealedValue(revealed ? void 0 : value);', 'setShow(!revealed);')
    field = replace_once(field, 'children: (0, react_jsx_runtime.jsx)("svg", {', '''children: [
\t\t\t\t\t\t(0, react_jsx_runtime.jsx)("span", {
\t\t\t\t\t\t\tclassName: "iphone-key-toggle-label",
\t\t\t\t\t\t\tchildren: t(revealed ? "keyHide" : "keyReveal")
\t\t\t\t\t\t}),
\t\t\t\t\t\t(0, react_jsx_runtime.jsx)("svg", {''')
    field = replace_once(field, '''\n\t\t\t\t\t})
\t\t\t\t})]
\t\t\t});''', '''
\t\t\t\t\t})]
\t\t\t\t}), value.length === 0 ? null : (0, react_jsx_runtime.jsx)("button", {
\t\t\t\t\ttype: "button", className: "iphone-key-clear", disabled: props.disabled,
\t\t\t\t\tonClick: () => { setShow(false); onClear(); input.current?.focus(); },
\t\t\t\t\tchildren: t("keyClearDraft")
\t\t\t\t}), revealed ? (0, react_jsx_runtime.jsx)("code", {
\t\t\t\t\tclassName: "iphone-key-preview", "aria-hidden": true, children: value
\t\t\t\t}) : null]
\t\t\t});''')
    text = text[:begin] + field + text[end:]
    text, count = re.subn(r'(\(0, react_jsx_runtime\.jsx\)\(ApiKeyInput, \{\n)(\t+)t,',
                          r'\1\2onClear: () => setKeyDraft(""),\n\2t,', text)
    if count != 2:
        raise ValueError('Unexpected API key input call sites')
    text = replace_once(text, 'keyIllegalCharacters: "This API key is not in a valid format. Please check it.",',
                        '''keyIllegalCharacters: "The key contains an unsupported character. Copy the full key from your provider.",
\t\t\tkeyHasAssignment: "Paste just the key, without the variable name or equals sign.",
\t\t\tkeyHasQuotes: "Remove the quotes around the key.",
\t\t\tkeyHasSpaces: "The key contains spaces or line breaks. Copy it again as one line.",
\t\t\tkeyClearDraft: "Clear input",''')
    text = replace_once(text, 'keyIllegalCharacters: "该 API 密钥格式错误，请检查。",',
                        '''keyIllegalCharacters: "密钥含有不支持的字符。请从服务平台重新复制完整密钥。",
\t\t\tkeyHasAssignment: "请只粘贴密钥本身，去掉变量名和等号。",
\t\t\tkeyHasQuotes: "请去掉密钥两端的引号。",
\t\t\tkeyHasSpaces: "密钥中有空格或换行，请重新复制为一整行。",
\t\t\tkeyClearDraft: "清空输入",''')
    for before, after in (
        ('Leave blank to use env as auth ({hint})', 'Paste the API key'),
        ('Env var not detected. Enter an API key, or configure {hint} in your env.', 'Copy the full key from your model provider and paste it here.'),
        ('留空使用环境认证（{hint}）', '粘贴 API 密钥'),
        ('未检测到环境变量。请填写 API 密钥，或设置环境变量 {hint}。', '请从模型服务平台复制完整密钥，再粘贴到这里。'),
        ('留空使用已保存凭据', '粘贴新密钥，或留空保留旧密钥'),
    ):
        text = replace_once(text, before, after)
    return text


def patch(payload):
    root = Path(payload).resolve()
    loader = '@deepseek-ai/dsh-app-boot'
    packages = root / 'node_modules'
    for package, version in ((loader, '0.2.1-rc.5'), (FLOCK_PACKAGE, '0.1.2'),
                             (MODELS_PACKAGE, '0.2.1-rc.5')):
        if json.loads((packages / package / 'package.json').read_text(encoding='utf-8'))['version'] != version:
            raise ValueError(f'Unexpected upstream version: {package}')
    changes = []
    # Validate every input before mutating any file.
    planned = []
    edits = [(loader, name, OLD, NEW) for name in FILES]
    edits.append((FLOCK_PACKAGE, FLOCK_FILE, FLOCK_OLD, FLOCK_NEW))
    edits.append((MODELS_PACKAGE, MODELS_FILE, None, None))
    for package, name, before, after in edits:
        path = packages / package / name
        data = path.read_bytes()
        text = data.decode('utf-8')
        updated = (patch_models(text) if before is None else replace_once(text, before, after)).encode('utf-8')
        planned.append((path, updated))
        changes.append({'package': package, 'file': name, 'before_sha256': hashlib.sha256(data).hexdigest(),
                        'after_sha256': hashlib.sha256(updated).hexdigest()})
    for path, updated in planned:
        path.write_bytes(updated)
    (root / 'iphone-adapter-report.json').write_text(json.dumps(changes, indent=2), encoding='utf-8')
    print('Applied loader, iOS file-lock and phone settings adapters')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('payload', type=Path)
    patch(parser.parse_args().payload)
