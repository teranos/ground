// "and another thing i want, but that is a way bigger item, is for ground to be usage usable with coding agent pi"

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import extension, { asClaude, contextOf } from "./ground";

// A stand-in ground on PATH: it keeps each event it is given, and answers by its hook_event_name.
let dir = "";
let path = "";
beforeAll(() => {
	dir = mkdtempSync(join(tmpdir(), "ground-pi-"));
	writeFileSync(join(dir, "ground"), `#!/bin/sh
input=$(cat)
printf '%s\\n' "$input" >> "${dir}/said"
case "$input" in
  *'"PreToolUse"'*'rm -rf'*) echo "ground: not that" >&2; exit 2 ;;
  *'"SessionStart"'*) echo '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"grove performs here"}}'; exit 0 ;;
  *'"Stop"'*'"stop_hook_active":false'*) echo "ground: one more rite" >&2; exit 2 ;;
esac
exit 0
`);
	chmodSync(join(dir, "ground"), 0o755);
	path = process.env.PATH ?? "";
	process.env.PATH = `${dir}:${path}`;
});
afterAll(() => {
	process.env.PATH = path;
	rmSync(dir, { recursive: true });
});

type Handler = (event: any, ctx: any) => Promise<any>;
function loaded() {
	const on: Record<string, Handler> = {};
	const sent: any[] = [];
	extension({ on: (name: string, h: Handler) => (on[name] = h), sendMessage: (m: any) => sent.push(m) } as any);
	const ctx = { cwd: dir, sessionManager: { getSessionId: () => "pi-1" } };
	return { on, sent, ctx };
}
const said = () => readFileSync(join(dir, "said"), "utf8").trim().split("\n").map((l) => JSON.parse(l));

describe("ground under Pi", () => {
	test("a Pi tool is said to ground as the Claude Code tool its controls name", () => {
		expect(asClaude("bash", { command: "ls" })).toEqual({ tool_name: "Bash", tool_input: { command: "ls" } });
		expect(asClaude("read", { path: "a.d" }).tool_input.file_path).toBe("a.d");
		expect(asClaude("edit", { path: "a.d", edits: [{ oldText: "x", newText: "y" }] }).tool_input).toMatchObject({
			file_path: "a.d", old_string: "x", new_string: "y",
		});
	});

	test("what ground gives the model is read from its hookSpecificOutput", () => {
		expect(contextOf('ground: 3ms\n{"hookSpecificOutput":{"additionalContext":"grove"}}\n')).toBe("grove");
		expect(contextOf('{"systemMessage":"up"}')).toBe("");
	});

	test("SessionStart's context reaches the model", async () => {
		const { on, sent, ctx } = loaded();
		await on.session_start({ reason: "startup" }, ctx);
		expect(sent).toEqual([{ customType: "ground", content: "grove performs here", display: false }]);
		expect(said().at(-1)).toMatchObject({ hook_event_name: "SessionStart", session_id: "pi-1", source: "startup" });
	});

	test("ground's exit 2 on PreToolUse blocks the tool, in ground's words", async () => {
		const { on, ctx } = loaded();
		expect(await on.tool_call({ toolName: "bash", input: { command: "rm -rf /" } }, ctx)).toEqual({ block: true, reason: "ground: not that\n" });
		expect(await on.tool_call({ toolName: "bash", input: { command: "ls" } }, ctx)).toBeUndefined();
	});

	test("ground holds a Stop once, and lets it settle when it is said again as held", async () => {
		const { on, ctx } = loaded();
		await on.before_agent_start({ prompt: "go" }, ctx);
		const first = await on.agent_before_settle({}, ctx);
		expect(first).toEqual({ continue: true, entries: [{ type: "custom_message", customType: "ground", content: "ground: one more rite\n", display: true }] });
		expect(await on.agent_before_settle({}, ctx)).toBeUndefined();
		expect(said().filter((e) => e.hook_event_name === "Stop").map((e) => e.stop_hook_active)).toEqual([false, true]);
	});

	test("PostToolUse carries what the tool answered", async () => {
		const { on, ctx } = loaded();
		await on.tool_result({ toolName: "write", input: { path: "W.md", content: "x" }, content: [{ type: "text", text: "ok" }], isError: false }, ctx);
		expect(said().at(-1)).toMatchObject({ hook_event_name: "PostToolUse", tool_name: "Write", tool_input: { file_path: "W.md" }, tool_response: { is_error: false } });
	});
});
