import json
from pathlib import Path
import tempfile
import unittest
from release_manifest import write_manifest


class ReleaseManifestTests(unittest.TestCase):
    def test_the_manifest_identifies_exactly_the_dmg_that_will_be_published(self):
        with tempfile.TemporaryDirectory() as directory:
            dmg = Path(directory) / 'TMflash-1.5.0-universal.dmg'
            dmg.write_bytes(b'koly' + bytes(508))
            manifest = write_manifest(dmg, '1.5.0', 'a' * 40, False, '14.0', 'tmsense-1.8', False)
            self.assertEqual(manifest['size'], 512)
            self.assertEqual(manifest['tag'], 'build-' + 'a' * 40)
            self.assertEqual(manifest['architectures'], ['arm64', 'x86_64'])
            self.assertFalse(manifest['sourceModified'])
            self.assertEqual(json.loads((dmg.parent / 'tmflash-app.json').read_text()), manifest)
            before = manifest['sha256']
            dmg.write_bytes(b'koly' + bytes(507) + b'1')
            self.assertNotEqual(write_manifest(dmg, '1.5.0', 'a' * 40, True, '14.0', 'tmsense-1.8', False)['sha256'], before)

    def test_an_unidentified_or_invalid_image_cannot_be_published(self):
        with tempfile.TemporaryDirectory() as directory:
            dmg = Path(directory) / 'TMflash-1.5.0-universal.dmg'
            dmg.write_bytes(bytes(512))
            with self.assertRaises(ValueError):
                write_manifest(dmg, '1.5.0', 'a' * 40, False, '14.0', 'tmsense-1.8', False)
            dmg.write_bytes(b'koly' + bytes(508))
            with self.assertRaises(ValueError):
                write_manifest(dmg, '1.5.0', 'short', False, '14.0', 'tmsense-1.8', False)


if __name__ == '__main__':
    unittest.main()
