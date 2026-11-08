"""Release contracts: synthetic bundles, no signing keys or Apple services."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
IDENTITY = 'A' * 40
SECOND = 'B' * 40
TEAM = 'ABCDE12345'


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dictator-release-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        self.calls_file = self.root / 'calls.jsonl'
        self.app = self.root / 'build/Build/Products/Release/Dictator.app'
        (self.app / 'Contents').mkdir(parents=True)
        with (self.app / 'Contents/Info.plist').open('wb') as f:
            plistlib.dump(dict(CFBundleIdentifier='dev.noamlitt.dictator', CFBundleDisplayName='Dictator',
                               CFBundleShortVersionString='1.2.3'), f)
        self.binary('Contents/MacOS/Dictator')
        self.binary('Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle')
        self.binary('Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader')
        self.binary('Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Updater.app/Contents/MacOS/Updater')
        self.binary('Contents/Frameworks/libExample.dylib')
        self.binary('Contents/Helpers/extensionless helper')
        framework = self.app / 'Contents/Frameworks/Sparkle.framework'
        (framework / 'Versions/Current').symlink_to('B', target_is_directory=True)
        (framework / 'Sparkle').symlink_to('Versions/Current/Sparkle')
        (self.app / 'Contents/Resources').mkdir()
        (self.app / 'Contents/Resources/not-code').write_text('resource')
        resource_bundle = self.app / 'Contents/Resources/WhisperKit_WhisperKit.bundle'
        resource_bundle.mkdir()
        (resource_bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundlePackageType': 'BNDL'}))
        code_bundle = self.app / 'Contents/PlugIns/Example.bundle'
        code_bundle.mkdir(parents=True)
        (code_bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Example'}))
        self.binary('Contents/PlugIns/Example.bundle/Example')
        shim = self.tools / 'shim'
        shim.write_text('#!' + sys.executable + '\n' + r'''
import json, os, pathlib, plistlib, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ['MOCK_CALLS'], 'a') as f:
    f.write(json.dumps([name] + args) + '\n')
if name == 'security':
    for i in range(int(os.environ['MOCK_IDENTITIES'])):
        print(f'  {i+1}) {chr(65+i)*40} "Developer ID Application: Example {i} (ABCDE12345)"')
elif name == 'codesign':
    if '--verbose=4' in args:
        runtime = '0x10000(runtime)' if os.environ.get('MOCK_RUNTIME', '1') == '1' else '0x0(none)'
        print('CodeDirectory v=20500 size=74273 flags=' + runtime, file=sys.stderr)
        print('Executable Segment flags=' + os.environ.get('MOCK_EXEC_FLAGS', '0x1'), file=sys.stderr)
        print('TeamIdentifier=' + os.environ.get('MOCK_TEAM', 'ABCDE12345'), file=sys.stderr)
    if '--entitlements' in args and '-d' in args:
        values = {'com.apple.security.device.audio-input': True, 'com.apple.security.automation.apple-events': True}
        values.pop(os.environ.get('MOCK_MISSING_ENTITLEMENT', ''), None)
        sys.stdout.buffer.write(plistlib.dumps(values))
elif name == 'xcrun':
    if args[:2] == ['notarytool', 'history'] and os.environ.get('MOCK_CREDENTIALS', '1') == '0':
        sys.exit(1)
    if args[:2] == ['notarytool', 'submit']:
        print(json.dumps({'id': 'submission-123', 'status': os.environ.get('MOCK_NOTARY_STATUS', 'Accepted')}))
        sys.exit(int(os.environ.get('MOCK_SUBMIT_EXIT', '0')))
    if args[:2] == ['notarytool', 'log']:
        print('synthetic notary rejection log')
elif name == 'ditto':
    pathlib.Path(args[-1]).write_bytes(b'synthetic zip with staple')
''')
        shim.chmod(0o755)
        for name in ('security', 'xcodebuild', 'codesign', 'xcrun', 'ditto', 'spctl'):
            (self.tools / name).symlink_to(shim)
        self.env = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ['PATH'],
                        HOME=str(self.root), DICTATOR_BUILD_DIR=str(self.root / 'build'),
                        MOCK_CALLS=str(self.calls_file), MOCK_IDENTITIES='1')
        for key in ('DICTATOR_SIGN_IDENTITY', 'DICTATOR_NOTARY_PROFILE'):
            self.env.pop(key, None)

    def binary(self, relative):
        path = self.app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(bytes.fromhex('cffaedfe') + b'synthetic code')

    def run_release(self, *args):
        self.env.setdefault('DICTATOR_SPARKLE_PUBLIC_KEY', 'synthetic-public-key')
        return subprocess.run(['/bin/bash', str(ROOT / 'scripts/release.sh'), *args], env=self.env,
                              capture_output=True, text=True, timeout=20)

    def calls(self, command=None):
        calls = [json.loads(line) for line in self.calls_file.read_text().splitlines()]
        return [call for call in calls if command is None or call[0] == command]

    def test_release_without_update_key_is_refused_before_build(self):
        self.env['DICTATOR_SPARKLE_PUBLIC_KEY'] = ''
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('DICTATOR_SPARKLE_PUBLIC_KEY', result.stderr)
        self.assertEqual(self.calls('xcodebuild'), [])

    def test_signing_check_allows_an_empty_update_key(self):
        self.env['DICTATOR_SPARKLE_PUBLIC_KEY'] = ''
        result = self.run_release('--skip-notarize')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('DICTATOR_SPARKLE_PUBLIC_KEY=', self.calls('xcodebuild')[0])

    def test_build_carries_the_update_key_and_a_rising_build_number(self):
        result = self.run_release('--skip-notarize')
        self.assertEqual(result.returncode, 0, result.stderr)
        build = self.calls('xcodebuild')[0]
        self.assertIn('DICTATOR_SPARKLE_PUBLIC_KEY=synthetic-public-key', build)
        number = next(arg for arg in build if arg.startswith('CURRENT_PROJECT_VERSION='))
        self.assertRegex(number, r'^CURRENT_PROJECT_VERSION=[0-9]{12}$')

    def test_project_generation_keeps_the_release_entitlements(self):
        # `xcodegen generate` rewrites the entitlements file from project.yml.
        project = (ROOT / 'swift-client/project.yml').read_text()
        with (ROOT / 'swift-client/Dictator/Dictator.entitlements').open('rb') as f:
            entitlements = plistlib.load(f)
        for key in ('com.apple.security.device.audio-input', 'com.apple.security.automation.apple-events'):
            self.assertIs(entitlements.get(key), True, key)
            self.assertIn(key + ': true', project)

    def test_third_party_notices_are_complete_and_ship_in_the_app(self):
        notices = (ROOT / 'THIRD_PARTY_NOTICES.md').read_text(encoding='utf8')
        for text in ('Copyright (c) 2024 argmax, inc.', 'Copyright 2022 Hugging Face SAS.', 'Andy Matuschak',
                     'bsdiff', 'The Anton Project Authors', 'The Jost Project Authors',
                     'SIL Open Font License, Version 1.1'):
            self.assertIn(text, notices)
        self.assertIn('- path: ../THIRD_PARTY_NOTICES.md', (ROOT / 'swift-client/project.yml').read_text())

    def test_missing_identity_fails_before_build(self):
        self.env['MOCK_IDENTITIES'] = '0'
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Xcode > Settings > Accounts > Manage Certificates', result.stderr)
        self.assertEqual(self.calls('xcodebuild'), [])

    def test_multiple_identities_require_selection(self):
        self.env['MOCK_IDENTITIES'] = '2'
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('DICTATOR_SIGN_IDENTITY', result.stderr)
        self.assertEqual(self.calls('xcodebuild'), [])

    def test_explicit_identity_selects_one_of_multiple(self):
        self.env.update(MOCK_IDENTITIES='2', DICTATOR_SIGN_IDENTITY=SECOND)
        result = self.run_release('--skip-notarize')
        self.assertEqual(result.returncode, 0, result.stderr)
        for call in self.calls('codesign'):
            if '--sign' in call:
                self.assertEqual(call[call.index('--sign') + 1], SECOND)

    def test_local_identity_override_is_refused(self):
        self.env['DICTATOR_SIGN_IDENTITY'] = 'Dictator Local Code Signing'
        result = self.run_release('--skip-notarize')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('valid Developer ID Application', result.stderr)
        self.assertEqual(self.calls('xcodebuild'), [])

    def test_missing_notary_credential_explains_setup(self):
        self.env['MOCK_CREDENTIALS'] = '0'
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("notarytool store-credentials 'dictator'", result.stderr)
        self.assertEqual(self.calls('xcodebuild'), [])

    def test_nested_code_signs_inside_out_without_deep(self):
        result = self.run_release('--skip-notarize')
        self.assertEqual(result.returncode, 0, result.stderr)
        signed = [call for call in self.calls('codesign') if '--sign' in call]
        paths = [Path(call[-1]) for call in signed]
        self.assertEqual(paths[-1], self.app)
        self.assertEqual(len(paths), len(set(paths)))
        for index, path in enumerate(paths):
            for later in paths[index+1:]:
                self.assertNotIn(path, later.parents, f'container signed before child: {path}, {later}')
        self.assertTrue(any(p.suffix == '.xpc' for p in paths))
        self.assertTrue(any(p.suffix == '.dylib' for p in paths))
        self.assertTrue(any(p.name == 'Example.bundle' for p in paths))
        self.assertFalse(any(p.name == 'WhisperKit_WhisperKit.bundle' for p in paths))
        self.assertTrue(any(p.name == 'extensionless helper' for p in paths))
        self.assertFalse(any('Current' in p.parts for p in paths))
        for call in signed:
            self.assertNotIn('--deep', call)
            self.assertIn('--timestamp', call)
            self.assertEqual(call[call.index('--options') + 1], 'runtime')
        self.assertIn('--entitlements', signed[-1])
        self.assertTrue(all('--preserve-metadata=entitlements' in call for call in signed[:-1]))
        self.assertEqual(self.calls('xcrun'), [])
        self.assertEqual(self.calls('ditto'), [])
        self.assertIn('not been notarized', result.stdout)
        build = self.calls('xcodebuild')[0]
        for setting in ('CODE_SIGNING_ALLOWED=NO', 'ENABLE_HARDENED_RUNTIME=YES',
                        'PRODUCT_BUNDLE_IDENTIFIER=dev.noamlitt.dictator', 'DICTATOR_DISPLAY_NAME=Dictator'):
            self.assertIn(setting, build)
        self.assertEqual(build[build.index('-configuration') + 1], 'Release')
        self.assertEqual(build[build.index('-destination') + 1], 'platform=macOS,arch=arm64')
        self.assertNotIn('-arch', build)

    def test_missing_entitlements_refuse_handoff(self):
        for key in ('com.apple.security.device.audio-input', 'com.apple.security.automation.apple-events'):
            with self.subTest(key=key):
                self.env['MOCK_MISSING_ENTITLEMENT'] = key
                result = self.run_release('--skip-notarize')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('missing entitlement ' + key, result.stderr)
                self.assertNotIn('SIGNED_APP=', result.stdout)

    def test_runtime_and_team_are_checked(self):
        for overrides, message in (({'MOCK_RUNTIME': '0'}, 'hardened runtime flag'),
                                   ({'MOCK_RUNTIME': '0', 'MOCK_EXEC_FLAGS': '0x10000'}, 'hardened runtime flag'),
                                   ({'MOCK_TEAM': 'not set'}, 'TeamIdentifier')):
            with self.subTest(overrides=overrides):
                result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/release.sh'), '--skip-notarize'],
                                        env=dict(self.env, **overrides), capture_output=True, text=True, timeout=20)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_notary_rejection_prints_log_and_does_not_staple(self):
        for exit_status in ('0', '1'):
            with self.subTest(exit_status=exit_status):
                self.env.update(MOCK_NOTARY_STATUS='Invalid', MOCK_SUBMIT_EXIT=exit_status)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('synthetic notary rejection log', result.stdout)
                self.assertIn('not accepted', result.stderr)
                self.assertFalse(any(c[1:3] == ['stapler', 'staple'] for c in self.calls('xcrun')))
                self.assertNotIn('RELEASE_ARCHIVE=', result.stdout)

    def test_accepted_release_staples_assesses_then_rezips_and_hashes(self):
        self.env['DICTATOR_NOTARY_PROFILE'] = 'custom-profile'
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        staple = next(i for i, c in enumerate(calls) if c[1:3] == ['stapler', 'staple'])
        validate = next(i for i, c in enumerate(calls) if c[1:3] == ['stapler', 'validate'])
        assess = next(i for i, c in enumerate(calls) if c[0] == 'spctl')
        zips = [i for i, c in enumerate(calls) if c[0] == 'ditto']
        self.assertLess(zips[0], staple)
        self.assertLess(staple, validate)
        self.assertLess(validate, assess)
        self.assertLess(assess, zips[-1])
        submit = next(c for c in calls if c[1:3] == ['notarytool', 'submit'])
        self.assertIn('--wait', submit)
        self.assertIn('custom-profile', submit)
        archive = self.root / 'build/releases/Dictator-1.2.3-macOS-arm64.zip'
        self.assertTrue(archive.exists())
        self.assertIn('RELEASE_ARCHIVE=' + str(archive), result.stdout)
        import hashlib
        self.assertIn(hashlib.sha256(archive.read_bytes()).hexdigest(), result.stdout)
        self.assertTrue(all(c[1:5] == ['-c', '-k', '--keepParent', str(self.app)] for c in self.calls('ditto')))


if __name__ == '__main__':
    unittest.main()
