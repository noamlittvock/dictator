# Security

Dictator can hold Microphone, Accessibility and Input Monitoring permissions. Those rights let it record speech, inspect accessible fields, insert text and respond to keyboard input. A vulnerability affecting them can expose private information or let an action run with the user's authority.

## Report a vulnerability privately

Use [GitHub's private vulnerability reporting](https://github.com/noamlittvock/dictator/security/advisories/new). On this repository, choose **Security → Advisories → Report a vulnerability**. [GitHub's reporting guide](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately) explains the private process.

Include the affected version or commit, macOS version, impact, and minimal reproduction steps using synthetic data. Remove tokens, personal addresses, dictation history and recordings from attachments. Do not open a public issue or pull request containing vulnerability details. If the private report option is unavailable, ask for it to be enabled without disclosing the vulnerability publicly.

## Threat boundaries

The rules in [`AGENTS.md`](AGENTS.md) and [`docs/architecture.md`](docs/architecture.md) define the intended boundaries:

- Nothing listens beyond Tailscale. The main Mac and speech server bind only to a Tailscale address, and join requests come only from Tailscale's range. Ollama is not exposed for dictation; connected Macs reach it through Dictator's connection.
- Remote servers are reached only through the user's SSH, with validated hosts and quoted paths. No listener is added to a remote server.
- Each Mac reads and writes its own store. Sharing uses replication and mirrored settings, rather than direct access to another Mac's files.
- Pairing and speech-server tokens are credentials. Tailscale membership alone does not replace application authorization. A copied invitation or token should stay private.
- Background commands run as the user. Spoken words are passed as a quoted argument, never as shell code.
- `dictator://` links run only commands that opted in. Links cannot pass words to a command, and commands that act ask first.
- macOS permissions are granted on each Mac's own screen. Typed history is off until the user enables it, and no keystrokes are held when no typed place is enabled. History analysis and delivery to a configured CLI are explicit user choices.

Reports that cross these boundaries, bypass consent, leak saved data or trigger unintended actions are security reports. Use the private channel even if you are unsure of the impact.
