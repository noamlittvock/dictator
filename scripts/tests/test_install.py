"""Installer and capture hook fixtures: temporary folders only, signing mocked."""
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dictator-install-')
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.apps = root / 'apps with a space'
        self.apps.mkdir()
        self.asset = root / 'new build' / 'Dictator.app'
        self.make_app(self.asset, 'new')
        self.tools = root / 'tools'
        self.tools.mkdir()
        self.calls = root / 'calls'
        self.tool('codesign', '''echo "codesign $*" >> "$MOCK_CALLS"
case "$*" in
  *--verify*) [ "${MOCK_UNSIGNED:-0}" = 0 ] ;;
  *--verbose=4*) echo "TeamIdentifier=${MOCK_TEAM:-ABCDE12345}" >&2 ;;
  *-r-*) echo "designated => ${MOCK_REQUIREMENT:-stable identity}" >&2 ;;
esac''')
        self.tool('spctl', 'echo "spctl $*" >> "$MOCK_CALLS"; exit "${MOCK_GATEKEEPER:-0}"')
        self.tool('xattr', 'echo "xattr $*" >> "$MOCK_CALLS"')
        self.tool('defaults', 'echo 1.2.3')
        self.tool('uname', 'case "$1" in -s) echo Darwin;; -m) echo arm64;; esac')
        self.tool('sw_vers', 'echo 14.0')
        self.tool('pgrep', 'exit 1')
        self.tool('pkill', 'echo "unexpected pkill" >&2; exit 1')
        self.env = dict(os.environ, HOME=str(root), DICTATOR_INSTALL_DIR=str(self.apps), DICTATOR_ASSET=str(self.asset),
                        DICTATOR_NO_LAUNCH='1', MOCK_CALLS=str(self.calls), PATH=str(self.tools) + os.pathsep + os.environ['PATH'])
        expected_team = re.search(r'^EXPECTED_TEAM_ID="([^"]*)"', (ROOT / 'install.sh').read_text(), re.MULTILINE).group(1)
        self.env['MOCK_TEAM'] = expected_team or 'ABCDE12345'

    def make_app(self, path, marker):
        (path / 'Contents').mkdir(parents=True)
        (path / 'Contents/marker').write_text(marker)

    def tool(self, name, body):
        path = self.tools / name
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)

    def install(self):
        return subprocess.run(['/bin/sh', str(getattr(self, 'script', ROOT / 'install.sh')), '--yes'], env=self.env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=60)

    def marker(self):
        return (self.apps / 'Dictator.app/Contents/marker').read_text()

    def leftovers(self):
        return [path.name for path in self.apps.iterdir() if path.name != 'Dictator.app']

    def test_a_bundle_given_directly_installs(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker(), 'new')
        self.assertEqual(self.leftovers(), [])

    def test_a_trailing_slash_on_the_bundle_installs(self):
        self.env['DICTATOR_ASSET'] = str(self.asset) + '/'
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker(), 'new')

    def test_an_update_replaces_the_old_app(self):
        self.make_app(self.apps / 'Dictator.app', 'old')
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker(), 'new')
        self.assertEqual(self.leftovers(), [])

    def test_a_copy_that_fails_leaves_the_working_app(self):
        self.make_app(self.apps / 'Dictator.app', 'old')
        # The asset's own copy into the work folder succeeds; the one into the install folder fails.
        self.tool('cp', f'''case "$*" in *{self.apps}*) mkdir -p "$(eval echo \\${{$#}})/Contents"; exit 1;; esac
exec /bin/cp "$@"''')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.marker(), 'old')
        self.assertEqual(self.leftovers(), [])

    def downloaded(self):
        self.env.pop('DICTATOR_ASSET')
        self.env['MOCK_ASSET'] = str(self.asset)
        self.tool('curl', '''case "$*" in
  *releases/latest*) printf '%s\\n' '{' '  "tag_name": "v1.2.3",' '  "assets": [{"url": "https://api.github.com/repos/example/releases/assets/123", "name": "Dictator-1.2.3-macOS-arm64.zip"}]' '}' ;;
  *) exit 0 ;;
esac''')
        self.tool('ditto', '''mkdir -p "$4"
exec /bin/cp -R "$MOCK_ASSET" "$4/"''')

    def test_local_asset_keeps_permissive_signing_and_labels_local_build(self):
        # Verification fails until the mock ad hoc signer marks this build signed.
        self.tool('codesign', '''echo "codesign $*" >> "$MOCK_CALLS"
case "$*" in
  *--sign*) touch "$HOME/locally-signed" ;;
  *--verify*) test -f "$HOME/locally-signed" ;;
esac''')
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Using local build:', result.stdout)
        calls = self.calls.read_text()
        self.assertIn('xattr -dr com.apple.quarantine', calls)
        self.assertIn('codesign --force --deep --sign -', calls)
        self.assertNotIn('spctl', calls)

    def test_downloaded_unsigned_app_refused_before_replacing_existing(self):
        self.downloaded()
        self.make_app(self.apps / 'Dictator.app', 'old')
        self.env['MOCK_UNSIGNED'] = '1'
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('signature could not be verified', result.stderr)
        self.assertEqual(self.marker(), 'old')
        calls = self.calls.read_text()
        self.assertNotIn('xattr', calls)
        self.assertNotIn('--sign', calls)

    def test_downloaded_gatekeeper_rejection_is_refused(self):
        self.downloaded()
        self.env['MOCK_GATEKEEPER'] = '1'
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('macOS did not approve', result.stderr)
        self.assertFalse((self.apps / 'Dictator.app').exists())

    def test_downloaded_approved_release_keeps_signature_and_quarantine(self):
        self.downloaded()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker(), 'new')
        calls = self.calls.read_text()
        self.assertIn('codesign --verify --deep --strict', calls)
        self.assertIn('spctl --assess --type execute', calls)
        self.assertNotIn('xattr', calls)
        self.assertNotIn('--sign', calls)

    def test_downloaded_team_id_mismatch_is_refused(self):
        self.downloaded()
        self.env['MOCK_TEAM'] = 'OTHER12345'
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('signing team does not match', result.stderr)
        self.assertFalse((self.apps / 'Dictator.app').exists())

    def test_changed_identity_explains_permission_transition(self):
        self.make_app(self.apps / 'Dictator.app', 'old')
        self.tool('codesign', '''case "$*" in
  *-r-*) case "$*" in *"$DICTATOR_INSTALL_DIR"*) echo 'designated => old identity';; *) echo 'designated => new identity';; esac ;;
esac''')
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('macOS will ask for Microphone, Accessibility and Input Monitoring access again', result.stdout)


class SignedInstallerIdentityTests(unittest.TestCase):
    """Run the source identity gate only; never reach /Applications or launch."""
    def run_gate(self, requirement, team='not set', anchor_status=0):
        with tempfile.TemporaryDirectory(prefix='dictator-identity-') as directory:
            root = Path(directory)
            app = root / 'Dictator.app'
            app.mkdir()
            codesign = root / 'codesign'
            codesign.write_text('''#!/bin/sh
case "$*" in
  *-r-*) echo "designated => $MOCK_REQUIREMENT" ;;
  *--verbose=4*) echo "TeamIdentifier=$MOCK_TEAM" ;;
  *--test-requirement*) exit "$MOCK_ANCHOR_STATUS" ;;
esac
''')
            codesign.chmod(0o755)
            text = (ROOT / 'scripts/install-app.sh').read_text().split('INSTALLED="/Applications/Dictator.app"')[0]
            script = root / 'gate.sh'
            script.write_text(text)
            return subprocess.run(['/bin/bash', str(script), str(app), '--no-launch'], capture_output=True, text=True,
                                  env=dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                                           MOCK_REQUIREMENT=requirement, MOCK_TEAM=team,
                                           MOCK_ANCHOR_STATUS=str(anchor_status)), timeout=10)

    def test_developer_id_requirement_without_hash_is_accepted(self):
        result = self.run_gate('identifier "dev.noamlitt.dictator" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345"', 'ABCDE12345')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('expected Developer ID team', result.stdout)

    def test_local_certificate_requirement_is_accepted(self):
        result = self.run_gate('identifier "dev.noamlitt.dictator" and certificate root = H"' + 'A' * 40 + '"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('expected local certificate hash', result.stdout)

    def test_ad_hoc_requirement_is_refused(self):
        result = self.run_gate('identifier "dev.noamlitt.dictator" and cdhash H"' + 'A' * 40 + '"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Ad hoc builds are refused', result.stderr)

    def test_claimed_team_without_apple_anchor_is_refused(self):
        result = self.run_gate('identifier "dev.noamlitt.dictator" and certificate leaf[subject.OU] = "ABCDE12345"', 'ABCDE12345', 1)
        self.assertNotEqual(result.returncode, 0)


class QuitDictatorTests(unittest.TestCase):
    """The same quit, in every script: asks first, waits, and forces only at the end."""
    SCRIPTS = ['install.sh', 'uninstall.sh', 'scripts/install-app.sh']

    def run_quit(self, script, polls_until_gone):
        with tempfile.TemporaryDirectory(prefix='dictator-quit-') as folder:
            root = Path(folder)
            tools = root / 'tools'
            tools.mkdir()
            calls = root / 'calls'
            (root / 'polls').write_text('0')
            (tools / 'pkill').write_text(f'#!/bin/sh\necho "$1" >> "{calls}"\n')
            (tools / 'pgrep').write_text(
                f'#!/bin/sh\nn=$(cat "{root}/polls"); echo $((n + 1)) > "{root}/polls"\n[ "$n" -lt {polls_until_gone} ]\n')
            for tool in tools.iterdir():
                tool.chmod(0o755)
            text = (ROOT / script).read_text()
            function = text[text.index('quit_dictator() {'):]
            function = function[:function.index('\n}\n') + 3]
            shell = root / 'quit.sh'
            shell.write_text(function + 'quit_dictator\n')
            result = subprocess.run(['/bin/sh', str(shell)], capture_output=True, text=True, timeout=30,
                                    env=dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], DICTATOR_QUIT_WAIT='2'))
            self.assertEqual(result.returncode, 0, result.stderr)
            return calls.read_text().split()

    def test_an_app_that_quits_is_never_forced(self):
        for script in self.SCRIPTS:
            self.assertEqual(self.run_quit(script, 1), ['-TERM'], script)

    def test_an_app_that_never_quits_is_forced_after_the_wait(self):
        for script in self.SCRIPTS:
            self.assertEqual(self.run_quit(script, 1000), ['-TERM', '-KILL'], script)

    def test_the_wait_outlasts_the_apps_own_limit(self):
        swift = (ROOT / 'swift-client/Dictator/Services/QuitGuard.swift').read_text()
        limit = int(swift.split('longestWait: TimeInterval = ')[1].split()[0])
        for script in self.SCRIPTS:
            self.assertGreater(int((ROOT / script).read_text().split('DICTATOR_QUIT_WAIT:-')[1].split('}')[0]), limit, script)


class CaptureHookTests(unittest.TestCase):
    def test_a_spool_it_cannot_write_is_silent(self):
        with tempfile.TemporaryDirectory(prefix='dictator-hook-') as folder:
            spool = Path(folder) / 'spool'
            spool.mkdir()
            spool.chmod(0o500)
            try:
                result = subprocess.run(['/bin/sh', str(ROOT / 'shared/connectors/dictator-capture'), 'hook', 'codex'],
                                        env=dict(os.environ, DICTATOR_HOME=folder), input='{"prompt":"hi"}',
                                        capture_output=True, text=True, timeout=30)
            finally:
                spool.chmod(0o700)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))


if __name__ == '__main__':
    unittest.main()
