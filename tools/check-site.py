#!/usr/bin/env python3
"""Dependency-free Pages validation (also runs on the GitHub hosted runner)."""
from appcast import validate as validate_appcast
import re
import struct
import sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

root = Path(sys.argv[1] if len(sys.argv) > 1 else 'site').resolve()
errors, external, refs, documents = [], set(), [], {}

def require(condition, message):
    if not condition: errors.append(message)

if (root / 'appcast.xml').exists():
    try: validate_appcast(root / 'appcast.xml')
    except (ValueError, OSError, ET.ParseError) as error: require(False, f'appcast.xml: {error}')

class Page(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.path, self.ids, self.h1, self.lang = path, set(), 0, None
        self.feed(path.read_text())
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'html': self.lang = a.get('lang')
        if tag == 'h1': self.h1 += 1
        if 'id' in a:
            require(a['id'] not in self.ids, f'{self.path.name}: duplicate id {a["id"]}')
            self.ids.add(a['id'])
        if tag in ('img', 'video'):
            require('alt' in a or bool(a.get('aria-label')), f'{self.path.name}: {tag} missing accessible description')
        if tag == 'video':
            require(all(key in a for key in ('muted', 'loop', 'playsinline', 'poster')), f'{self.path.name}: incomplete video attributes')
            require(a.get('preload') == 'none' and 'src' not in a and a.get('data-src'), f'{self.path.name}: video must lazy load')
        if tag == 'img' and a.get('loading') != 'lazy' and 'hero' not in a.get('src', '') and 'pixel/' not in a.get('src', ''):
            require(False, f'{self.path.name}: non-hero image must lazy load')
        if tag == 'link' and a.get('rel') in ('canonical',):
            external.add(a.get('href', ''))
        for key in ('src', 'href', 'poster', 'data-src', 'data-mobile-src', 'data-mobile-poster'):
            if a.get(key): refs.append((self.path, a[key], tag, key, a))
        if a.get('srcset'):
            for src in a['srcset'].split(','): refs.append((self.path, src.strip().split()[0], tag, 'src', a))
    handle_startendtag = handle_starttag

require(root.is_dir(), 'site directory missing')
require((root/'.nojekyll').is_file(), '.nojekyll missing')
require((root/'robots.txt').is_file(), 'robots.txt missing')
for path in sorted(root.rglob('*.html')):
    page = Page(path)
    documents[path] = page
    require(page.h1 == 1, f'{path.name}: expected exactly one h1, got {page.h1}')
    expected_language = 'en' if path.parent.name == 'en' else 'zh-Hans'
    require(page.lang == expected_language, f'{path}: lang must be {expected_language}')

def resolve(path, url):
    p = unquote(urlsplit(url).path)
    if p.startswith('/iMic/'): target = root / p.removeprefix('/iMic/')
    elif p.startswith('/'): target = root / p.lstrip('/')
    else: target = path.parent / p if p else path
    if target.is_dir(): target /= 'index.html'
    target = target.resolve()
    require(target.is_relative_to(root), f'{path.name}: resource escapes site: {url}')
    return target

for path, url, tag, key, a in refs:
    parsed = urlsplit(url)
    if parsed.scheme or parsed.netloc:
        require(parsed.scheme in ('https', 'mailto'), f'{path.name}: unsupported URL {url}')
        external.add(url)
        asset = tag in ('script', 'img', 'video', 'source') or (tag == 'link' and a.get('rel') not in ('canonical', 'alternate'))
        require(not asset, f'{path.name}: external resource forbidden: {url}')
        continue
    target = resolve(path, url)
    require(target.is_file(), f'{path.name}: missing resource {url}')
    if parsed.fragment and target in documents:
        require(unquote(parsed.fragment) in documents[target].ids, f'{path.name}: missing anchor {url}')
for path in root.rglob('*.css'):
    for url in re.findall(r'url\([\'\"]?([^\)\'\"]+)', path.read_text()):
        require(not urlsplit(url).scheme, f'{path.name}: external CSS asset {url}')
        require(resolve(path,url).is_file(), f'{path.name}: missing CSS asset {url}')
for path in root.rglob('*.js'):
    source = path.read_text()
    require(not re.search(r'\b(?:localStorage|sessionStorage)\b|document\.cookie', source), f'{path.name}: storage/tracking forbidden')
    external.update(re.findall(r'https://[^\s"\'`<>]+',source))
index = (root/'index.html').read_text()
for value in ('canonical', 'og:title', 'og:description', 'og:image', 'og:url', 'twitter:card', 'apple-touch-icon'):
    require(value in index, f'index.html: missing metadata {value}')
require('id="download"' in index, 'download anchor missing')
for anchor in ('feel', 'modes', 'anywhere', 'private', 'start', 'faq'):
    require(anchor in documents[root/'index.html'].ids, f'Missing section/legacy anchor: {anchor}')
require(re.findall(r'<section\b[^>]*\bid="([^"]+)"', index) ==
        ['anywhere', 'feel', 'modes', 'private', 'download', 'faq'],
        'ANYWHERE must be the first section after HERO')
nav = re.search(r'<nav aria-label="主导航">(.*?)</nav>', index, re.S)
require(nav is not None and 'href="#anywhere"' in nav[1], 'Scenario navigation missing')
anywhere = re.search(r'<section id="anywhere".*?</section>', index, re.S)
require(anywhere is not None, 'ANYWHERE missing')
if anywhere:
    scene = anywhere[0]
    require('试试' not in scene and '示意动画' in scene, 'Scenario copy must be clear and identify the illustration')
    require('role="img" aria-label=' in scene and 'class="field-grid" aria-hidden="true"' in scene,
            'Illustration needs one accessible description, with animated text hidden')
    fields = re.findall(r'class="field-text" data-text="([^"]+)">([^<]+)</span>', scene)
    require(len(fields) == 6 and all(text == fallback for text, fallback in fields),
            'Six fields need complete static fallback text')
faq = re.search(r'<section id="faq".*?</section>', index, re.S)
require(faq is not None, 'FAQ missing')
if faq:
    # Caveats live in the FAQ so the page itself stays short; they must not disappear.
    answers = faq[0]
    require('辅助功能权限' in answers and '前台应用变化' in answers and '不自动输入' in answers,
            'Permission and app-switch limitations missing from FAQ')
    require('实时预览、润色扫光与清空效果因应用而异' in answers and '拒绝清空' in answers,
            'Enhanced feature limitations missing from FAQ')
    require('换行会替换为空格' in answers and '按回车' in answers, 'Terminal behaviour missing from FAQ')
    require('macOS 14+' in answers and '屏幕录制' in answers, 'Polish highlight requirements missing from FAQ')
    require('手写' in answers and '不会自动执行' in answers, 'Polish example and terminal-mode notes missing from FAQ')
require('Mac 上任意输入框' in index and '一只手机，接管所有输入' in index, 'Slogan or any-field metadata missing')
for identifier in ('origin-banner', 'mac-download-link', 'share-link', 'release-meta', 'mobile-download-note', 'share-status', 'share-manual', 'checksum-link', 'testflight-pending', 'testflight-link'):
    require(identifier in documents[root/'index.html'].ids, f'Download contract missing: {identifier}')
require('data-hero-version' in index and index.count('data-dmg-link') >= 2, 'Download data attributes missing')
require('brand-dot' not in index, 'Duplicate brand dot')
require(index.count('class="feature"') == 3, 'FEEL must contain three features')
require('新安装默认开启实时预览' in index and '可能重复或误删' in index and '无法监视用户接管' in index, 'Live preview risk disclosure missing')
require('href="https://github.com/Drafffffff/iMic/releases/latest"' in index, 'no-JS release fallback missing')

# Bilingual pages share every asset and section, with explicit language navigation.
english = (root/'en/index.html').read_text()
for filename, source, language in [('index.html', index, 'zh-Hans'), ('en/index.html', english, 'en')]:
    for lang in ['zh-Hans','en','x-default']:
        require(f'hreflang="{lang}"' in source, f'{filename}: missing alternate {lang}')
    require('class="language-switch"' in source, f'{filename}: language switch missing')
    for value in ['og:title','og:description','og:url','twitter:card','data-template','data-demo-toggle']:
        require(value in source, f'{filename}: missing {value}')
    require('?from=ios#download' in source, f'{filename}: missing iPhone deep link')
require(re.findall(r'<section\b[^>]*\bid="([^"]+)"', english) == re.findall(r'<section\b[^>]*\bid="([^"]+)"',index), 'English section structure differs')
require(not re.search('[\u3400-\u9fff]', re.sub(r'>中文<', '>ZH<', english)), 'Untranslated Chinese in English page')
require('/ap-southeast-1/model/settings/api-key' in english and 'Singapore' in english and 'Free Quota Only' in english, 'International Key guidance missing')
require('may duplicate or delete text by mistake' in english and 'refuse clearing' in english and 'does not type automatically' in english, 'English risk warnings missing')
require('id="language-banner"' in index, 'English suggestion missing')
require(not (root/'en/assets').exists(), 'English must share assets')

files = [p for p in root.rglob('*') if p.is_file()]
code = sum(p.stat().st_size for p in files if p.suffix in ('.html','.css','.js'))
poster = root/'assets/img/hero.webp'
poster_size = poster.stat().st_size if poster.is_file() else 0
# Conservative startup envelope: all HTML/CSS/JS, all pixel labels and all icons
# (even OG, which normal browsers don't request), plus both hero poster formats.
startup = code + sum(p.stat().st_size for p in files if '/pixel/' in str(p) or '/icons/' in str(p) or p.name in ('hero.webp','hero.png','hero-mobile.webp','hero-mobile.png'))
total = sum(p.stat().st_size for p in files)
budgets = [('HTML + CSS + JS',code,150_000),('Hero poster WebP',poster_size,200_000),('First-screen envelope (no video)',startup,1_000_000),('site total',total,15_000_000)]
for label,size,limit in budgets:
    print(f'{label}: {size:,} bytes / {limit:,} bytes')
    require(size <= limit, f'{label} over budget: {size} > {limit}')
require(poster_size > 0, 'hero poster missing')
def boxes(data, start=0, end=None):
    """Yield (type, payload_start, payload_end) for ISO-BMFF boxes in data[start:end]."""
    end = len(data) if end is None else end
    while start + 8 <= end:
        size, kind = struct.unpack_from('>I4s', data, start)
        header = 8
        if size == 1:
            size, header = struct.unpack_from('>Q', data, start + 8)[0], 16
        elif size == 0:
            size = end - start
        if size < header:
            return
        yield kind.decode('latin-1'), start + header, start + size
        start += size

def child(data, parent, kind):
    for name, a, b in boxes(data, *parent):
        if name == kind:
            return a, b
    return None

def video_fps(data):
    moov = next(((a, b) for k, a, b in boxes(data) if k == 'moov'), None)
    for kind, a, b in boxes(data, *moov):
        if kind != 'trak':
            continue
        mdia = child(data, (a, b), 'mdia')
        hdlr = child(data, mdia, 'hdlr')
        if data[hdlr[0] + 8:hdlr[0] + 12] != b'vide':
            continue
        mdhd = child(data, mdia, 'mdhd')
        version = data[mdhd[0]]
        timescale = struct.unpack_from('>I', data, mdhd[0] + (20 if version == 1 else 12))[0]
        stbl = child(data, child(data, mdia, 'minf'), 'stbl')
        stts = child(data, stbl, 'stts')
        count = struct.unpack_from('>I', data, stts[0] + 4)[0]
        frames = ticks = 0
        for i in range(count):
            n, delta = struct.unpack_from('>II', data, stts[0] + 8 + i * 8)
            frames += n; ticks += n * delta
        return frames / (ticks / timescale) if ticks else 0
    return 0

# Demo videos: hero ≤3 MB, others ≤2.5 MB; ≤13s; 60fps; only sound.mp4 carries audio.
expected_videos = {'hero', 'hero-mobile', 'string', 'polish', 'sound'}
require({p.stem for p in root.rglob('*.mp4')} == expected_videos, 'Unexpected/missing demo videos')
for path in sorted(root.rglob('*.mp4')):
    data=path.read_bytes()
    limit = 1_500_000 if path.stem == 'hero-mobile' else 3_000_000 if path.stem == 'hero' else 2_500_000
    require(len(data)<=limit, f'{path.name}: video exceeds {limit:,} bytes')
    has_audio = b'soun' in data
    require(b'avc1' in data, f'{path.name}: expected H.264')
    require(has_audio == (path.name == 'sound.mp4'), f'{path.name}: audio track only allowed in sound.mp4')
    moov, mdat = data.find(b'moov'), data.find(b'mdat')
    require(0 <= moov < mdat, f'{path.name}: missing faststart')
    mvhd = data.find(b'mvhd')
    require(mvhd >= 0, f'{path.name}: missing duration')
    if mvhd >= 0:
        version=data[mvhd+4]
        offset=mvhd+(24 if version==1 else 16)
        scale=struct.unpack_from('>I',data,offset)[0]
        duration=struct.unpack_from('>Q' if version==1 else '>I',data,offset+4)[0]/scale
        require(0<duration<=13.05, f'{path.name}: duration {duration:.3f}s outside budget')
        fps = video_fps(data)
        require(abs(fps - 60) < 0.5, f'{path.name}: {fps:.2f} fps, expected 60')
        print(f'Video {path.name}: {duration:.2f}s · {fps:.0f}fps · {len(data):,} bytes / {limit:,} bytes · H.264 · faststart · {"AAC audio" if has_audio else "silent"}')
# PNG header dimensions; no image library required in CI.
og=root/'assets/icons/og.png'
if og.is_file():
    require(struct.unpack('>II',og.read_bytes()[16:24])==(1200,630),'OG image must be 1200×630')
else: require(False,'OG image missing')
print('\nExternal links (navigation/API only):')
for link in sorted(external):print('  '+link)
if errors:
    print('\nFAILED:\n'+'\n'.join('  '+e for e in errors),file=sys.stderr)
    sys.exit(1)
print(f'\nPASS: {len(documents)} HTML pages, {len(files)} files, local references, anchors, accessibility attributes and budgets.')
