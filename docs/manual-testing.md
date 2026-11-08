# Checks to run by hand

Run affected sections on real Macs before release, with the candidate installed on each Mac. Use test accounts and synthetic content. Installing, recording and contacting services require a deliberate request.

Start with [Dictation](#dictation), [Commands](#commands), [Workspaces](#workspaces-on-real-desks) and [History and privacy](#history-and-privacy). For multi-Mac changes, also check [Several Macs](#several-macs) and [Removing a Mac](#removing-a-mac). Release checks: [cleanup](#release-cleanup) and [updates](#in-app-updates).

The detailed cases below are acceptance criteria; build and automated test commands live in [Development](development.md).

## Dictation

- [ ] Hold Right ⌥, say a sentence with an "um" in it, let go: clean text appears where the cursor is, and the clipboard holds what it held before.
- [ ] Switch Settings › General › How the key works to "Tap to start, tap to stop" and dictate that way.
- [ ] Dictate in each of your languages, and once mixing two in one sentence.
- [ ] Add a word to the Dictionary and dictate it: it's spelled your way.
- [ ] Start a long-running CLI from a Datasets package, then quit Dictator: the CLI process stops with it.
- [ ] Settings › Dictation › "Polish the text": dictate a clumsy sentence with a number and a name in it. Grammar improves and the number and name are unchanged. The row on Home reads "Polished" with a time; clicking it shows removed words struck through and new words highlighted. Plain dictation with "Clean up the text" still keeps your wording.
- [ ] With Polish chosen and the clean-up model unavailable, dictate: the words are typed, the row on Home reads "Kept as heard" in the warning color, and Settings › Dictation › How it's going counts it.
- [ ] Settings › Dictation › "Skip AI clean-up": AI rewriting is skipped and Dictionary replacements still apply. Compare fillers with the recording; speech recognition may still change them.
- [ ] Press Esc while talking: nothing is typed and no alert appears.

## Several Macs

- [ ] With Universal Control, move the pointer to the other Mac, hold ⌥ there: the text lands on that Mac.
- [ ] Long dictation warning: dictate for about 110 seconds, in hold mode and again in tap mode. A soft tick sounds and the badge says "Stopping in 10…", counting down, with a tick on each of the last three seconds. Letting go (or tapping) early clears it. Repeat with the microphone on the other Mac: the warning shows on the Mac with the badge.
- [ ] Settings › Your Macs shows every Mac, its memory, its AI models, and the four steps with the right Mac under each.
- [ ] Dictate on the connected Mac: the entry appears in History on both Macs.
- [ ] Add a Mac: open Add a Mac on the main Mac and Join Another Mac's Setup on the other; the same code shows on both; approving connects it.

## Removing a Mac

Use a disposable setup with synthetic history for these checks; do not use personal recordings. These checks deliberately change pairing credentials.

- [ ] On the main Mac, choose Remove from Your Macs for a connected Mac. The confirmation says it can no longer connect, says offline/disconnected Macs must be added again, names those Macs, and says existing history stays. Cancel leaves everything connected.
- [ ] Confirm removal: the Mac disconnects and disappears from Your Macs. Another updated connected Mac stays connected, saves the replacement and acknowledges it. Disconnect/reconnect that remaining Mac and restart its app: it still connects without another invitation.
- [ ] Attempt to reconnect the removed Mac with its old saved credential. It gets the `auth` refusal and explains Settings › Your Macs › Add a Mac on the main Mac. Observe beyond 90 seconds: neither the backoff loop nor the coordinator watchdog retries. Its synthetic local history remains available.
- [ ] Keep a third Mac offline during removal. Bring it back: the same refusal and explained state appear. Open Add a Mac on the main Mac and Join Another Mac’s Setup on the refused Mac; verify it connects again. Repeat removing an already-offline Mac.
- [ ] Open a socket before removal, but send its old-token hello after removal: it receives `auth`. Changing its claimed Mac ID does not bypass this. An unauthenticated socket and the removed socket never receive the replacement credential.
- [ ] Force a token-write failure in a disposable setup. Confirming Remove shows a plain failure; the old pairing credential, connected Macs and listing all remain unchanged. Restore file access and repeat successfully.
- [ ] Force credential saving to fail on a remaining Mac in a disposable setup. It sends no acknowledgement, disconnects, explains how to add it again, and stops retrying. Fix file access, then add it again.
- [ ] With an older connected peer, removal does not break the existing protocol: the peer ignores the new message. After its next disconnect it needs to be added again. Remove two Macs in succession and verify the remaining updated peer reconnects with the latest credential.
- [ ] With speech only on the main Mac, no separate-key line appears. With a speech server on another Mac (including a backup), one extra line says to change that server's separate key on its Mac and update Settings › Advanced › Speech server key on the Macs kept. Follow the procedure in server/README.md separately; pairing removal alone does not revoke direct speech-server requests.

## AI models

- [ ] Add a speech model to a Mac (Whisper, and Apple on macOS 26+): it downloads, "Try it" hears the sample, and "For every dictation" makes it the first speech source.
- [ ] Add a clean-up model to a Mac with Ollama: "Try it" cleans up the sample; dictation then uses it.
- [ ] Turn off the Mac that turns speech into text: dictation still works through the next source, and Your Macs says it's standing in.

## Commands

All ready-made link formats in `shared/shortcut-catalog.json` are **unverified until tested by hand**; fix the catalog for any that don't work. Nothing is on by default. The Commands tab shows one card per ready-made command (turn a card on or off); "Build your own…" at the bottom opens the advanced screens (your commands, "Your lists", Teach, Try it) with a Back button. Nothing in Build your own shows curly or square brackets, or words like slot, field, pattern, trigger, alias, template, step or token; check every screen for that. Actions that send for real (Return or ⌘Return, an Apple Shortcut unless marked "Doesn’t send or change anything", a webhook) always follow a "Wait for me to cancel (3 seconds)" pause; the editor adds one when you add such an action and explains it in one line.
- [ ] Commands tab, simple view: the header says "Hold Right ⌥ + Right Shift and say what you want." and shows no braces or words like slot, step, pattern, trigger or alias. Tabs at the top: Things to say, People (with a count) and, once Run a Shortcut is on, Apple Shortcuts; "Build your own…" sits at the top right. Things to say starts with "On now" (a chip per card that is on; clicking one opens that card) or "Nothing is on yet." Then "How to say it", open when nothing is on and folded to one line otherwise, explains the three shapes: the start word (solid key), someone or a project (outlined pill with a person or folder symbol), and your own words (italics). Cards sit under Message someone (Email, WhatsApp), Search the web (YouTube, Google, Marketplace), Ask an AI (ChatGPT, Claude), On your Mac (Claude Code project, Run a Shortcut) and Made by you. Each card is one line: the icon of where it goes (an installed app's icon, else the website's icon, else a letter or symbol), its title, a "Say …" line, and an On/Off switch; a card that is off is greyed. Clicking a card opens it, closing any other: the sentence in its shapes, one plain line saying what happens, for Email and WhatsApp who you can say with "Edit people…" (switches to the People tab), and its settings once on. Turning on WhatsApp or Claude Code opens the card after its question. The WhatsApp line changes between "You press Send" and "after 3 seconds" with its mode. The whole list fits without scrolling on a normal window. Check light and dark mode, and with no network (letters and symbols stand in).
- [ ] Card switches: turn Search YouTube on, then say "YouTube cute cats" (it opens); turn it off, and repeat in Commands mode: nothing opens or is typed, and the words stay on the clipboard with a notice. Turning it on again brings it back with any other ways you taught it.
- [ ] WhatsApp card: turning it on asks "Send it right away, or let me check first?". "Let me check first" opens the chat with the text filled in. Switch to "Send right away" (with "You'll have 3 seconds to press Esc."): saying "WhatsApp Dana I'll be late" (same words) now presses Return after the pause, and Esc cancels. Only one WhatsApp command exists at a time (see it in Build your own).
- [ ] Claude Code card: turning it on asks "Which projects?" and opens a folder picker (with "Open it in" Terminal / iTerm when iTerm is installed; this choice is not in the simple list, only here and in the coding-assistant action). Each folder becomes a project named after it; rename it in the card's Projects row, add or remove folders there. Say "Code <project> fix the tests": Terminal opens in the folder.
- [ ] Your own commands made in Build your own appear as cards with their first words as the title; Edit opens the editor.
- [ ] People: Add (name, phone, email), Edit, Remove. Badges show WhatsApp for a phone number and Email for an address. "Add from Contacts" opens the system contact picker: check whether it works with no Contacts permission prompt and that the chosen contact fills the form (first name, first number, first email). Cancelling does nothing.
- [ ] Check name: press it next to Noam, record twice ("WhatsApp Noam"). If heard right: "Got it — Dictator hears Noam correctly." If heard as "norm": "Dictator heard "norm". Saved as another way to say Noam." and saying it works. Give Dana the same way of hearing first: it says "Sounds like Dana too — try saying it more clearly" and saves nothing. Misheard "WhatsApp": it asks for just the name.
- [ ] Build your own › Your lists: "New list…" makes one; edit it to rename it, add details (phone, email, folder), and add entries with a name, "Also called" (comma separated) and detail values; Teach sits next to the name. Renaming a list updates commands that use it. A bad detail name gives a plain reason. Deleting a list a command uses is refused with a plain reason.
- [ ] Turning on the WhatsApp card when no People list exists creates People (phone, email), empty. Add a person, say "WhatsApp Dana I'll be late": WhatsApp opens the chat with the text filled in.
- [ ] Command editor, "What do you say?": type the opening word (solid "start word" key); add "+ Someone from People" (outlined "who" pill with a person symbol), "+ A project" (outlined "project" pill with a folder symbol), "+ Your words" (asks for a short name, default "message") and "+ A word that starts a new part" (small outlined pill). Move pieces left and right, remove them, tick "Can be skipped". The live preview and the "Example:" line (for example "WhatsApp Noam running late") update as you go. Put your words before another piece: the plain reason "Your words need to come last, or be followed by a word that starts a new part." appears and Save is refused. "Also listen for" lists other ways the opening word is heard, with Teach. Editing an older command shows its pieces; one that can't be shown exactly says so and offers "Start again".
- [ ] Command editor, "What should happen?": "Add an action" lists Open a website, Open an app, Wait until I can type, Type my words, Start a coding assistant in a folder, Wait for me to cancel (3 seconds), Press a key, Run an Apple Shortcut, Send to n8n, Zapier or another webhook, Add a line to a file. Each shows as a numbered card in plain words with Edit, move up/down and remove. Press a key offers Return (send), ⌘Return (send), Tab, Esc. Choose app, Choose folder and the file chooser use the system pickers.
- [ ] Values in text and addresses: in Type my words (and the coding assistant's "What to give it", the pause message, Apple Shortcut input, line to add) press an "Insert:" button (message, person's phone, project folder...): a coloured bubble appears at the cursor. Delete it with backspace; typing curly brackets does nothing. Save and reopen: the bubbles are back and it works when spoken.
- [ ] Open a website from an example: search a site for TEST, paste the address into "Build it from an example", press "Use this address": the word TEST (any capitals, or its %-encoded form) is replaced by your words; "Edit the address" shows it with bubbles. An address without TEST says so plainly. Try it with your words containing & and Hebrew letters.
- [ ] Coding assistant action: choose Claude Code, Codex, Gemini or OpenCode, then a folder or "The project folder"; the Terminal / iTerm choice ("This Mac only.") is here. "Clean up my words first" applies to your main words and is hidden when there are none.
- [ ] Build your own › Try it: type "WhatsApp Dana I'll be late" and see the command, the sentence in its role shapes and "Would do" in plain words (for example "Opens WhatsApp, then waits 3 seconds so you can cancel, then types “I'll be late”"); nothing opens. A sentence that matches nothing says why in plain words.
- [ ] Progress notice: after key release the sentence you said (role-coloured) appears at the bottom of the screen with each step, a tick as it finishes, and a cross on the one that fails (an alert card sits below it). It disappears by itself.
- [ ] Wait for me to cancel: add a command ending in "Press a key" (Return) without a pause; the editor inserts "Wait for me to cancel (3 seconds)" with the person and message as bubbles first. Run it: the notice shows the filled-in summary and "Sending in 3 s — Esc to cancel", counting down. Let it run out: the key press happens. Run it again and press Esc during the count: nothing is sent, a plain "Cancelled" notice appears, and the message is on the clipboard (⌘V pastes it).
- [ ] Press a key: Return, ⌘Return, Tab and Escape each land in the frontmost app (try a notes app; use a test text box). If another app comes to the front during the pause, the step fails with "isn't in front" and nothing is pressed.
- [ ] Apple Shortcuts, picking: add "Run an Apple Shortcut". It lists this Mac's Shortcuts (Refresh re-reads them); choose one, and "Open in Shortcuts" shows it there and "New Shortcut" opens the Shortcuts app. Type a name that doesn't exist: the picker notes it isn't among this Mac's Shortcuts. The help line reads: Your Shortcut gets what you said. Add “Get Dictionary from Input” in it to use each part.
- [ ] Apple Shortcuts, JSON input (**check first**): make a Shortcut with "Get Dictionary from Input", then "Get Dictionary Value" for `values` > `task`, then "Show Result". Leave "What it gets" on "Everything I said" and run a sentence: does the Shortcut read the dictionary? Dictator writes `input.json` and passes it with `--input-path`. If the input arrives as a file that "Get Dictionary from Input" can't read (or as text you have to convert), **the fallback is to pass the same JSON as text**: write it with a `.txt` extension (in `VoiceLaunchActing.runAppleShortcut`, the file name where `input.json` is chosen) and have the Shortcut use "Get Dictionary from Input" on that text. Also check a person's entry arrives as an object (`values` > `person` > `phone`) and Hebrew comes through intact. Record what you find here.
- [ ] Apple Shortcuts, answers: a Shortcut ending in "Text" or "Show Result" with the text `Hello Dana` (or a JSON dictionary as text). Add it read-only, then "Type the answer" (or turn on "Type its answer where my cursor is"): the answer is typed at the cursor. In a later action's "Insert:" buttons, "answer from …" appears; list the parts of a dictionary answer in "Parts of its answer to use" and use one in a link. An empty answer types nothing and is not a failure.
- [ ] Apple Shortcuts, limits and failures: set "Give up after" to 10 seconds on a Shortcut that waits longer: a plain "didn't finish in time" alert. Rename the Shortcut in the Shortcuts app: "This Mac doesn't have the Shortcut …". A Shortcut that errors: "stopped with an error". No raw error text shows on screen, but `~/Library/Logs/Dictator/hotkey.log` has a short `voicelaunch: shortcut …` line. Turn on "Doesn't send or change anything": no cancel pause is required before it (Type the answer after it works without one); turn it off and the editor asks for the pause again.
- [ ] Run an Apple Shortcut: make a Shortcut that shows its input, add "Run an Apple Shortcut", choose "Just my words" and put the message value in "What it gets"; after the pause it runs with your words as input. A wrong name shows a plain failure and stops the chain. Confirm no `dictator-shortcut-*` folder is left in the temp folder.
- [ ] Run a Shortcut (voice, main Mac): the card "Run a Shortcut" is off by default, with the example "Shortcut lights off" coloured by role. Turning it on asks "Send right away, or give me 3 seconds to cancel?" with the 3 seconds selected. A "Your Shortcuts" section then lists this Mac's Shortcuts (Refresh re-reads them; quit and reopen Dictator, and open the page again, to see it refreshed). Say "Shortcut <name>" for a Shortcut that shows its input: after the pause it runs with everything said (`said`, `values` > `which` > `name`/`identifier`, `values` > `words`); a longer name beats a shorter one ("lights off" vs "lights"); saying only the name works (empty words). Its answer is not typed. Check name on a Shortcut saves how it heard it; the new way to say it works and shows under the name. Add or rename a Shortcut in the Shortcuts app and Refresh: the list follows, and a way you added stays with the same Shortcut. Switch to "Run right away" on the card: no pause. On a connected Mac, the list has no Refresh button and matches the main Mac's; saying a Shortcut the connected Mac doesn't have gives "This Mac doesn't have the Shortcut …". Turn the card off and repeat in Commands mode: nothing runs or is typed, and "Shortcut …" stays on the clipboard with a notice.
- [ ] Get Dictionary check (from Apple Shortcuts, JSON input above): still unrecorded, so do it first. Note here whether "Get Dictionary from Input" reads the `input.json` file Dictator passes with `--input-path`, and switch to text input if not.
- [ ] Standard locally signed build — Settings › General explains “Dictator’s actions in Apple Shortcuts are unavailable in this build.” Newly indexed metadata has all three actions undiscoverable and an empty AppShortcutsProvider. Check the installed bundle’s metadata as well as the native action library; stale development/previous-build entries are not proof of the installed build’s availability. Do not reset unrelated Shortcuts or workflows. Existing workflows containing old Dictator actions can still fail at system validation. Commands running your existing Apple Shortcuts remains a separate check above.
- [ ] Enabled team-signed build only — Dictator in the Shortcuts app (install and launch the intended build first, and verify the saved action’s bundle identifier): open the Shortcuts app, search "Dictator" in the action list. Three actions appear: Dictate, Clean up text, Run a Voice launch shortcut, each with a plain description; Clean up text says it uses an AI model.
- [ ] Enabled team-signed build only — Dictate, in the Shortcuts app: make a Shortcut with Dictate followed by "Show Result" and run it. The microphone badge appears, you speak, and after 2 seconds of quiet a "Stopping in 2…" countdown runs down and it ends (speaking again resets it). The result shows your words with clean-up applied. Nothing is typed anywhere. Run it with "Clean up my words" off: the words come back as spoken, with your Dictionary's replacements. Talk past 2 minutes once (or leave it silent): it stops at the limit. The history has one entry per run, labelled as from Shortcuts ("Dictation (from Shortcuts)" in its details), and it follows the normal history rules (turn history off: nothing saved). Run it while a normal dictation is going on: "Dictator is busy with a dictation".
- [ ] Enabled team-signed build only — Dictate, Spotlight: type "Dictate" in Spotlight and pick Dictate for Dictator (or say "Dictate with Dictator" to Siri); it records the same way. The phrase includes the app name.
- [ ] Enabled team-signed build only — Dictate on a connected Mac: same result, and the recording goes through the main Mac. With the main Mac off: a plain message that this Mac isn't connected to the main Mac, before any recording. With no speech model set up (main Mac): a plain "Dictation isn't set up yet". With Microphone access removed in System Settings: a plain message pointing there. Audio is accumulated only while it records; the always-running engine can leave the macOS microphone indicator on while idle.
- [ ] Enabled team-signed build only — Clean up text: a Shortcut with "Text" ("so um call dana about the the meeting tomorrow") then Clean up text, then "Show Result": punctuation and filler words are tidied and a Dictionary replacement is applied. Run it on a connected Mac too (it asks the main Mac). With no clean-up model chosen (Settings › Your Macs): a plain message saying so. Empty text: "There is no text to clean up." Nothing is saved to history.
- [ ] Enabled team-signed build only — Run a Voice launch shortcut: with the "Run a Shortcut" card or your own command turned on, make a Shortcut with "Run a Voice launch shortcut". Its picker lists the enabled voice commands by card title with "Say …" under each (a disabled one is missing). Choose one and give it words ("call Dana at 5" for "Remind {task}"): it runs on this Mac exactly as if spoken, including the "Esc to cancel" pause before an acting step; Esc stops the Shortcut with "Cancelled". "Show Result" shows the last Apple Shortcut's answer if it ran one, else the main words. Words that don't fit the command give a plain "Those words don't fit …". Delete the command in Dictator and run the action again: "isn't in Dictator any more".
- [ ] Enabled team-signed build only — All three actions appear in Spotlight's actions and in Shortcuts › Dictator (App Shortcuts) with their short titles, and running them from there works; before Dictator has been started the action starts it.
- [ ] Send to a web address: point "Send to a web address" at a request-catcher you control; after the pause it receives a POST with JSON of every slot (a person as an object with their details). A 404 or 500 shows a failure; no reply within 10 seconds shows "couldn't reach".
- [ ] Add a line to a file: choose a file, say the command twice; each time one line like `2026-09-29 14:05:09 | your words` is added (the file is created if it didn't exist). A path in a missing folder fails with "That folder isn't on this Mac".
- [ ] "WhatsApp and send": turn on the WhatsApp card in "Send right away" mode, add a person with a phone number, say "WhatsApp Dana running late". Check that `whatsapp://send?phone=…&text=…` opens the chat with the text filled in (unverified link format), that Dictator waits for WhatsApp's text box (bundle id `net.whatsapp.WhatsApp`, as installed on the Macs here), shows "Sending to Dana: running late", and after 3 s presses Return so the message goes. Esc during the count sends nothing.
- [ ] Confirm each ready-made link pre-fills the text: Email (Gmail compose body), YouTube and Google (search), Marketplace (search), ChatGPT and Claude (new chat with the message).
- [ ] Hold Right ⌥ and Right Shift, say "YouTube cute cats": YouTube opens with a search for "cute cats", and nothing is pasted. Repeat in tap mode (Right Shift held when tapping to start).
- [ ] Press Right Shift after Right ⌥ is already down, then talk: it still counts as a command.
- [ ] Hold Right ⌥ alone: the red badge shows. Add Right Shift: the badge turns cream and "Commands" appears beside it straight away. With Universal Control, do this with the pointer on another Mac: the change shows on that Mac. Let a recording reach its last seconds: "Stopping in …" replaces the label and the badge stays cream.
- [ ] Plain Right ⌥ with "YouTube cute cats": the words are typed where the cursor is, nothing opens.
- [ ] Commands mode with words that match nothing: nothing is typed, the words stay on the clipboard, and a notice explains that no command matched. Two commands that fit equally well give "More than one command fits …" and also leave the words on the clipboard without running either command.
- [ ] Near miss, name: with a WhatsApp command and Noam in People, say "WhatsApp norm I'll be late" (or type it in Try it). Nothing is typed at the cursor; the words are on the clipboard and a notice on the Mac you were using shows what you said with "norm?" in the outlined "who" pill, then "Did you mean…?" with up to three name buttons, "Someone else…" and Dismiss. Click Noam: "norm" is saved as another way to say Noam and the WhatsApp command runs with the same words.
- [ ] Near miss, refused: give another person the alias "norm" first, then choose Noam from the notice: it says the name already belongs to the other person and saves nothing.
- [ ] Near miss, start of a command: say "Whatsap Noam hi" (no command starts that way). Nothing is typed; the words stay on the clipboard, and a one-line notice says "Didn't catch which command. Make "Whatsap" mean…" with a picker. Pick WhatsApp a person: nothing runs now, and next time it works.
- [ ] Teach a name: Commands › Build your own › Lists, edit People, press Teach next to Noam. It shows a real phrase such as "WhatsApp Noam" (just "Noam" with no command using the list). Press Record and say it: it stops by itself after two seconds of quiet, with a "Stopping…" bar (and one soft tick) that empties again if you speak, and a "N s left" line for the six-second limit. Do four takes. The results show what was heard on each take; new spellings are ticked, a spelling equal to the name is left out, and one that belongs to someone else is shown with the reason and can't be ticked. When the fixed word was misheard, the whole take is shown and you tap the words that are the name. Save adds the ticked ones to the entry.
- [ ] Teach a trigger: Build your own, edit a command and press Teach beside "Also listen for". Same steps; Save adds them to the field, and saying them now starts the command.
- [ ] Teach from a connected Mac (not the main Mac): it works the same way, and nothing appears in History. Audio is accumulated only while a take is recording; the macOS microphone light can stay on while idle. Cancel during a take: nothing is kept.
- [ ] Teach while dictating is busy, or with the main Mac off: a plain message, no crash.
- [ ] Say only the command name: the page or app opens with nothing typed.
- [ ] Two commands, "Claude" and "Claude Code": saying "Claude Code fix it" picks the longer one (make "Claude Code {prompt}" by hand).
- [ ] A search with a "." at the end of what you said: the search has no trailing full stop. Words with &, # or Hebrew letters arrive intact.
- [ ] Coding assistant: say its name plus a request that contains an apostrophe and quote marks. Terminal opens in the folder and the assistant starts with the whole request as one message. The temporary script is gone afterwards.
- [ ] Coding assistant with a folder that doesn't exist on the Mac that opens it: an alert says so and the words are on the clipboard.
- [ ] App command (for example Notes): the app comes forward and the words are typed once a text field is ready. With an app that never shows one, after about 8 seconds an alert says "Couldn't find a place to type in …" and the words are on the clipboard.
- [ ] With two Macs: dictate with the pointer on the other Mac; the command opens there, not on the Mac that recorded.
- [ ] Turn a command off, or remove it: it no longer matches. The list is the same on every Mac.
- [ ] After a command, `~/Library/Logs/Dictator/hotkey.log` has one `voicelaunch:` line per step with its milliseconds, and a `voicelaunch: total` line measured from key release.

- [ ] Check Commands and Workspaces in the sidebar, page titles, alerts and Settings links. Check “Voice to Power” on welcome and “VOICE TO POWER” in the sidebar. Instructions and the cancellation countdown stay plain; Apple Shortcuts and keyboard shortcuts keep their names. The App Intent title “Run a Voice launch shortcut” and its existing Siri phrases retain their legacy wording for compatibility checks.

- [ ] Commands, Terminal action: edit the command and folder, turn on “Run in the background”, and check that a cancel pause appears and an empty command cannot be saved. With a harmless test script in a temporary folder, run it without a Terminal window and verify one literal argument, including quotes, line breaks and shell-looking text; a leading `--flag` must arrive with a protective space. Check an unsuccessful exit shows its status and a short error in the alert, preserves the words on the clipboard and skips later actions, without writing arguments or output to diagnostics. Set a short time limit and then try Esc during a running script that starts a harmless child; both must stop. Repeat from another Mac and check the script uses the Mac executing the plan. Turn background mode off and verify the visible Terminal action still works.
- [ ] Commands limited to apps: create commands with the same phrase, one global, one only in Safari and one only in another app. Check the editor's app picker and the “Only in Safari” row note. The Safari command wins in Safari, the other app's command wins there, and the global command runs elsewhere. Overlapping scoped duplicates cannot be saved. Repeat from a connected Mac with a different app frontmost on the main Mac, including tap mode and Shift joining a hold. Switch apps after pressing: the original app still decides. Near-miss choices exclude commands for other apps. Try it and an older connected Mac use only the global command. Remove every selected app and confirm the command works everywhere.
### Commands from the keyboard and other apps

Use disposable commands with harmless steps for these checks on both a main Mac and a connected Mac.

- [ ] Give a command with no required spoken parts a keyboard shortcut. It runs on the Mac receiving the key; editing the key, disabling or deleting the command updates registration on both Macs after the settings mirror arrives. Required spoken parts explain why a key cannot be used. Optional parts render empty.
- [ ] Try a key already owned by another command or a Workspaces routine in both editors. It refuses. Recording a key never starts either a command or a routine; closing the recorder restores registration.
- [ ] Copy an opted-in command's link and start it from another app with the installed Release build. Exact names and IDs work, renaming retains the copied ID link, and a command without opt-in only shows a plain notice. Repeat with Dictator initially closed.
- [ ] Add ignored words and other query parameters to the link. None appear in the action, slots or diagnostics. Unknown hosts, missing/duplicate command parameters, invalid ports and control characters cause no action or crash.
- [ ] Use a harmless acting command or a harmless Terminal command. Every link asks Allow/Cancel, names the command and its actions, and Cancel runs nothing. Repeated links while the dialog or command is active run nothing extra. Rapid completed links are limited to one attempt per two seconds.
- [ ] Pause locally and try a command key, routine key and link. Resume and retry. Pause or edit the command while its Allow dialog is open; accepting the old dialog must run nothing.
- [ ] A development build refuses links and command keys even with the development-runtime argument. With both builds installed, verify Launch Services opens the intended Release app; a URL choosing the development app must run nothing.

### Command files

- [ ] Commands › Export: select synthetic commands with list entries, a webhook, a folder, a file path and a web address. Check that all details appear before their inclusion choices. Save with defaults: entries, command IDs, keyboard shortcuts, other-app permission and locations are absent from the bytes. Opt in per list and include locations, then verify the selected details appear. Cancel either panel or sheet: settings stay unchanged.
- [ ] Commands › Import: review that file without running anything. Full program command, folder, address, file path, input and acting steps are visible with “Check this”; mixed-script text and invisible characters are flagged. Every command stays off. Fill omitted values and change a phrase that clashes before confirming; existing list entries remain unchanged. On a connected Mac, confirm the new commands reach the main Mac through normal settings mirroring. Cancel review: nothing is saved.
- [ ] Import malformed JSON, a file over 1 MB, an invalid command, a higher format and an unknown step kind. Each explains the refusal and changes nothing; the last two say “This file needs a newer Dictator.” Opening a JSON file outside Commands never imports it.
- [ ] Recent commands: with disposable settings, run a command successfully, cancel its pause and cause a failure before its first step. Home shows one plain row per plan (five at most), with the correct start method, outcome and time. Unmatched or tied phrases add no row. Missing/ambiguous app or routine names, missing details and Apple Shortcut errors must not put spoken words, app/window names or arbitrary error text in `recent-commands.json`. Relaunch retains at most 50; a corrupt file starts empty. Clear removes the local file and hides the block without changing the dictation list.
- [ ] Run Again: on the main Mac and a connected Mac, repeat a synthetic command from the menu bar. It uses the same words and cancel pauses, with start method Run Again. Apple Shortcuts-started commands say Other app. Relaunch disables replay even with saved activity. Pause clears replay and prevents new activity; history off prevents new activity too. No plan or words appear on disk. Uninstall with optional data removal deletes the file; keeping data retains it.
- [ ] First Welcome only, after dictation is ready: Try a command is optional. Turn on starter commands, check the Commands key and say Open Safari, then see Your command worked. The starters only open apps or Google/YouTube pages. Skip or finish at any point. Existing commands (even disabled) remain unchanged, and existing users do not see Welcome again. Also check success feedback with history off.

## When things go wrong

Each of these should show an on-screen alert saying what happened:

- [ ] Unplug the microphone (or deny microphone permission) and press the key.
- [ ] Turn off Wi-Fi on a Mac whose speech source is another Mac, and dictate.
- [ ] Quit Dictator on the Mac that turns speech into text, with no backup, and dictate. The recording then appears in History & Privacy › Needs your attention, and "Turn Into Text" works once that Mac is back.
- [ ] On a connected Mac with no speech server key: lose a dictation to a dropped connection, reconnect, and "Turn Into Text" works with no key.
- [ ] Quit or update Dictator on the main Mac while dictating on another Mac: the dictation finishes first, then the app quits.
- [ ] Settings › Advanced on the Mac with the speech server: Copy Key works, and the key leaves the clipboard after two minutes unless something else was copied.
- [ ] Press the key with no text field focused: "Your text is on the clipboard".
- [ ] Stay silent while holding the key: "No words were heard".

## History and privacy

- [ ] Turn on saving what you type for one app, send a message there: it appears in History, with any API key shown as `[redacted]`.
- [ ] Pause saving what you type: nothing new is saved from that app until you resume.

## Workspaces on real desks

Workspaces uses `WorkspaceLaunchConfig` and `WorkspaceLaunchController`; its stored `workspaceResetJSON` key remains unchanged.

For the owner to run later, with their go-ahead. It moves real windows, so close anything unsaved first. For every desk below: open Workspaces, pick the "Four corners" starting point, choose three or four apps you have open (include Safari and Mail), and give it a shortcut by clicking the shortcut box and pressing the keys. Then do the same three steps: press **Preview** (nothing moves; the drawing shows where each window will land), press **Run**, press **Undo**. Also press the shortcut once from another app.

First use, once per Mac (before the desks below):

- [ ] With no routines and window control not yet allowed, the page opens on "Get started" with three numbered steps. "Open System Settings" goes to Accessibility; after turning Dictator on and coming back, step 1 shows a check mark without restarting.
- [ ] Pick "Side by side": the editor opens named and laid out, Save is off and the bottom line says "To save, add the apps to use." Choose two apps: it says "Ready to save." After saving (with window control allowed) the "Get started" card gives way to "Your routines", whose line underneath explains Preview, Run and Undo.
- [ ] "Start from scratch" offers Place apps, the existing arrange/center/hide steps and Remember; choosing one names the routine after it.

Record for every desk: the Mac and screens used, what Preview said (copy the lines), what moved where, anything that landed off-screen or on the wrong screen, and whether Restore put everything back.

- [ ] **One screen (laptop alone).** Setup: unplug everything. Set the action's screen to "Right screen". Expect: Preview says "This Mac has one screen, so ‘Right screen’ used it." and the windows tile on the laptop. Run and Restore work.
- [ ] **Two screens side by side.** Setup: laptop on the left, a monitor on the right (System Settings › Displays › Arrange). Try "Left screen", then "Right screen". Expect: the windows go to the screen on that side, no note about fallbacks. Swap the screens in Displays and try again: left and right follow the new arrangement.
- [ ] **Two screens stacked.** Setup: drag the monitor above the laptop in Displays. Try "Left screen": Preview says "These screens are stacked, so ‘Left screen’ used the main screen." and the main screen is used. Then pick "Top screen" under "On this Mac": the windows go to the upper screen.
- [ ] **Three screens.** Setup: laptop in the middle, a monitor on each side. Expect: "Left screen" is the far left one and "Right screen" the far right one. Try "Largest screen" and "Screen under the pointer" (put the pointer on the screen you expect before pressing Preview).
- [ ] **Undocked laptop, routines saved on a desk Mac.** Setup: make the routine on the desk Mac with "Right screen" and wait for it to appear on the laptop. Undock the laptop. Expect: the routine is still there; Preview explains the one-screen fallback; nothing lands off-screen. Then on the laptop set "On this Mac" to "Built-in screen" and save. Back at the desk Mac the routine still uses "Right screen" there (the laptop's choice is only for the laptop).

App placements (owner-run only; both Macs need this build):

- [ ] Start from scratch, choose **Place apps**, and add two apps. Each row has an app, Mac, monitor, position and remove control; “Add app” adds a row. Saving requires an app on every row and disallows the same app twice on one Mac. New placement steps have **Open these apps if they aren't open** on.
- [ ] Choose a running app, a closed installed app, an app via **Choose…**, and a remote-only app by typing its bundle ID and name. No app needs launching just to be chosen. App inventory is local; the typed remote bundle ID is checked only on its target Mac when run.
- [ ] Assign Cursor to Mac mini → Studio Display → right half and Safari to MacBook → built-in screen → left half. Confirm offline Macs remain in the Mac picker. Connected Macs' real monitors appear by name after Refresh monitors, including on a Mac with no open windows; offline choices retain the saved monitor alongside generic choices.
- [ ] Preview on each Mac: no app opens or moves. Local placements draw on their target monitor, closed apps say “will open”, and the other Mac gets one plain line naming apps, monitors and positions.
- [ ] Run by click, keyboard and “Workspace <routine name>”, starting once on each Mac. Each opens only its assigned apps and places only their eligible windows. Put two windows in one app; they share the tile and its previously focused window stays on top. Unplaced apps stay put.
- [ ] Exercise all twelve positions on a monitor to the left/above the main screen. Confirm halves, quarters and thirds fit its usable frame, accounting for menu bar and Dock.
- [ ] Unplug the saved specific monitor: the run finishes on that Mac's main screen, with a note naming the missing monitor and Mac. Reconnect and run again: it uses the specific monitor.
- [ ] Quit an assigned app, then disable opening: it stays closed and is named as skipped. Enable opening: it opens and is placed. Try a nonexistent bundle ID and an app that opens no standard window: notes name the app and Mac, readiness is bounded to eight seconds per app and the overall workspace budget, and other placements finish.
- [ ] Take the named Mac offline, including disconnecting from the main Mac entirely. The local formation still completes; the note says “Mac mini wasn't reached, so Cursor wasn't placed”. Commands reports failure and stops following command actions.

### Open tabs

Uses real browsers and real accounts, so use pages that are safe to open twice.

- [ ] Add an **Open tabs** step with two windows in the same Chrome-family browser, using two profiles. Run with the browser closed, then again with it open. Each window lands in its own profile, in the listed tab order, and the browser doesn't come to the front. The second run opens two more windows.
- [ ] Put Open tabs after a Place apps step for the same browser: the placed windows move and the new window stays where the browser put it. Put it before: the new window is placed too.
- [ ] Repeat in Brave or Edge if installed. Then in Safari and Firefox: pick each with no profile. The editor says the browser decides where pages open. Note where they land.
- [ ] Delete a profile that a saved routine uses, then Preview and Run: both name the browser and profile, and the browser creates no new profile.
- [ ] Uninstall or rename a saved browser: the note names it, and the editor keeps it selected as “(not available right now)”.
- [ ] Type `mailto:a@b.c`, `file:///etc/hosts`, `javascript:alert(1)` and `--incognito`, one per line: each is listed under the field and Save stays off until they're gone. `gmail.com` and `localhost:3000` save as full addresses.
- [ ] Assign a window to another Mac. Its browsers and profiles appear in the pickers. With that Mac offline, the stored choice stays, and a run says “<Mac> wasn't reached, so its tabs didn't open.”
- [ ] On a Mac with Accessibility off, Run and Preview work for a routine that only opens tabs. So does a routine whose window steps belong to another Mac, and the editor on another Mac still lists this Mac's browsers. A routine that moves windows here asks for the permission and opens nothing.
- [ ] Run a window routine on two Macs, then a tab-only routine. Undo still puts the first routine's windows back on both Macs.
- [ ] Run a routine with no working browser by voice: it reports the failure and stops the command.
- [ ] After each run, `hotkey.log` shows `tabs=N` and no address or profile name.

### Window groups

Uses real windows, so close anything unsaved first.

- [ ] Make two routines with “Show only this routine's windows” on, using different apps. Run one, then the other, by keyboard shortcut. The windows swap in well under a second, and the other group's apps are hidden, not closed.
- [ ] Hidden apps appear in Command-Tab and the Dock, and clicking one brings it back.
- [ ] Add an app under “Keep these apps showing”: it stays visible through both groups.
- [ ] Give two routines tab sets in the same Chrome, with two profiles, and set where each window goes. Run each twice: windows swap, no new windows open, and each returns to its place. The other window leaves only a thin sliver at the screen corner.
- [ ] Command-Tab to Chrome with one window showing and one parked: the showing window comes forward. If you close the showing window, Chrome stays in front with nothing visible until Bring back or running its group: activation doesn't move a parked window.
- [ ] Swap to a group without Chrome, then back to one with it: a parked window may flash on screen for a moment as Chrome shows, then parks again. Bring back still returns it to its own place.
- [ ] Open a Chrome window yourself, then swap groups: yours is never parked. Its app may hide with a group that doesn't use Chrome.
- [ ] With a window parked, the “Bring back” row appears on the Workspaces page and returns it. Then park again and try each of: Undo; quit Dictator; force quit Dictator and reopen it; unplug the screen the window came from. The window comes back every time and is reachable.
- [ ] Edit a routine's addresses and run it: a new window opens with the new pages, and the old one stays open.
- [ ] Run a group with none of its apps open and opening turned off: nothing hides, and the status says why.
- [ ] Run a group that names another Mac's apps: nothing hides on a Mac with no work in it.
- [ ] After runs, `workspace-parked.json` holds no addresses or titles, and is gone when nothing is parked.
- [ ] Undo from the initiating Mac restores positions on both Macs, leaves apps it opened running, and says so. A run that opened no apps has no extra Undo sentence. A newer run on a remote Mac still protects its own Undo from an older remote request.
- [ ] Existing Side by side and grid routines still leave minimized windows alone. Load a legacy routine without the new fields: it opens no apps. In an older build using disposable settings, the same placement routine decodes as legacy tiling via `bundleIDs`.

Remembered layouts (both Macs on and connected):

- [ ] On the MacBook built-in screen, put WhatsApp and VS Code in overlapping windows with VS Code in front. Remember, save, swap their front-to-back order, then run: VS Code ends in front again. Run again while already correct: focus stays where it was. Repeat from an app whose windows do not overlap the routine: focus returns to that app; from an app whose window overlaps: focus stays on the frontmost routine window. From Dictator, focus always returns to Dictator. Repeat with a needed minimized window and a closed app with opening enabled. Check the saved drawing has the same tile in front and hotkey.log has one `workspace: stack` line per run with passes, lifted count, final wanted bundle IDs front to back and `focusBack` only. An unavailable lift adds “<app> wouldn't come to the front.” on that Mac and other windows continue.

- [ ] Arrange windows on the main Mac and a connected Mac the way you like them, including a window on a second screen. On either Mac press **Remember on all my Macs**: the editor opens drawing both Macs' windows on their screens, and the line on the page says how many windows each Mac had. Save it with a shortcut.
- [ ] Mess up the windows on both Macs, then press **Run** on one of them: both Macs' windows go back, and the line names the other Mac with what it did. Press the shortcut on the other Mac: the same. Press **Undo**: both Macs' windows return to the messy state.
- [ ] Quit one app on the connected Mac with opening off and run again: Preview and the result say “ChatGPT isn't open, so it wasn't moved. Turn on “Open these apps if they aren't open” to open it.” (using that app’s name). Enable **Open these apps if they aren't open**: it opens only on its assigned Mac, waits for a standard window and is restored. Check that a new Remember step defaults on, a saved step with the field absent stays off, and Remember again preserves either choice. Unplug the second screen and run: its windows go to the main screen and Preview says so.
- [ ] Put the main Mac to sleep and press **Remember on all my Macs** on the connected Mac: it says the other Macs couldn't be reached and remembers that Mac only.
- [ ] Note any window that landed in the wrong spot, and whether two windows of the same app swapped places.

- [ ] Remember five windows on the connected Mac (three ChatGPT, one Herdr, one iTerm2) plus an unrelated app on the main Mac. Minimize one ChatGPT and the Herdr window; leave two extra ChatGPT windows and an extra iTerm2 window on another desktop. Preview changes nothing and says the two minimized windows will come back. Run from the main Mac: all five remembered local windows move, other-desktop windows stay put, and only the connected Mac reports ChatGPT/iTerm2 notes. No app with windows anywhere is called closed. Each Mac has one outcome line followed by grouped notes, with no repeated line. Undo on the starting Mac restores both Macs' geometry and re-minimizes exactly those two windows.
- [ ] Remember one window of an app with one visible and two minimized windows: Run leaves both minimized. Remember three with one visible and three minimized: only two come back. For Place apps, one visible window means no unminimizing; no visible windows means one comes back. A refused unminimize produces a plain note and other apps finish.
- [ ] After each click, keyboard and voice run, and after local/remote Undo, inspect `~/Library/Logs/Dictator/hotkey.log` on each Mac for `workspace:` start/end lines. Check shared operation ID, routine ID, Mac, local/remote origin, trigger, duration, moved/brought-back/re-minimized/opened counts, reason counts with bundle IDs and failure. The starting Mac logs each other Mac's reachability and counts once. Repeat with a Mac offline and an app refusing a move. No window title or typed text appears.

Also check on any desk:

- [ ] Put one Safari window on a different desktop (Mission Control) and one app in full screen, and leave Mail busy (for example, indexing). Preview says “Safari is on another desktop, so it won't move. Switch to that desktop and run this again.” The result says “Safari is on another desktop, so it wasn't moved. Switch to that desktop and run this again.” Other notes still say "Skipped 1 full-screen … window." or "Mail was too slow to answer — try again." Write down any skipped window that was not mentioned, or a mention that was wrong.
- [ ] Before any Preview or Run, Remember and Place apps steps have no conditional desktop note. After Preview or Run finds windows on another desktop for a routine, edit it: both step types show “macOS doesn't let apps move windows between desktops, so these stay where they are.” Check a different routine has no note; Preview or Run again with no other-desktop windows clears it. A run on another Mac also supplies this finding when its result includes skip counts.
- [ ] The header says “Arrange windows on the current desktop by voice, with a click or a keyboard shortcut.” The Remember card and step footer say “Running the routine brings back minimized windows and puts these in place, with the same ones in front. Windows on another desktop stay there.” The hero image is unchanged.
- [ ] For both Remember and Place apps, close ChatGPT with opening off and check the exact toggle hint in Preview and the result. Repeat with a legacy absent choice (still off). With opening on, Preview says it will open; a failure to open keeps the existing failure message without the toggle hint.
- [ ] Shortcuts: record a new one with the keys you really use; the box shows it with ⌃⌥⇧⌘ and the key name (also try with a non-US keyboard layout). Esc cancels, Delete clears. Try a shortcut another routine already has, your dictation key, and ⌥⌘Esc: each shows a plain message and is not saved. Pick one that another app owns (for example one set in that app), turn the routine on, and expect "Another app already uses this shortcut" on that routine.

## Personas

Three setups the V1 promises must survive. The automated part is `PersonaFixtureTests` (screens, spoken phrases, a missing app); these are the checks only a person on that setup can do. Each needs the owner's go-ahead, because it uses the microphone and moves windows.

### Multiple Macs (two Macs, main Mac often asleep)

- [ ] Put the main Mac to sleep, then hold ⌥ on the travelling Mac within a second: "Can't reach your main Mac" appears at once, the dictation records on this Mac, and the text arrives (or History & Privacy offers to turn it into text).
- [ ] Unplug the network mid-dictation: "Lost the connection to your main Mac" says where the recording is kept, and Turn Into Text there works.
- [ ] Update Dictator on only one Mac: the other says "Update Dictator on <Mac>", not "Can't reach".
- [ ] Say a long agent prompt ("um so Claude Code now …", well over a minute): every word after the trigger arrives; check the time limit warning.
- [ ] A command that opens an app the travelling Mac doesn't have (T3 Code, say): the alert names the app and this Mac, and Try it shows the same before you run it.
- [ ] Paste into the terminal and an Electron app (Slack, VS Code): text lands, and the clipboard holds what it held before.
- [ ] Start a Workspaces routine saved on the desk on the undocked travelling Mac: Preview says which screen it used and why.

### Bilingual single-Mac user (Hebrew + English, AirPods, non-US layout)

- [ ] With a layout that types characters with Right ⌥ (Polish or German, say), type such a character: no dictation starts, nothing is recorded, no alert.
- [ ] Choose a different dictation key in Settings and dictate with it.
- [ ] "אממ שלח ליוסי …" runs the send command for יוסי; an English name inside a Hebrew sentence works too.
- [ ] Dictate into a password field: nothing is typed and "Your text is on the clipboard" appears.
- [ ] With AirPods connected, check whether call-quality audio or the microphone indicator stays on while not dictating, and record what you see.

### Multi-monitor desk and its laptop

- [ ] Three screens (main, one to the left, one stacked above): Left, Right, Top, Bottom and Largest each land where the Preview says.
- [ ] Undock the laptop and run the same routine: windows go to its one screen, and Preview explains the fallback.
- [ ] Record a shortcut that another routine already uses: the conflict message shows and the other routine does not run.

## Where a dictation belongs

For the owner to run later with permission for microphone and live-service checks:

- [ ] Macs apart, separate keyboards: leave a pointer claim on one Mac, then dictate on the other. Only the pressing Mac records and receives text with Automatic selected. Repeat in both directions and in hold and tap modes, including a main Mac used as a distant or screenless server. Old pointer activity must not move the words.
- [ ] One keyboard over Universal Control: press while the pointer is on either Mac and confirm both event taps report the gesture. The Mac under the pointer initiates; a microphone on another Mac reporting the same press can record. Release quickly during the settling window, cancel with Esc, and add Right Shift before settling. The release, cancellation and Commands choice must survive settling. Moving the pointer during recording moves the insertion target; earlier activity does not.
- [ ] Typing during the wait: on the main Mac, with old pointer activity on another Mac, press the dictation key and type a character at once, in hold and tap modes. Nothing records and the character still types.
- [ ] A Mac with no microphone: with Automatic selected and another connected Mac able to record, press on the microphone-less Mac alone. Nothing records. That Mac shows “This Mac has no microphone” and Open Your Macs. The warning must not say none of the Macs has a microphone. Choose Mac that records there, repeat, and confirm the chosen Mac records while the words return to the pressing Mac. With no connected microphones at all, confirm the existing microphone alert.
- [ ] In Settings › Your Macs on each role, Mac that records lists Macs with microphones and offers Automatic. Its help reads “Automatic records on the Mac you press the key on. If it has no microphone, Dictator asks first instead of using another Mac.” Change the choice from a connected Mac and confirm the main Mac applies it without reconnecting. Set Automatic remotely and confirm it clears the preference everywhere. Disconnect the chosen recorder and verify Automatic fallback and the unavailable choice are explained; reconnect it and confirm the choice remains. Older peers missing the optional field must not clear it.
- [ ] Press during processing or insertion, in both hold and tap modes: the pressing Mac shows “Still finishing your last dictation” as a notice, no more than once per two seconds, and the original result still arrives. The rejected press records nothing, cannot cancel a later dictation when a character is typed, and cannot trigger a delayed local fallback. After completion, the next press starts normally. Also check hold during tap recording and tap during hold recording; ordinary joined holds and absorbed duplicate taps must not show the notice.

## Startup across a setup

- [ ] Single Mac: General shows the real macOS login state. Enable automatic opening; log out and in, and confirm Dictator returns after login. Disable it and confirm it stays closed on a later login.
- [ ] Turn on Show the window when Dictator opens; quit and reopen and confirm the window appears. Turn it off and repeat; Dictator should remain available in the menu bar. Opening the app again from Finder still brings its window forward.
- [ ] If macOS requires approval, show Waiting for macOS approval and Open Login Items. Return after approving; the actual state refreshes. A denied operation must not show automatic opening as enabled.
- [ ] Multiple Macs: Your Macs shows startup settings reported by each online Mac. Change General on one Mac and confirm other Macs see the change within the normal capability refresh. Settings on the other Macs must stay unchanged.
- [ ] An offline Mac with an old enabled report must show Offline, not a claim that startup is currently configured. An older app without a report must offer update guidance.
- [ ] With permission to interrupt the setup, quit and reopen the main Mac app. Confirm connected Macs reconnect and history sync resumes without re-pairing. Start Dictator before Tailscale is ready and confirm it recovers once the network becomes available.
- [ ] Explain the boundary: startup means after user login, not before login or while asleep. Configuring another Mac requires using that Mac; no invisible remote registration or wake-up occurs.

## Datasets

Use synthetic history only for these checks.

- Open Datasets at the minimum window size and in light/dark appearance. No old charts, watches, suggestions or background notifications remain. Folded sections show summaries that match their settings (for example, turning off key hiding shows a warning in the summary).
- Combine date/time, Sent to (a vendor and a single product), Saved by, website, remote host, full project path, computer and input filters. Sent to must list each product once (the merged ChatGPT app is ChatGPT; CLIs in a terminal resolve to their tool; terminals and herdr/tmux without a recorded tool appear as one Terminal entry). A selection saved by an earlier version still applies. Search using phrase, all terms, any term and a regular expression. Invalid dates/patterns disable export and explain the issue. Zero results never fall back to all history.
- Turn preparation options on/off and inspect the expanded record and exact-file preview. Confirm history is unchanged, same-name project folders stay distinct and missing timing is not represented as zero.
- Export JSONL, JSON and CSV. Verify all selected rows (not just the displayed page), stable IDs, Unicode/multiline text, manifest counts, optional metadata and hashes. When hiding secrets, check prompt text, context and manifest query. CSV formula-leading text must be escaped.
- Save a selection, quit/reopen and restore it. Create a dataset: the bar switches to Copy prompt for agent / Copy path. Paste the brief and check its folder exists and its counts and dates match the manifest. Dictate something new: the ready bar stays. Change a filter: it returns to Create dataset. Change/delete the source rows and verify the snapshot stays unchanged. Attach a synthetic report and save a copy of the dataset elsewhere. Existing destinations must not be overwritten.
- In Datasets › Saved, use a harmless local fixture CLI (not a live agent/service) that echoes stdin. Verify the JSON envelope and exact input/output/receipt. Test nonzero exit, startup failure and cancellation. Only the explicit Run button may start a process. No credentials or models should be selected or downloaded by Dictator.
- Delete a dataset from Datasets › Saved; confirm its history rows and previously exported folders remain. Deleting history must not imply archived packages were deleted.
- Import synthetic supported exports, review before confirming, repeat the import and remove its batch. Existing history deletion markers must still prevent re-import of deleted rows.


## Apps and workspaces by voice

For the owner to run later with permission; these checks open apps and move windows.

- [ ] Enable “Open an app” in Commands. Hold the Commands keys, say “Open Safari” and release. Safari opens on the target Mac. Say “Open chat gpt.” and verify ChatGPT opens if installed; test case, diacritics, punctuation, `.app`, and “T3 Code” for “T3 Code (Beta)”. No model selects an app.
- [ ] Try a missing app and two apps with the same normalized name. Nothing opens; the dictating Mac shows “No app called … on …” or “More than one app is called …: …”. The words stay on the clipboard. Repeat with main and target on different Macs whose installed apps differ.
- [ ] Check apps in /Applications, /System/Applications, /System/Applications/Utilities and ~/Applications, including an immediate vendor folder. A deeper nested app is not discovered. Verify key-down remains responsive while the background hint snapshot refreshes.
- [ ] Save and enable a synthetic “writing” routine under Workspaces, then enable its ready-made voice card and say “Workspace writing”. Verify its normal local changes, other-Mac fan-out and Undo. A following test step runs only after all changes finish. A slow run within the workspace budget must not show an insertion timeout.
- [ ] On each Mac, open any saved routine (Remember, Place apps, or any other actions). Its “Voice command” row offers “Add a voice command”. The sheet has one field with the routine name selected, one help line using this Mac's configured dictation key plus Right Shift, inline problems, Save and Cancel. Empty words, punctuation-only words, curly/square brackets, an overlong phrase, and words already used by another command (including one off or a taught spelling) disable Save; an on conflict says ““X” already listens for those words. Choose different words.” and an off conflict says ““X” already uses those words, but it's turned off. Choose different words, or change it in Commands.” Test both literal words and taught spellings, using the command’s name for X. Enter saves valid words. Test the 100-command limit with disposable settings. No action runs while editing.
- [ ] Save “Start writing”, then say it using the shown keys. The routine runs without “Workspace” or a cancel pause. Its command appears in Commands and can be edited there, including adding other actions. Rename Writing to Drafting: “Start writing” still runs it; the command's display name updates only if it was still Writing. Its summary names Drafting. The old “Workspace Drafting” card still resolves by name.
- [ ] Edit the command from the routine: the saved phrase is selected and a change is reflected in Commands and on the other Mac. Turn the command off in Commands: the routine row shows Off and Turn on; turning it on restores it. Add a second command pointing to the same saved routine: the row shows the first and “and 1 more in Commands”. Remove the first without confirmation and verify the other remains. Test connected-Mac add/edit/remove and reconnect using disposable settings.
- [ ] A linked routine’s Voice command row has a small “Not being heard? Teach it” link. It opens that exact command’s editor in Commands, with the existing Teach control; opening it does not start recording. Check enabled and off commands, two routines with different links, and return/reopen navigation. An unlinked routine has no Teach link.
- [ ] Delete a routine: confirmation names its voice phrases. All its linked workspace actions disappear on both Macs; a command with other actions remains with those actions, and one left empty disappears. Clear all routines and verify the same cleanup. Turn a routine off instead: its phrase stays, but speaking it reports “This routine is off. Turn it on to run it.” A stale ID (disposable settings) fails naming what was said, offers no replacement, keeps the words on the clipboard and stops later actions even if a different routine has the old name.
- [ ] In Commands, add “Run a workspace”: its picker lists saved routine names, and selecting one stores a stable link. Select “The name I say” to reveal the existing name value editor and verify name/slot behavior still works. Rename a selected routine and verify the action summary shows its current name. Remove it and verify the picker and summary explain it was removed.
- [ ] Try a missing, ambiguous or disabled routine, revoked Accessibility permission, and a routine while another is running. The dictating Mac gets a plain failure with the words on the clipboard; later steps do not run. Check a partial execution failure as well.
- [ ] Add a card whose normalized pattern is already present, including a disabled custom command and the WhatsApp/Apple Shortcut variants. It enables the existing command and adds no duplicate. The editor refuses another equivalent pattern.
- [ ] Arrange two different commands that tie for a synthetic sentence. The notice names both, says to turn one off or change what you say, keeps the clipboard line, and “Open Commands” opens that page.
- [ ] Verify the sidebar, page title and explanatory copy say Workspaces. Navigation stays plain and follows the existing destination.
- [ ] On disposable test settings only, confirm an older build cannot decode a voice config containing `runWorkspace` and shows empty Commands. All participating Macs need the updated build; the protocol version stays unchanged.

## Choosing your keys

- [ ] Settings › General: click the dictation keys and press F13 (or another spare key). Hold it and dictate in a text field. The text appears, and the key itself types nothing.
- [ ] Try Left ⌃ + Space. Only that pair starts dictation; Space types as usual, and Right ⌃ + Space does nothing for Dictator.
- [ ] Set a two-modifier pair, such as Right ⌥ + Right ⌘, by pressing both and letting go.
- [ ] Set the Commands keys to a key of their own and run a command with it. Then press the arrow button to go back, and dictation plus Right Shift works again.
- [ ] Try a letter, Space, Esc and Caps Lock: each is refused with a reason and the old keys stay.
- [ ] Choose Left ⌘: it saves with a warning. Press ⌘C: nothing is typed and any brief recording is dropped.
- [ ] Press Esc while recording a key: the old keys stay.
- [ ] With Universal Control, hold F13 and move to the other Mac: dictation stops on its own.
- [ ] Quit and reopen Dictator: your keys are kept. Help, the welcome and the Commands page name them.

## Help

- [ ] Click Help in the sidebar, then go through Basics, Manual, Advanced and FAQ. The Basics pictures play once and replay on hover, and with Reduce Motion on they stay still. Open a topic and follow its button to the right page.
- [ ] Search for "cloud", then for a word that isn't there. The first finds the FAQ answer; the second offers the FAQ.
- [ ] Click the "?" beside each page title, including each Settings tab. The brief fits that page, and Read more in Help opens the right topic.
- [ ] With the main window closed, choose Help from the menu bar icon: the window opens on Help.
- [ ] Press ⌘? and use Help › Dictator Help from the main menu.
- [ ] Change the dictation key in Settings › General. Help and the briefs name the new key.

## Release cleanup

Use disposable homes/bundles for uninstall checks, never the real tool configs. `python3 -m unittest discover -s scripts/tests -p test_uninstall.py -v` covers every bundled hook format, shared-handler preservation, backups, malformed JSON, modified plugins, unconditional shim removal, noninteractive retention and mocked interactive data/server removal. Check the final message names remote SSH hooks, exported dataset copies and System Settings permissions. Open-at-login is `SMAppService`; confirm the script makes no claim to unregister it.

With the owner's permission for microphone/live checks:

- [ ] Hold a dictation through 120 seconds, and repeat in tap mode. The final ten seconds show only the existing “Stopping in …” badge/countdown. At the limit, capture stops; one notice says the recording stopped at 2 minutes and the words were kept. The words still arrive in the text field.
- [ ] Repeat with initiator, mic owner and insertion target on different Macs. The stop notice appears once on the initiating Mac; repeated state broadcasts do not repeat it. Ordinary key release has no limit notice. Check new/old peers connect without a protocol bump.
- [ ] Open Dictator with microphone permission. Observe the idle macOS microphone indicator and, with AirPods, audio quality. Verify the README's engine disclosure against what macOS shows; no idle recording should appear in recovery.
- [ ] On disposable preferences, load `light` and `strong`: `light` becomes "Clean up the text", `strong` becomes "Polish the text". Skip AI clean-up remains selectable. With an older connected Mac, choosing Polish leaves it on ordinary clean-up without echoing a change back.
- [ ] Check Commands website icons use only the site's `apple-touch-icon.png` and `favicon.ico`, with no external icon-service request. The unreachable “Email (just a message)” template is absent; saved user commands remain intact.

## In-app updates

For the release owner to run later with permission for installation and GitHub requests:

- [ ] Build with `DICTATOR_SPARKLE_PUBLIC_KEY` empty. Confirm there is no Check for Updates menu item or automatic-update toggle, and no GitHub update request. Repeat with an ordinary development build.
- [ ] On a disposable release setup with the real public key, confirm Check for Updates… appears above Settings… and General shows Check for updates automatically, initially on. Turn it off, quit and reopen: it stays off on this Mac, and another Mac’s setting is unchanged. Manual Check for Updates… still works. Confirm the controls use plain wording.
- [ ] Generate `appcast.xml` from the exact notarized zip. Confirm its `sparkle:minimumSystemVersion` matches the app’s `LSMinimumSystemVersion`, its enclosure has an EdDSA signature and its URL names the correct release tag and zip. Upload both assets only as an explicit release step.
- [ ] From an older signed release with a lower build number, check for updates, install and relaunch. Confirm the new version runs and the existing Microphone, Accessibility and Input Monitoring permissions still work. Check the no-update and offline cases, and confirm a tampered archive is rejected on a disposable test feed. Confirm no system profile is sent.
