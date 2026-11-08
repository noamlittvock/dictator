// Installed by Dictator (Settings → Prompts). Hands each prompt you send in
// OpenCode to Dictator's capture shim; delete this file to stop. It never
// changes or delays the message.
const SHIM = __DICTATOR_CAPTURE_PATH__;

export const DictatorCapture = async ({ directory }) => ({
  "chat.message": async (input, output) => {
    try {
      const text = (output?.parts ?? [])
        .filter((part) => part?.type === "text" && !part.synthetic)
        .map((part) => part.text)
        .join("\n");
      if (!text.trim()) return;
      const proc = Bun.spawn([SHIM, "hook", "opencode"], { stdin: "pipe", stdout: "ignore", stderr: "ignore" });
      proc.stdin.write(JSON.stringify({ session_id: input?.sessionID, cwd: directory, prompt: text }));
      proc.stdin.end();
    } catch {}
  },
});
