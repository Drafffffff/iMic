#!/usr/bin/env python3
"""Generate the bilingual changelog pages from docs/releases/changelog.json.

    python3 tools/site-changelog.py          # write site/changelog/ and site/en/changelog/
    python3 tools/site-changelog.py --check  # fail if the pages are out of date

Entries are curated, user-facing highlights; the full notes stay in
docs/releases/v<VERSION>.md and the GitHub Release. Newest first.
"""
import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'docs/releases/changelog.json'
BASE = 'https://drafffffff.github.io/iMic/'
RELEASES = 'https://github.com/Drafffffff/iMic/releases'

TEXT = {
    'zh': {
        'lang': 'zh-Hans', 'og': 'zh_CN', 'dir': 'changelog/', 'home': '../',
        'title': '更新日志 · VoxChord',
        'description': 'VoxChord 每个版本的主要更新：iPhone 与 Mac 的新功能、改进与修复。',
        'skip': '跳到正文', 'home_label': 'VoxChord 首页', 'nav_label': '主导航', 'footer_label': '页脚',
        'download': '下载', 'changelog': '更新日志',
        'h1': '更新日志',
        'intro': '每个版本的主要变化。建议 Mac 与 iPhone 保持同一版本；Mac 客户端会自动检查更新。',
        'full': '完整说明与安装包', 'older': '更早的版本（1.0–1.2）见',
        'older_link': 'GitHub Releases', 'privacy': '隐私说明', 'feedback': '反馈邮件',
        'date': lambda d: f'{int(d[:4])} 年 {int(d[5:7])} 月 {int(d[8:])} 日',
    },
    'en': {
        'lang': 'en', 'og': 'en_US', 'dir': 'en/changelog/', 'home': '../',
        'title': 'Changelog · VoxChord',
        'description': 'What changed in each VoxChord release: new features, improvements and fixes for iPhone and Mac.',
        'skip': 'Skip to content', 'home_label': 'VoxChord home', 'nav_label': 'Main navigation', 'footer_label': 'Footer',
        'download': 'Download', 'changelog': 'Changelog',
        'h1': 'Changelog',
        'intro': 'The main changes in each release. Keep your Mac and iPhone on the same version; the Mac app checks for updates automatically.',
        'full': 'Full notes and downloads', 'older': 'Older releases (1.0–1.2) are on',
        'older_link': 'GitHub Releases', 'privacy': 'Privacy', 'feedback': 'Feedback',
        'date': lambda d: ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
                           'September', 'October', 'November', 'December'][int(d[5:7]) - 1] + f' {int(d[8:])}, {d[:4]}',
    },
}


def load():
    entries = json.loads(DATA.read_text(encoding='utf-8'))
    seen = set()
    for entry in entries:
        version, date = entry['version'], entry['date']
        assert re.fullmatch(r'\d+\.\d+\.\d+', version), f'bad version {version}'
        assert re.fullmatch(r'\d{4}-\d{2}-\d{2}', date), f'{version}: bad date {date}'
        assert version not in seen, f'duplicate version {version}'
        seen.add(version)
        for lang in ('zh', 'en'):
            assert entry[lang] and all(isinstance(x, str) and x.strip() for x in entry[lang]), f'{version}: empty {lang}'
        assert len(entry['zh']) == len(entry['en']), f'{version}: zh/en item counts differ'
        assert not any(re.search('[㐀-鿿]', x) for x in entry['en']), f'{version}: Chinese in English entry'
    key = lambda e: tuple(int(p) for p in e['version'].split('.'))
    assert entries == sorted(entries, key=key, reverse=True), 'entries must be newest first'
    return entries


def page(lang, entries):
    t, e = TEXT[lang], html.escape
    other = 'en' if lang == 'zh' else 'zh'
    url, other_url = BASE + t['dir'], BASE + TEXT[other]['dir']
    home = t['home'] if lang == 'zh' else '../'
    assets = '../assets/' if lang == 'zh' else '../../assets/'
    switch = (f'<span class="language-choice"><span aria-hidden="true">中文 / </span>'
              f'<a class="language-switch" href="../en/changelog/" lang="en" hreflang="en">EN</a></span>' if lang == 'zh' else
              f'<span class="language-choice"><a class="language-switch" href="../../changelog/" lang="zh-Hans" hreflang="zh-Hans">ZH</a>'
              f'<span aria-hidden="true"> / EN</span></span>')
    items = []
    for i, entry in enumerate(entries):
        v = entry['version']
        bullets = ''.join(f'<li>{e(x)}</li>' for x in entry[lang])
        latest = ' <span class="release-latest">LATEST</span>' if i == 0 else ''
        items.append(
            f'<article class="release" id="v{v}" aria-labelledby="v{v}-title">'
            f'<header class="release-meta"><h2 id="v{v}-title"><a href="#v{v}">{e(v)}</a>{latest}</h2>'
            f'<time datetime="{entry["date"]}">{e(t["date"](entry["date"]))}</time></header>'
            f'<div class="release-body"><ul>{bullets}</ul>'
            f'<a class="text-link" href="{RELEASES}/tag/v{v}">{e(t["full"])} ↗</a></div></article>')
    return f'''<!doctype html>
<html lang="{t['lang']}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#090909">
<title>{e(t['title'])}</title>
<meta name="description" content="{e(t['description'])}">
<link rel="canonical" href="{url}">
<meta property="og:type" content="website">
<meta property="og:locale" content="{t['og']}">
<meta property="og:title" content="{e(t['title'])}">
<meta property="og:description" content="{e(t['description'])}">
<meta property="og:image" content="{BASE}assets/icons/og.png">
<meta property="og:url" content="{url}">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" type="image/png" sizes="32x32" href="{assets}icons/favicon.png">
<link rel="apple-touch-icon" sizes="180x180" href="{assets}icons/apple-touch-icon.png">
<link rel="stylesheet" href="{assets}css/site.css">
<link rel="alternate" hreflang="zh-Hans" href="{BASE}changelog/">
<link rel="alternate" hreflang="en" href="{BASE}en/changelog/">
<link rel="alternate" hreflang="x-default" href="{BASE}changelog/">
</head>
<body class="changelog-page">
<a class="skip" href="#main">{e(t['skip'])}</a>
<header class="masthead shell"><a class="brand" href="{home}" aria-label="{e(t['home_label'])}"><img class="wordmark" src="{assets}pixel/imic.svg" alt="VoxChord" width="110" height="22"></a><nav aria-label="{e(t['nav_label'])}"><a href="./" aria-current="page">{e(t['changelog'])}</a><a href="{home}#download" class="nav-download">{e(t['download'])} <span aria-hidden="true">↗</span></a>{switch}</nav></header>
<main id="main" class="shell changelog">
<section class="section changelog-intro" aria-labelledby="changelog-title"><img class="pixel" src="{assets}pixel/changelog.svg" alt="" width="159" height="21"><h1 id="changelog-title">{e(t['h1'])}</h1><p>{e(t['intro'])}</p></section>
{chr(10).join(items)}
<p class="changelog-older">{e(t['older'])} <a href="{RELEASES}">{e(t['older_link'])} ↗</a></p>
</main>
<footer class="shell footer"><a class="brand" href="{home}" aria-label="{e(t['home_label'])}"><img class="wordmark" src="{assets}pixel/imic.svg" alt="VoxChord" width="110" height="22"></a><p>© 2026 VoxChord · <a href="https://github.com/Drafffffff/iMic/blob/codex/ui-phosphor-wireframe/LICENSE">GPL-3.0</a></p><nav aria-label="{e(t['footer_label'])}"><a href="https://github.com/Drafffffff/iMic">GitHub ↗</a><a href="https://github.com/Drafffffff/iMic/blob/codex/ui-phosphor-wireframe/docs/PRIVACY.md">{e(t['privacy'])}</a><a href="mailto:i0.0ia@qq.com">{e(t['feedback'])}</a></nav></footer>
</body>
</html>
'''


def main():
    check = sys.argv[1:] == ['--check']
    assert sys.argv[1:] in ([], ['--check']), 'usage: site-changelog.py [--check]'
    entries, stale = load(), []
    for lang in ('zh', 'en'):
        target = ROOT / 'site' / TEXT[lang]['dir'] / 'index.html'
        content = page(lang, entries)
        if check:
            if not target.is_file() or target.read_text(encoding='utf-8') != content:
                stale.append(str(target.relative_to(ROOT)))
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding='utf-8')
            print(f'wrote {target.relative_to(ROOT)} ({len(entries)} releases)')
    if stale:
        sys.exit('Changelog pages out of date; run python3 tools/site-changelog.py: ' + ', '.join(stale))


if __name__ == '__main__':
    main()
