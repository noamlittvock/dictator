"""Appcast contract: synthetic zip metadata and a mocked Sparkle tool; no keys/network."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/make-appcast.sh'


class MakeAppcastTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.dd'
        scratch.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='appcast-tests-', dir=scratch)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / 'Dictator release.zip'
        self.output = self.root / 'output'
        self.output.mkdir()
        self.log = self.root / 'tool.json'
        self.tool = self.root / 'generate_appcast'
        self.tool.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys, urllib.parse
folder = pathlib.Path(sys.argv[-1])
archives = list(folder.glob('*.zip'))
pathlib.Path(os.environ['TOOL_LOG']).write_text(json.dumps({
    'args': sys.argv[1:], 'archives': [p.name for p in archives],
    'inode': archives[0].stat().st_ino,
}))
if os.environ.get('TOOL_FAIL'):
    sys.exit(7)
prefix = sys.argv[sys.argv.index('--download-url-prefix') + 1]
url = prefix + urllib.parse.quote(archives[0].name)
minimum = os.environ.get('TOOL_MINIMUM', '14.0')
signature = '' if os.environ.get('TOOL_UNSIGNED') else ' sparkle:edSignature="fixture-signature"'
(folder / 'appcast.xml').write_text(f\'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><item><sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
<enclosure url="{url}"{signature}/></item></channel></rss>\''')
''')
        self.tool.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(SPARKLE_GENERATE_APPCAST=str(self.tool), TOOL_LOG=str(self.log))
        self.write_zip()

    def write_zip(self, **overrides):
        info = {'LSMinimumSystemVersion': '14.0', 'CFBundleVersion': '2',
                'SUPublicEDKey': 'fixture-public-key'}
        info.update(overrides)
        with zipfile.ZipFile(self.archive, 'w') as archive:
            archive.writestr('Dictator.app/Contents/Info.plist', plistlib.dumps(info))

    def run_script(self, *args):
        return subprocess.run(['/bin/bash', str(SCRIPT), *map(str, args)],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def generate(self):
        return self.run_script(self.archive, 'v1.2.3', self.output)

    def assert_rejected_before_tool(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.log.exists())
        self.assertFalse((self.output / 'appcast.xml').exists())

    def test_argument_count(self):
        for args in [(), (self.archive,), (self.archive, 'v1', self.output, 'extra')]:
            result = self.run_script(*args)
            self.assertEqual(result.returncode, 2)
            self.assertIn('Usage:', result.stderr)

    def test_missing_zip(self):
        self.assert_rejected_before_tool(self.run_script(self.root / 'missing.zip', 'v1'))

    def test_non_zip(self):
        other = self.root / 'archive.dmg'
        other.write_text('fixture')
        self.assert_rejected_before_tool(self.run_script(other, 'v1'))

    def test_invalid_tag(self):
        for tag in ['../latest', '', '--account', 'v1;echo unexpected', 'v1 with spaces']:
            self.assert_rejected_before_tool(self.run_script(self.archive, tag))

    def test_missing_output_directory(self):
        self.assert_rejected_before_tool(self.run_script(self.archive, 'v1', self.root / 'missing'))

    def test_existing_appcast_preserved(self):
        target = self.output / 'appcast.xml'
        target.write_text('existing')
        result = self.generate()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), 'existing')
        self.assertFalse(self.log.exists())

    def test_missing_generator(self):
        self.env['SPARKLE_GENERATE_APPCAST'] = str(self.root / 'missing-tool')
        self.assert_rejected_before_tool(self.generate())

    def test_invalid_zip(self):
        self.archive.write_text('not a zip')
        self.assert_rejected_before_tool(self.generate())

    def test_missing_or_unresolved_metadata(self):
        for overrides in [{'LSMinimumSystemVersion': ''}, {'LSMinimumSystemVersion': '$(MACOSX_DEPLOYMENT_TARGET)'},
                          {'CFBundleVersion': ''}, {'SUPublicEDKey': ''},
                          {'SUPublicEDKey': '$(DICTATOR_SPARKLE_PUBLIC_KEY)'}]:
            self.write_zip(**overrides)
            self.assert_rejected_before_tool(self.generate())

    def test_multiple_apps_rejected(self):
        with zipfile.ZipFile(self.archive, 'a') as archive:
            archive.writestr('Other.app/Contents/Info.plist', plistlib.dumps({}))
        self.assert_rejected_before_tool(self.generate())

    def test_success_uses_keychain_account_and_immutable_release_url_without_copying_zip(self):
        before = self.archive.read_bytes()
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.output / 'appcast.xml').is_file())
        log = json.loads(self.log.read_text())
        self.assertEqual(log['args'][:6], ['--account', 'dictator', '--download-url-prefix',
                         'https://github.com/noamlittvock/dictator/releases/download/v1.2.3/',
                         '--maximum-deltas', '0'])
        self.assertEqual(log['archives'], [self.archive.name])
        self.assertEqual(log['inode'], self.archive.stat().st_ino)
        self.assertEqual(self.archive.read_bytes(), before)
        self.assertFalse(list(self.root.glob('.appcast.*')))
        self.assertIn('nothing uploaded', result.stdout)

    def test_default_output_beside_zip(self):
        result = self.run_script(self.archive, 'v1.2.3')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / 'appcast.xml').is_file())

    def test_generator_failure_leaves_no_output_or_staging(self):
        self.env['TOOL_FAIL'] = '1'
        result = self.generate()
        self.assertEqual(result.returncode, 7)
        self.assertFalse((self.output / 'appcast.xml').exists())
        self.assertFalse(list(self.root.glob('.appcast.*')))

    def test_mismatched_minimum_rejected(self):
        self.env['TOOL_MINIMUM'] = '13.0'
        result = self.generate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('minimumSystemVersion does not match', result.stderr)
        self.assertFalse((self.output / 'appcast.xml').exists())

    def test_unsigned_feed_rejected(self):
        self.env['TOOL_UNSIGNED'] = '1'
        result = self.generate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no EdDSA signature', result.stderr)
        self.assertFalse((self.output / 'appcast.xml').exists())


if __name__ == '__main__':
    unittest.main()
