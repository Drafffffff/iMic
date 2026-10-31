#!/usr/bin/env python3
"""Validate release inputs and atomically replace a version's appcast entry. No network writes."""
import argparse
import base64
import binascii
import html
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
from email.utils import formatdate

NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
PREFIX = 'https://github.com/Drafffffff/iMic/releases/download/'
ET.register_namespace('sparkle', NS)


def public_key(path):
    value = Path(path).read_text().strip()
    try:
        if len(base64.b64decode(value, validate=True)) != 32:
            raise ValueError()
    except (ValueError, binascii.Error):
        raise ValueError('更新公钥是占位值或格式无效，请先配置发布者的 Ed25519 公钥。')
    return value


def load(path):
    tree = ET.parse(path)
    if tree.getroot().tag != 'rss' or tree.find('channel') is None:
        raise ValueError('appcast 必须包含 rss/channel。')
    return tree


def validate(path):
    tree = load(path)
    for item in tree.findall('./channel/item'):
        enclosure = item.find('enclosure')
        if enclosure is None:
            raise ValueError('appcast 条目缺少 enclosure。')
        attrs = enclosure.attrib
        signature = attrs.get(f'{{{NS}}}edSignature', '')
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError('appcast 条目缺少有效 edSignature。')
        if int(attrs.get('length', '0')) <= 0:
            raise ValueError('appcast 条目缺少有效 length。')
        build = item.findtext(f'{{{NS}}}version') or attrs.get(f'{{{NS}}}version', '')
        if not build.isascii() or not build.isdecimal() or int(build) <= 0:
            raise ValueError('appcast 条目缺少有效 sparkle:version。')
        if not attrs.get('url', '').startswith(PREFIX):
            raise ValueError('appcast 下载地址必须指向 iMic GitHub Releases。')
    return tree


def check_build(path, build):
    tree = validate(path)
    numbers = [int(i.findtext(f'{{{NS}}}version') or i.find('enclosure').get(f'{{{NS}}}version'))
               for i in tree.findall('./channel/item')]
    if build <= max(numbers, default=0):
        raise ValueError(f'BUILD {build} 未大于 appcast 最大构建号 {max(numbers)}，请先将构建号加 1（原地覆盖也必须递增）。')
    return tree


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    key = sub.add_parser('key'); key.add_argument('path')
    valid = sub.add_parser('validate'); valid.add_argument('path')
    for command in ('check-build', 'update'):
        p = sub.add_parser(command)
        p.add_argument('path'); p.add_argument('build', type=int)
        if command == 'update':
            p.add_argument('version'); p.add_argument('dmg'); p.add_argument('signature')
            p.add_argument('notes')
    a = parser.parse_args()
    if a.command == 'key': public_key(a.path)
    elif a.command == 'validate': validate(a.path)
    else:
        if a.build <= 0: raise ValueError('BUILD 必须为正整数。')
        tree = check_build(a.path, a.build)
        if a.command == 'update':
            channel = tree.find('channel')
            # A same-version overwrite replaces the old signature, length and build together.
            url = f'{PREFIX}v{a.version}/iMic-{a.version}-macOS-universal.dmg'
            for item in list(channel.findall('item')):
                enc = item.find('enclosure')
                version = item.findtext(f'{{{NS}}}shortVersionString')
                if version == a.version or enc.get('url') == url:
                    channel.remove(item)
            item = ET.Element('item')
            ET.SubElement(item, 'title').text = f'iMic {a.version} ({a.build})'
            ET.SubElement(item, 'pubDate').text = formatdate(usegmt=True)
            ET.SubElement(item, f'{{{NS}}}version').text = str(a.build)
            ET.SubElement(item, f'{{{NS}}}shortVersionString').text = a.version
            ET.SubElement(item, f'{{{NS}}}minimumSystemVersion').text = '13.0'
            # Embed escaped release-note text as safe HTML; no remote renderer is required.
            notes = Path(a.notes).read_text()
            ET.SubElement(item, 'description').text = '<pre>' + html.escape(notes) + '</pre>'
            ET.SubElement(item, 'enclosure', {'url': url, 'length': str(Path(a.dmg).stat().st_size),
                'type': 'application/octet-stream', f'{{{NS}}}edSignature': a.signature})
            channel.insert(0, item)
            temporary = Path(a.path).with_suffix('.xml.tmp')
            ET.indent(tree, space='  ')
            tree.write(temporary, encoding='utf-8', xml_declaration=True)
            validate(temporary)
            temporary.replace(a.path)


if __name__ == '__main__':
    try: main()
    except (ValueError, OSError, ET.ParseError, binascii.Error) as error:
        sys.exit(str(error))
