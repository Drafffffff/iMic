#!/usr/bin/env python3
"""Generate sitemap.xml and the JSON-LD block of the two home pages.

    python3 tools/site-seo.py          # write site/sitemap.xml and update JSON-LD in place
    python3 tools/site-seo.py --check  # fail if either is out of date

No FAQPage: Google shows FAQ rich results only for well-known government and
health sites, so it would add page weight without benefit. Standard library only.
"""
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / 'site'
BASE = 'https://drafffffff.github.io/iMic/'
APP_STORE = 'https://apps.apple.com/app/id6829771739'
RELEASES = 'https://github.com/Drafffffff/iMic/releases/latest'
GITHUB = 'https://github.com/Drafffffff/iMic'
START = '<script type="application/ld+json" id="structured-data">'
END = '</script>'

# Each page pair: zh path, en path (relative to BASE). x-default is Chinese, as in the pages.
PAGES = [('', 'en/'), ('changelog/', 'en/changelog/')]

COPY = {
    'zh': {'lang': 'zh-Hans', 'file': 'index.html', 'url': BASE,
           'site': 'VoxChord 官网',
           'ios': '按住 iPhone 说话，文字直接落进 Mac 光标处。Mac mini、Mac Studio 没有麦克风也能语音输入，支持 AI 润色和多台 Mac 切换。',
           'mac': 'VoxChord 的免费 Mac 客户端：接收 iPhone 的语音，完成识别与可选的 AI 润色，并输入到当前应用。'},
    'en': {'lang': 'en', 'file': 'en/index.html', 'url': BASE + 'en/',
           'site': 'VoxChord',
           'ios': 'Hold your iPhone, speak, and the words land at your Mac\'s cursor. Voice typing for Mac mini and Mac Studio with no microphone, with AI polish and multi-Mac switching.',
           'mac': 'The free VoxChord Mac app: it receives speech from your iPhone, recognizes and optionally polishes it, and types into the front app.'},
}


def mac_version():
    feed = (SITE / 'appcast.xml').read_text(encoding='utf-8')
    versions = re.findall(r'<sparkle:shortVersionString>([\d.]+)</sparkle:shortVersionString>', feed)
    assert versions, 'appcast has no versions'
    return max(versions, key=lambda v: tuple(int(p) for p in v.split('.')))


def structured(lang):
    c = COPY[lang]
    graph = [
        {'@type': 'WebSite', '@id': BASE + '#website', 'name': 'VoxChord', 'alternateName': c['site'],
         'url': BASE, 'inLanguage': ['zh-Hans', 'en']},
        {'@type': 'SoftwareApplication', '@id': BASE + '#ios', 'name': 'VoxChord',
         'operatingSystem': 'iOS 17.0 or later', 'applicationCategory': 'ProductivityApplication',
         'description': c['ios'], 'url': c['url'], 'installUrl': APP_STORE,
         'image': BASE + 'assets/icons/icon-512.png',
         'offers': {'@type': 'Offer', 'price': '2.99', 'priceCurrency': 'USD', 'url': APP_STORE}},
        {'@type': 'SoftwareApplication', '@id': BASE + '#mac', 'name': 'VoxChord for Mac',
         'operatingSystem': 'macOS 13.0 or later', 'applicationCategory': 'ProductivityApplication',
         'description': c['mac'], 'url': c['url'], 'downloadUrl': RELEASES, 'softwareVersion': mac_version(),
         'image': BASE + 'assets/icons/icon-512.png', 'license': 'https://www.gnu.org/licenses/gpl-3.0.html',
         'offers': {'@type': 'Offer', 'price': '0', 'priceCurrency': 'USD'}, 'sameAs': [GITHUB]},
    ]
    data = json.dumps({'@context': 'https://schema.org', '@graph': graph}, ensure_ascii=False, separators=(',', ':'))
    # Keep the block inert inside HTML.
    return START + data.replace('</', '<\\/') + END


def with_jsonld(lang):
    path = SITE / COPY[lang]['file']
    source = path.read_text(encoding='utf-8')
    block = structured(lang)
    if START in source:
        a = source.index(START)
        b = source.index(END, a) + len(END)
        return path, source[:a] + block + source[b:]
    assert '</head>' in source
    return path, source.replace('</head>', block + '\n</head>', 1)


def sitemap():
    ns = 'http://www.sitemaps.org/schemas/sitemap/0.9'
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             f'<urlset xmlns="{ns}" xmlns:xhtml="http://www.w3.org/1999/xhtml">']
    for zh, en in PAGES:
        for path in (zh, en):
            assert (SITE / path / 'index.html').is_file(), f'missing page {path}'
            lines.append(f'  <url><loc>{BASE}{path}</loc>')
            for lang, target in (('zh-Hans', zh), ('en', en), ('x-default', zh)):
                lines.append(f'    <xhtml:link rel="alternate" hreflang="{lang}" href="{BASE}{target}"/>')
            lines.append('  </url>')
    lines.append('</urlset>')
    content = '\n'.join(lines) + '\n'
    ET.fromstring(content)
    return SITE / 'sitemap.xml', content


def main():
    assert sys.argv[1:] in ([], ['--check']), 'usage: site-seo.py [--check]'
    check = bool(sys.argv[1:])
    outputs = [with_jsonld('zh'), with_jsonld('en'), sitemap()]
    stale = []
    for path, content in outputs:
        current = path.read_text(encoding='utf-8') if path.is_file() else None
        if current == content:
            continue
        if check:
            stale.append(str(path.relative_to(ROOT)))
        else:
            path.write_text(content, encoding='utf-8')
            print(f'wrote {path.relative_to(ROOT)}')
    if stale:
        sys.exit('SEO files out of date; run python3 tools/site-seo.py: ' + ', '.join(stale))


if __name__ == '__main__':
    main()
