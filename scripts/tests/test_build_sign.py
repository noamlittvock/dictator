"""Build-script contract with synthetic metadata and mocked signing/build tools."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'build-sign.sh'


class AppIntentsSigningContractTests(unittest.TestCase):
    def run_build(self, advertised, team='not set', apple_anchor=False, provider=False, malformed=False):
        with tempfile.TemporaryDirectory(prefix='dictator-sign-contract-') as temporary:
            root = Path(temporary)
            tools = root / 'tools'
            tools.mkdir()
            app = root / 'build/Build/Products/Debug/Dictator.app'
            metadata = app / 'Contents/Resources/Metadata.appintents'
            metadata.mkdir(parents=True)
            (metadata / 'extract.actionsdata').write_text(json.dumps({'actions': {
                name: {'isDiscoverable': name in advertised}
                for name in ['DictateIntent', 'CleanUpTextIntent', 'RunVoiceLaunchShortcutIntent']
            }, 'autoShortcuts': [{'actionIdentifier': 'CleanUpTextIntent'}] if provider else []}))
            if malformed:
                (metadata / 'extract.actionsdata').write_text('{invalid metadata')
            scripts = {
                'security': '#!/bin/sh\nprintf \'  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Dictator Local Code Signing"\\n     1 valid identities found\\n\'\n',
                'xcodebuild': '#!/bin/sh\necho "synthetic build complete"\n',
                'codesign': '''#!/bin/sh
case "$*" in
  *--test-requirement*)
    case "$*" in
      *'--test-requirement =anchor apple generic'*) exit "$MOCK_ANCHOR_STATUS" ;;
      *) echo 'invalid inline requirement argument' >&2; exit 2 ;;
    esac ;;
  *--verbose=4*) printf 'TeamIdentifier=%s\\n' "$MOCK_TEAM" >&2 ;;
  *-r-*) echo 'designated => identifier "dev.noamlitt.dictator" and certificate root = H"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' >&2 ;;
esac
exit 0
''',
            }
            for name, body in scripts.items():
                executable = tools / name
                executable.write_text(body)
                executable.chmod(0o755)
            env = os.environ.copy()
            env.update(PATH=str(tools) + os.pathsep + env['PATH'],
                       DICTATOR_BUILD_DIR=str(root / 'build'), MOCK_TEAM=team,
                       MOCK_ANCHOR_STATUS='0' if apple_anchor else '1')
            return subprocess.run(['/bin/bash', str(SCRIPT)], env=env, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)

    def test_local_identity_build_keeps_unavailable_actions_hidden(self):
        result = self.run_build(set())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('BUILT_APP=', result.stdout)
        self.assertIn('actions in Apple Shortcuts are unavailable', result.stdout)

    def test_one_discoverable_custom_action_without_team_refuses_build_handoff(self):
        # An empty AppShortcutsProvider alone would not hide this custom action.
        result = self.run_build({'CleanUpTextIntent'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('signed app has no Team ID', result.stderr)
        self.assertNotIn('BUILT_APP=', result.stdout)

    def test_provider_alone_cannot_advertise_actions_without_a_team(self):
        result = self.run_build(set(), provider=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('signed app has no Team ID', result.stderr)
        self.assertNotIn('BUILT_APP=', result.stdout)

    def test_malformed_metadata_refuses_handoff(self):
        result = self.run_build(set(), malformed=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('BUILT_APP=', result.stdout)

    def test_claimed_team_without_apple_signature_refuses_handoff(self):
        result = self.run_build({'DictateIntent'}, team='EXAMPLE123')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('without an Apple-validated signing identity', result.stderr)
        self.assertNotIn('BUILT_APP=', result.stdout)

    def test_verified_team_signature_still_requires_native_verification(self):
        result = self.run_build({'RunVoiceLaunchShortcutIntent'}, team='EXAMPLE123', apple_anchor=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('native Shortcuts testing is still required', result.stdout)
        self.assertIn('BUILT_APP=', result.stdout)


if __name__ == '__main__':
    unittest.main()
