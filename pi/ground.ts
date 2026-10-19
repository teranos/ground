// "and another thing i want, but that is a way bigger item, is for ground to be usage usable with coding agent pi"

// ground speaks Claude Code's hook protocol: the event's JSON on stdin, an exit code, systemMessage
// and hookSpecificOutput. This extension says each Pi event to ground as the hook it is, and does
// what ground answered: exit 2 blocks a tool, refuses a prompt, or holds the run from settling.

import { spawn } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

/** What ground answered one event with. */
export interface Answered {
	code: number;
	stdout: string;
	stderr: string;
}

/** Runs ground with the event on stdin, as a Claude Code hook would: `ground` on PATH. */
export function groundSays(event: Record<string, unknown>, cwd: string): Promise<Answered> {
	return new Promise((resolve, reject) => {
		const run = spawn("ground", [], { cwd, stdio: ["pipe", "pipe", "pipe"] });
		let stdout = "";
		let stderr = "";
		run.stdout.on("data", (chunk) => (stdout += chunk));
		run.stderr.on("data", (chunk) => (stderr += chunk));
		run.on("error", (err) => reject(new Error(`ground did not start: ${err.message}`)));
		run.on("close", (code, signal) => {
			if (code === null) {
				reject(new Error(`ground ended on ${signal} without an exit code`));
				return;
			}
			resolve({ code, stdout, stderr });
		});
		run.stdin.end(JSON.stringify(event));
	});
}

// The tools as Claude Code names them, which ground's controls match on.
const CLAUDE_NAMES: Record<string, string> = {
	bash: "Bash", read: "Read", write: "Write", edit: "Edit", grep: "Grep", find: "Glob", ls: "LS",
};

/** A Pi tool call as the Claude Code tool ground's controls name: its name, and file_path for path. */
export function asClaude(toolName: string, input: Record<string, unknown>): { tool_name: string; tool_input: Record<string, unknown> } {
	const tool_input: Record<string, unknown> = { ...input };
	if ("path" in input) tool_input.file_path = input.path;
	const edits = input.edits;
	if (Array.isArray(edits) && edits.length === 1) {
		tool_input.old_string = edits[0].oldText;
		tool_input.new_string = edits[0].newText;
	}
	return { tool_name: CLAUDE_NAMES[toolName] ?? toolName, tool_input };
}

/** What ground's stdout gives the model as context, from hookSpecificOutput.additionalContext. */
export function contextOf(stdout: string): string {
	const line = stdout.trim().split("\n").reverse().find((l) => l.startsWith("{"));
	if (line === undefined) return "";
	const said = JSON.parse(line) as { hookSpecificOutput?: { additionalContext?: string } };
	return said.hookSpecificOutput?.additionalContext ?? "";
}

export default function (pi: ExtensionAPI) {
	const base = (event: string, ctx: ExtensionContext) => ({
		hook_event_name: event,
		session_id: ctx.sessionManager.getSessionId(),
		cwd: ctx.cwd,
	});
	const told = (ctx: ExtensionContext, context: string) => {
		if (context !== "") pi.sendMessage({ customType: "ground", content: context, display: false });
	};
	// A Stop that was held once is said again as one: ground then lets the run settle, as it does for Claude Code.
	let held = false;

	pi.on("session_start", async (event, ctx) => {
		const answered = await groundSays({ ...base("SessionStart", ctx), source: event.reason }, ctx.cwd);
		told(ctx, contextOf(answered.stdout));
	});

	pi.on("before_agent_start", async (event, ctx) => {
		held = false;
		const answered = await groundSays({ ...base("UserPromptSubmit", ctx), prompt: event.prompt }, ctx.cwd);
		if (answered.code === 2) {
			return { message: { customType: "ground", content: answered.stderr, display: true } };
		}
		const context = contextOf(answered.stdout);
		if (context !== "") return { message: { customType: "ground", content: context, display: false } };
	});

	// A tool_call handler that throws blocks the tool: ground that cannot run is ground that did not allow it.
	pi.on("tool_call", async (event, ctx) => {
		const answered = await groundSays({ ...base("PreToolUse", ctx), ...asClaude(event.toolName, event.input as Record<string, unknown>) }, ctx.cwd);
		if (answered.code === 2) return { block: true, reason: answered.stderr };
	});

	pi.on("tool_result", async (event, ctx) => {
		const response = { content: event.content, is_error: event.isError };
		const answered = await groundSays({ ...base("PostToolUse", ctx), ...asClaude(event.toolName, event.input), tool_response: response }, ctx.cwd);
		told(ctx, contextOf(answered.stdout));
	});

	pi.on("agent_before_settle", async (_event, ctx) => {
		const answered = await groundSays({ ...base("Stop", ctx), stop_hook_active: held }, ctx.cwd);
		if (answered.code !== 2) return;
		held = true;
		return { entries: [{ type: "custom_message", customType: "ground", content: answered.stderr, display: true }], continue: true };
	});
}
