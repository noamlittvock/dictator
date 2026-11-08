"""Uninstaller fixtures: only a temporary HOME and bundle, never real configs."""
import json
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


class UninstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dictator-uninstall-')
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name) / 'home'
        self.home.mkdir()
        self.install = Path(self.temporary.name) / 'apps'
        self.resources = self.install / 'Dictator.app/Contents/Resources'
        self.resources.mkdir(parents=True)
        for name in ['tool-catalog.json', 'connectors/opencode-plugin.js']:
            shutil.copyfile(ROOT / 'shared' / name, self.resources / Path(name).name)
        tools = Path(self.temporary.name) / 'tools'
        tools.mkdir()
        # These effects are mocked even in the interactive deletion test.
        for name in ['defaults', 'launchctl']:
            path = tools / name
            path.write_text('#!/bin/sh\necho "' + name + ' $*" >> "$HOME/effects"\n')
            path.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), DICTATOR_INSTALL_DIR=str(self.install),
                        PATH=str(tools) + os.pathsep + os.environ['PATH'])

    def write(self, relative, text):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def run_uninstall(self):
        result = subprocess.run(['/bin/sh', str(ROOT / 'uninstall.sh'), '--yes'],
                                env=self.env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout + result.stderr

    def test_all_catalog_formats_keep_other_hooks_and_make_backups(self):
        owned = {'command': str(self.home / '.dictator/bin/dictator-capture') + ' hook tool'}
        other = {'command': 'echo mine', 'name': 'dictator-capture'}  # name alone is not ownership
        catalog = json.loads((self.resources / 'tool-catalog.json').read_text())
        paths = []
        for tool in catalog['tools']:
            c = tool.get('connector', {})
            if not c.get('hook_config'):
                continue
            event, fmt = c.get('hook_event'), c['hook_format']
            if fmt == 'opencode-plugin':
                template = (self.resources / 'opencode-plugin.js').read_text()
                text = template.replace('__DICTATOR_CAPTURE_PATH__', json.dumps(str(self.home / '.dictator/bin/dictator-capture')))
            else:
                hooks = [{'hooks': [owned, other], 'matcher': '*'}, {'hooks': [owned]}] if fmt in ['nested-hooks', 'codex-hooks', 'gemini-hooks'] else [owned, other]
                if fmt == 'copilot-hooks':
                    hooks = [{'bash': owned['command']}, {'bash': 'echo mine'}]
                config = {'hooks': {event: hooks}, 'other': {'setting': 42}}
                if fmt == 'agy-hooks':
                    config = {'dictator-capture': {event: [owned, other]}, 'unrelated': {event: [other]}}
                text = json.dumps(config)
            path = self.write(c['hook_config'], text)
            paths.append((path, text, fmt))
        codex_toml = self.write('.codex/config.toml', '[features]\nhooks = true\nother = true\n')
        toml = codex_toml.read_text()
        output = self.run_uninstall()
        self.assertNotIn('manual look', output)
        for path, original, fmt in paths:
            self.assertEqual(Path(str(path) + '.dictator-uninstall-backup').read_text(), original)
            if fmt == 'opencode-plugin':
                self.assertFalse(path.exists())
            else:
                content = path.read_text()
                self.assertIn('echo mine', content)
                self.assertNotIn('hook tool', content)
                root = json.loads(content)
                if fmt == 'nested-hooks':
                    self.assertEqual(len(root['hooks']['UserPromptSubmit']), 1)
                    self.assertEqual(root['hooks']['UserPromptSubmit'][0]['matcher'], '*')
        self.assertEqual(codex_toml.read_text(), toml)

    def test_malformed_json_is_untouched_and_does_not_block_other_files(self):
        bad = self.write('.claude/settings.json', '{bad json')
        good = self.write('.cursor/hooks.json', '{"hooks":{"beforeSubmitPrompt":[{"command":"dictator-capture hook cursor"}]}}')
        self.write('.dictator/bin/dictator-capture', 'synthetic shim')
        output = self.run_uninstall()
        self.assertEqual(bad.read_text(), '{bad json')
        self.assertFalse(Path(str(bad) + '.dictator-uninstall-backup').exists())
        self.assertIn(str(bad), output)
        self.assertIn('manual look', output)
        self.assertNotIn('dictator-capture', good.read_text())
        self.assertFalse((self.home / '.dictator').exists())

    def test_yes_without_terminal_keeps_data_logs_and_server_but_removes_shim(self):
        paths = [self.write('Library/Application Support/Dictator/' + suffix, 'fixture')
                 for suffix in ['Usage/dataset/records.json', 'Takes/take.wav', 'Recovery/take.pcm',
                                'StoreRecovery/store', 'speech-server.token', 'recent-commands.json']]
        paths += [self.write('Library/Logs/Dictator/hotkey.log', 'fixture'),
                  self.write('Library/LaunchAgents/dev.noamlitt.dictation.server.plist', 'fixture')]
        self.write('.dictator/spool/prompt', 'fixture')
        output = self.run_uninstall()
        self.assertTrue(all(path.exists() for path in paths))
        self.assertFalse((self.home / '.dictator').exists())
        self.assertFalse((self.home / 'effects').exists())
        self.assertIn('Kept the speech server', output)
        self.assertIn('Kept Dictator data and logs', output)

    def test_interactive_removal_covers_data_and_server_but_keeps_model_caches(self):
        data = self.write('Library/Application Support/Dictator/Usage/fixture', 'fixture').parents[1]
        self.write('Library/Application Support/Dictator/Takes/fixture', 'fixture')
        self.write('Library/Application Support/Dictator/Recovery/fixture', 'fixture')
        self.write('Library/Application Support/Dictator/StoreRecovery/fixture', 'fixture')
        self.write('Library/Application Support/Dictator/speech-server.token', 'fixture')
        activity = self.write('Library/Application Support/Dictator/recent-commands.json', '[]')
        logs = self.write('Library/Logs/Dictator/log', 'fixture').parent
        plist = self.write('Library/LaunchAgents/dev.noamlitt.dictation.server.plist', 'fixture')
        cache = self.write('.cache/huggingface/model', 'fixture')
        master, slave = pty.openpty()
        process = subprocess.Popen(['/bin/sh', str(ROOT / 'uninstall.sh')], env=self.env,
                                   stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = b''
        deadline = time.monotonic() + 30
        try:
            while process.poll() is None and time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        output += os.read(master, 65536)
                    except OSError:
                        break
                    if output.count(b'[y/N]') > output.count(b'yes\r\n'):
                        os.write(master, b'yes\n')
            process.wait(timeout=5)
        finally:
            if process.poll() is None:
                process.kill()
            os.close(master)
        self.assertEqual(process.returncode, 0, output.decode())
        self.assertFalse(data.exists())
        self.assertFalse(activity.exists())
        self.assertFalse(logs.exists())
        self.assertFalse(plist.exists())
        self.assertTrue(cache.exists())
        self.assertIn('launchctl bootout gui/', (self.home / 'effects').read_text())

    def test_modified_plugin_is_kept_and_reported(self):
        plugin = self.write('.config/opencode/plugins/dictator-capture.js', '// user plugin dictator-capture')
        output = self.run_uninstall()
        self.assertEqual(plugin.read_text(), '// user plugin dictator-capture')
        self.assertIn(str(plugin), output)
        self.assertIn('manual look', output)


if __name__ == '__main__':
    unittest.main()
