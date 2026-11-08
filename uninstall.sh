#!/bin/sh
# Remove Dictator from this Mac.
#
#   sh uninstall.sh [--yes]
#
# Quits Dictator and removes /Applications/Dictator.app (DICTATOR_INSTALL_DIR to change).
# Removes local capture hooks and ~/.dictator. Open-at-login uses macOS
# SMAppService; disable it in Dictator before uninstalling or in System Settings.
# Data and the optional speech server stay unless you explicitly choose removal.
set -eu

INSTALL_DIR="${DICTATOR_INSTALL_DIR:-/Applications}"
YES=0
for arg in "$@"; do
  case "$arg" in --yes|-y) YES=1 ;; --help|-h) sed -n '2,9p' "$0"; exit 0 ;; *) echo "unknown option: $arg" >&2; exit 2 ;; esac
done
ask_optional() {
  if [ "$YES" = 1 ] || ! [ -t 0 ]; then return 1; fi
  printf '%s [y/N] ' "$1"; read -r answer || answer=""
  case "$answer" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

quit_dictator() {
  # SIGTERM, not an Apple event, so this works over SSH without Automation
  # permission. Dictator holds its exit until any dictation finishes, on this
  # Mac or a Mac it serves; the wait is longer than its own limit.
  pkill -TERM -x Dictator 2>/dev/null || true
  waited=0
  while pgrep -x Dictator >/dev/null 2>&1 && [ "$waited" -lt "${DICTATOR_QUIT_WAIT:-190}" ]; do
    [ "$waited" = 3 ] && echo "Waiting for a dictation to finish before quitting Dictator..."
    sleep 1
    waited=$((waited + 1))
  done
  if pgrep -x Dictator >/dev/null 2>&1; then
    pkill -KILL -x Dictator 2>/dev/null || true
    sleep 1
  fi
}

app="$INSTALL_DIR/Dictator.app"
if [ "$INSTALL_DIR" = "/Applications" ]; then
  quit_dictator
fi
# Read the installed catalog before removing the bundle. JXA and Foundation
# ship with macOS; no Python installation or third-party JSON tool is needed.
/usr/bin/osascript -l JavaScript - "$app/Contents/Resources" "$HOME" <<'JXA' || echo "Hook cleanup could not finish; inspect your tool configs manually."
ObjC.import('Foundation');
function run(argv) {
    var resources = argv[0], home = argv[1], fm = $.NSFileManager.defaultManager;
    function exists(path) { return fm.fileExistsAtPath(path); }
    function read(path) {
        var value = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
        if (!value) throw Error('cannot read file');
        return ObjC.unwrap(value);
    }
    function backup(path) {
        var base = path + '.dictator-uninstall-backup', target = base, n = 1;
        while (exists(target)) target = base + '.' + n++;
        if (!fm.copyItemAtPathToPathError(path, target, null)) throw Error('cannot make backup');
    }
    // Same identification as ConnectorInstaller.isOurs: command or bash
    // contains the dictator-capture shim marker, never a name alone.
    function ours(handler) {
        return handler && typeof handler === 'object' && ['command', 'bash'].some(function(key) {
            return typeof handler[key] === 'string' && handler[key].indexOf('dictator-capture') !== -1;
        });
    }
    function object(value) { return value && typeof value === 'object' && !Array.isArray(value); }
    // Only descend through hook containers. Keep unrelated settings verbatim
    // as values, including other handlers in the same matcher group.
    function clean(value) {
        if (Array.isArray(value)) return value.reduce(function(kept, v) {
            if (ours(v)) return kept;
            var hadHandlers = object(v) && Array.isArray(v.hooks) && v.hooks.length > 0;
            var result = clean(v);
            if (!hadHandlers || result.hooks) kept.push(result);
            return kept;
        }, []);
        if (object(value)) Object.keys(value).forEach(function(key) {
            var before = JSON.stringify(value[key]);
            value[key] = clean(value[key]);
            if (before !== JSON.stringify(value[key]) &&
                ((Array.isArray(value[key]) && !value[key].length) ||
                 (object(value[key]) && !Object.keys(value[key]).length))) delete value[key];
        });
        return value;
    }
    var tools;
    try { tools = JSON.parse(read(resources + '/tool-catalog.json')).tools; if (!Array.isArray(tools)) throw Error('missing tools'); }
    catch (error) { console.log('Cannot read bundled tool-catalog.json; inspect local capture hooks manually.'); return; }
    tools.forEach(function(tool) {
        var c = tool.connector;
        if (!c || !c.hook_config) return;
        var relative = c.hook_config;
        if (relative[0] === '/' || relative.split('/').indexOf('..') !== -1) {
            console.log('Inspect unsafe catalog path manually: ' + relative); return;
        }
        var path = home + '/' + relative;
        if (!exists(path)) return;
        try {
            // Follow dotfile-manager symlinks, preserving the link itself.
            path = ObjC.unwrap($(path).stringByResolvingSymlinksInPath);
            var original = read(path);
            if (c.hook_format === 'opencode-plugin') {
                var template = read(resources + '/opencode-plugin.js');
                var expected = template.replace('__DICTATOR_CAPTURE_PATH__', JSON.stringify(home + '/.dictator/bin/dictator-capture'));
                if (original !== expected) throw Error('plugin differs from Dictator’s bundled file');
                backup(path);
                if (!fm.removeItemAtPathError(path, null)) throw Error('cannot remove plugin');
            } else {
                var root = JSON.parse(original);
                if (!object(root)) throw Error('expected a JSON object');
                var before = JSON.stringify(root);
                if (c.hook_format === 'agy-hooks') root = clean(root);
                else if (object(root.hooks)) root.hooks = clean(root.hooks);
                if (JSON.stringify(root) === before) return;
                backup(path);
                if (!$(JSON.stringify(root, null, 2) + '\n').writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) throw Error('cannot write file');
            }
            console.log('Removed Dictator hook from ' + path + ' (backup beside it).');
        } catch (error) {
            console.log('Left ' + path + ' for a manual look: ' + error.message);
        }
    });
}
JXA
# Even an unreadable config must not leave a working capture shim or spool.
rm -rf "$HOME/.dictator"
echo "Removed $HOME/.dictator (capture shim and spool)."

if [ -d "$app" ]; then
  rm -rf "$app"
  echo "Removed $app."
else
  echo "No Dictator.app in $INSTALL_DIR."
fi

plist="$HOME/Library/LaunchAgents/dev.noamlitt.dictation.server.plist"
if [ -f "$plist" ]; then
  if ask_optional "Also remove the speech server? Its model caches will stay."; then
    # An already unloaded job is harmless; never start another copy.
    if ! launchctl bootout "gui/$(id -u)" "$plist"; then
      echo "Could not confirm the speech server stopped (it may already be unloaded); inspect it manually."
    fi
    rm -f "$plist"
    echo "Removed the speech server plist; kept its model caches."
  else
    echo "Kept the speech server and its model caches."
  fi
fi

data="$HOME/Library/Application Support/Dictator"
logs="$HOME/Library/Logs/Dictator"
if [ -d "$data" ] || [ -d "$logs" ]; then
  if ask_optional "Also delete all Dictator data (history, dictionary, settings, Datasets/Usage, Takes, Recovery, StoreRecovery, speech server key and logs)? This cannot be undone."; then
    rm -rf "$data" "$logs"
    defaults delete dev.noamlitt.dictator >/dev/null 2>&1 || true
    echo "Removed Dictator data and logs."
  else
    echo "Kept Dictator data and logs."
  fi
fi
echo "Review open-at-login in System Settings > General > Login Items (SMAppService)."
echo "Remote capture hooks, dataset copies saved elsewhere and System Settings permissions remain if present. Remove them separately."
