import base64
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('appcast', ROOT / 'tools/appcast.py')
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(dir=ROOT / 'build', prefix='updater-unit-')
        self.root = Path(self.work.name)
        for name in ('mac', 'site', 'scripts', 'tools'):
            (self.root / name).mkdir()
        for name in ('scripts/package-release.sh', 'tools/appcast.py', 'site/appcast.xml', 'VERSION', 'MAC_BUILD', 'mac/sparkle-public-key.txt'):
            shutil.copyfile(ROOT / name, self.root / name)
        self.feed = self.root / 'site/appcast.xml'
        self.signature = base64.b64encode(b's' * 64).decode()
        (self.root / 'test.dmg').write_bytes(b'final stapled archive fixture')
        (self.root / 'notes.md').write_text('Update <script> & details')

    def tearDown(self):
        self.work.cleanup()

    def preflight(self):
        return subprocess.run(['bash', str(self.root / 'scripts/package-release.sh'), '--check-only'], capture_output=True, text=True)

    def valid_key(self):
        (self.root / 'mac/sparkle-public-key.txt').write_text(base64.b64encode(b'p' * 32).decode())

    def update(self, build=1):
        return subprocess.run(['python3', str(ROOT / 'tools/appcast.py'), 'update', str(self.feed), str(build), '1.4.4', str(self.root / 'test.dmg'), self.signature, str(self.root / 'notes.md')], capture_output=True, text=True)

    def test_empty_channel_is_valid(self):
        self.assertEqual(appcast.validate(self.feed).findall('./channel/item'), [])

    def test_placeholder_blocks_package_before_work(self):
        p = self.preflight()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('占位值', p.stderr)
        self.assertFalse((self.root / 'build').exists())

    def test_dry_run_valid_inputs_does_not_build(self):
        self.valid_key()
        p = self.preflight()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('未构建、签名或发布', p.stdout)
        self.assertFalse((self.root / 'build').exists())

    def test_unchanged_build_blocks_package(self):
        self.valid_key()
        self.assertEqual(self.update(1).returncode, 0)
        p = self.preflight()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('请先将构建号加 1', p.stderr)

    def test_same_version_replaces_signature_length_and_build(self):
        self.assertEqual(self.update(1).returncode, 0)
        self.signature = base64.b64encode(b'n' * 64).decode()
        (self.root / 'test.dmg').write_bytes(b'a new final archive')
        self.assertEqual(self.update(2).returncode, 0)
        items = appcast.validate(self.feed).findall('./channel/item')
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].findtext(f'{{{appcast.NS}}}version'), '2')
        self.assertEqual(items[0].find('enclosure').get('length'), '19')
        self.assertEqual(items[0].find('enclosure').get(f'{{{appcast.NS}}}edSignature'), self.signature)
        self.assertIn('&lt;script&gt;', items[0].findtext('description'))

    def test_older_build_cannot_overwrite_feed(self):
        self.assertEqual(self.update(8).returncode, 0)
        before = self.feed.read_bytes()
        self.assertNotEqual(self.update(7).returncode, 0)
        self.assertEqual(before, self.feed.read_bytes())

    def test_missing_signature_length_version_and_wrong_download_are_rejected(self):
        self.assertEqual(self.update(1).returncode, 0)
        original = self.feed.read_bytes()
        for field in ('signature', 'length', 'version', 'url'):
            with self.subTest(field=field):
                tree = ET.ElementTree(ET.fromstring(original))
                item = tree.find('./channel/item'); enc = item.find('enclosure')
                if field == 'signature': enc.attrib.pop(f'{{{appcast.NS}}}edSignature')
                elif field == 'length': enc.attrib.pop('length')
                elif field == 'version': item.remove(item.find(f'{{{appcast.NS}}}version'))
                else: enc.set('url', 'https://attacker.example/update.dmg')
                tree.write(self.feed)
                with self.assertRaises((ValueError, TypeError)):
                    appcast.validate(self.feed)

    def test_malformed_xml_is_rejected(self):
        self.feed.write_text('<rss><channel>')
        with self.assertRaises(ET.ParseError): appcast.validate(self.feed)


if __name__ == '__main__': unittest.main(verbosity=2)
