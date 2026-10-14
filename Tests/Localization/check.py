#!/usr/bin/env python3
"""Check UI catalog completeness, placeholder parity and static code references."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[2]
catalog = json.loads((root / 'Mangar/Localization/Localizable.xcstrings').read_text())
entries = catalog['strings']
assert catalog['sourceLanguage'] == 'zh-Hans'
for key, entry in entries.items():
    assert set(entry['localizations']) == {'zh-Hans', 'en', 'ja'}, key
    formats = []
    for language, value in entry['localizations'].items():
        unit = value['stringUnit']
        assert unit['state'] == 'translated' and unit['value'], (key, language)
        formats.append(re.findall(r'%(?:%|@)', unit['value']))
    assert formats[0] == formats[1] == formats[2], (key, formats)
    assert not re.search(r'[\u3400-\u9fff]', entry['localizations']['en']['stringUnit']['value']), key

references = set()
for path in (root / 'Mangar').rglob('*.swift'):
    for match in re.finditer(r'L10n\.(?:text|format)\("((?:\\.|[^"\\])*)"', path.read_text()):
        value = match.group(1)
        if '\\(' not in value:
            references.add(json.loads('"' + value + '"'))
assert references <= entries.keys(), references - entries.keys()
for mode in ['normal', 'multiply', 'screen', 'overlay', 'darken', 'lighten', 'softLight', 'hardLight', 'difference', 'add']:
    assert 'blend.' + mode + '.short' in entries
for language in ['zh-Hans', 'en', 'ja']:
    names = [entries['blend.' + mode + '.short']['localizations'][language]['stringUnit']['value'] for mode in ['normal', 'multiply', 'screen', 'overlay', 'darken', 'lighten', 'softLight', 'hardLight', 'difference', 'add']]
    assert len(set(names)) == len(names), (language, names)
print(f'PASS: {len(entries)} entries, three complete languages, matching placeholders, code references, unique blend badges')
