#!/usr/bin/env python3
"""Check exact bilingual coverage, generated resources, format types, and hard-coded Chinese."""
import collections, hashlib, importlib.util, json, pathlib, re, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); return mod
lexer = module('literals', 'tools/swift-literals.py')
generator = module('generator', 'tools/generate-l10n.py')
errors, counts, remaining = [], collections.Counter(), []
whitelist = json.loads((ROOT/'tools/l10n-exclusions.json').read_text())
used = collections.Counter()
for p in sorted([*ROOT.glob('mac/*.swift'), *ROOT.glob('ios/iMic/**/*.swift'), *ROOT.glob('shared/*.swift')]):
    source = p.read_text(); relative = str(p.relative_to(ROOT))
    for a,b,raw in lexer.tokens(source):
        if not re.search('[\u3400-\u9fff]',raw): continue
        digest = hashlib.sha256((relative+'\n'+raw).encode()).hexdigest()
        entry = whitelist.get(digest)
        line = source.count('\n',0,a)+1
        if entry:
            used[digest] += 1; counts[entry['reason']] += 1
            remaining.append(f'{relative}:{line}: {entry["reason"]}: {raw[:90].replace(chr(10), " ")}')
        else: errors.append(f'{relative}:{line}: unreviewed Chinese literal: {raw[:120]}')
for digest,entry in whitelist.items():
    if used[digest] != entry['count']: errors.append(f'Stale/changed exclusion: {entry["path"]} {digest[:12]} expected {entry["count"]}, got {used[digest]}')
fmt = re.compile(r'%(?:\d+\$)?(?:[-+0 #]*\d*(?:\.\d+)?)?(@|lld|ld|d|f|s|u)|%%')
for file in ['Localizable','InfoPlist']:
    data = json.loads((ROOT/f'ios/iMic/{file}.xcstrings').read_text())
    assert data['sourceLanguage'] == 'en'
    sets = {lang:set() for lang in ['en','zh-Hans']}
    for key,entry in data['strings'].items():
        for lang in sets:
            unit = entry.get('localizations',{}).get(lang,{}).get('stringUnit',{})
            if unit.get('state') != 'translated' or not unit.get('value'): errors.append(f'{file}:{key}: missing {lang}')
            else: sets[lang].add(key)
        values = [entry.get('localizations',{}).get(lang,{}).get('stringUnit',{}).get('value','') for lang in sets]
        if collections.Counter(fmt.findall(values[0])) != collections.Counter(fmt.findall(values[1])): errors.append(f'{file}:{key}: incompatible format placeholders')
    if sets['en'] != sets['zh-Hans']: errors.append(f'{file}: language key sets differ')
    print(f'{file}: {len(data["strings"])} keys, en = zh-Hans; format types match')
catalog_keys = set(json.loads((ROOT/'ios/iMic/Localizable.xcstrings').read_text())['strings'])
for p in [*ROOT.glob('mac/*.swift'), *ROOT.glob('ios/iMic/**/*.swift'), *ROOT.glob('shared/*.swift')]:
    for literal in re.findall(r'L10n.text\(("(?:[^"\\]|\\.)*")', p.read_text()):
        key = json.loads(literal)
        if key not in catalog_keys: errors.append(f'{p.relative_to(ROOT)}: missing catalog key {key}')
for path, expected in generator.outputs().items():
    if not path.exists() or path.read_text() != expected: errors.append(f'Outdated generated resource: {path.relative_to(ROOT)}')
print('Reviewed untranslated Chinese literals:')
for line in remaining: print('  '+line)
print('Exclusion counts: '+json.dumps(dict(counts),ensure_ascii=False))
print(f'Unreviewed hard-coded Chinese: {len(errors)}')
if errors:
    print('\n'.join(errors),file=sys.stderr);sys.exit(1)
print('PASS: bilingual keys, placeholders, generated resources and exact Chinese exclusions')
