import base64
import copy
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

import personal_appcast as m


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.archive = Path(self.temp.name) / 'TypeWhisper-personal.dmg'
        self.archive.write_bytes(b'fixture archive')
        self.info = {'CFBundleIdentifier': 'com.typewhisper.mac', 'CFBundleVersion': '42',
                     'CFBundleShortVersionString': '1.6', 'LSMinimumSystemVersion': '15.0'}
        self.manifest = {'repository': m.REPO, 'tag': 'personal-20260925-120000-run42-attempt1'}
        signature = base64.b64encode(bytes(64)).decode()
        self.signature = f'sparkle:edSignature="{signature}" length="15"'

    def generate(self, previous=None):
        return m.generate(self.archive, self.info, self.manifest, self.signature, previous)

    def test_points_to_exact_personal_asset_with_signature_and_build_number(self):
        root = ET.fromstring(self.generate())
        item = root.find('./channel/item')
        self.assertEqual(item.findtext(f'{{{m.SPARKLE}}}version'), '42')
        self.assertEqual(item.find('enclosure').get('url'),
                         f"https://github.com/{m.REPO}/releases/download/{self.manifest['tag']}/TypeWhisper-personal.dmg")
        self.assertEqual(item.find('enclosure').get('length'), '15')

    def test_idempotent_same_archive_and_version(self):
        original = self.generate()
        self.assertEqual(self.generate(original), original)

    def test_run_attempt_versions_compare_numerically(self):
        self.info['CFBundleVersion'] = '42.2'
        original = self.generate()
        self.info['CFBundleVersion'] = '42.10'
        self.generate(original)
        self.info['CFBundleVersion'] = '43.1'
        self.generate(original)

    def test_rejects_rollback_or_different_archive_at_same_version(self):
        original = self.generate()
        self.info['CFBundleVersion'] = '41'
        with self.assertRaisesRegex(ValueError, 'newer'):
            self.generate(original)
        self.info['CFBundleVersion'] = '42'
        self.manifest['tag'] = 'personal-20260925-130000-run43-attempt1'
        with self.assertRaisesRegex(ValueError, 'different archive'):
            self.generate(original)

    def test_rejects_wrong_signature_size_archive_length_and_upstream_repo(self):
        for bad in ['sparkle:edSignature="AA==" length="15"', self.signature.replace('15', '16')]:
            with self.assertRaises(ValueError):
                m.generate(self.archive, self.info, self.manifest, bad)
        self.manifest['repository'] = 'TypeWhisper/typewhisper-mac'
        with self.assertRaises(ValueError):
            self.generate()

    def test_rejects_development_bundle_and_nonmonotonic_version_format(self):
        self.info['CFBundleIdentifier'] = 'com.typewhisper.mac.dev'
        with self.assertRaises(ValueError):
            self.generate()
        self.info['CFBundleIdentifier'] = 'com.typewhisper.mac'
        self.info['CFBundleVersion'] = '$(CURRENT_PROJECT_VERSION)'
        with self.assertRaises(ValueError):
            self.generate()


if __name__ == '__main__':
    unittest.main()
