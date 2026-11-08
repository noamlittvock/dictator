# Multiple Macs

One Mac is enough. With several, you can record on one and run models on another.

Install Dictator on each Mac and connect them through Tailscale. In **Settings › Your Macs**, choose a main Mac and join its setup from the others.

| Setup | Job |
|---|---|
| On its own | Everything stays on this Mac. |
| Main Mac | Coordinates dictation and keeps the main copy of shared history, dictionary and settings. |
| Connected to a main Mac | Records and inserts text, with its own local copy of history. |

## Choose where models run

Any Mac can run speech recognition and clean-up. Choose the sources and their backup order in Settings › Your Macs. The main Mac can run without a screen.

If a source is unavailable, Dictator tries your configured backup. If none works, it keeps the recording for recovery. Shared history catches up when the main Mac returns.

With Universal Control, a shared keyboard and pointer activity help Dictator choose where the text lands. Separate keyboards work independently. You can also choose another Mac as the recording source.

## Remove a Mac

Remove it in Settings › Your Macs. This rotates the pairing credential. If you use the optional Python speech server, its separate key must also be changed: follow [the server key instructions](../server/README.md#endpoints).

Keep connected apps on compatible builds; update the main Mac first. Each Mac owns its store. Do not point two installations at the same history file.
