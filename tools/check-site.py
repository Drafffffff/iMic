#!/usr/bin/env python3
"""Dependency-free Pages validation (also runs on the GitHub hosted runner)."""
import re
import struct
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

root = Path(sys.argv[1] if len(sys.argv) > 1 else 'site').resolve()
errors, external, refs, documents = [], set(), [], {}

def require(condition, message):
    if not condition: errors.append(message)

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
        for key in ('src', 'href', 'poster', 'data-src'):
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
    require(page.lang == 'zh-Hans', f'{path.name}: lang must be zh-Hans')

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
        asset = tag in ('script', 'img', 'video', 'source') or (tag == 'link' and a.get('rel') not in ('canonical',))
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
require('href="https://github.com/Drafffffff/iMic/releases/latest"' in index, 'no-JS release fallback missing')

files = [p for p in root.rglob('*') if p.is_file()]
code = sum(p.stat().st_size for p in files if p.suffix in ('.html','.css','.js'))
poster = root/'assets/img/hero.webp'
poster_size = poster.stat().st_size if poster.is_file() else 0
# Conservative startup envelope: all HTML/CSS/JS, all pixel labels and all icons
# (even OG, which normal browsers don't request), plus both hero poster formats.
startup = code + sum(p.stat().st_size for p in files if '/pixel/' in str(p) or '/icons/' in str(p) or p.name in ('hero.webp','hero.png'))
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

# Demo videos: hero ≤3 MB, others ≤2.5 MB; ≤12s; 60fps; only sound.mp4 carries audio.
for path in sorted(root.rglob('*.mp4')):
    data=path.read_bytes()
    limit = 3_000_000 if path.name.startswith('hero') else 2_500_000
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
        require(0<duration<=12.05, f'{path.name}: duration {duration:.3f}s outside budget')
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
