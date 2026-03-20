export interface ParsedControl {
  name: string;
  cmd: string;
  arg: string;
  omit: string;
  triggers: string[];
  filepath: string;
  userprompt: string;
  msg: string;
  bg: boolean;
  tmo: number;
  checkHandler: string;
  delayHandler: string;
  deliverHandler: string;
  deferPrefix: string;
  deferSec: number;
}

export interface ParsedScope {
  path: string;
  decision: string;
  event: string;
  controls: ParsedControl[];
}

export interface ParseResult {
  scopes: ParsedScope[];
  source: string; // filename
}

function makeControl(): ParsedControl {
  return {
    name: "", cmd: "", arg: "", omit: "", triggers: [],
    filepath: "", userprompt: "", msg: "", bg: false, tmo: 0,
    checkHandler: "", delayHandler: "", deliverHandler: "",
    deferPrefix: "", deferSec: 0,
  };
}

function makeScope(): ParsedScope {
  return { path: "", decision: "", event: "", controls: [] };
}

export function parsePbt(input: string, source: string): ParseResult {
  const result: ParseResult = { scopes: [], source };
  let pos = 0;

  function skipWS() {
    while (pos < input.length && " \t\n\r".includes(input[pos])) pos++;
  }

  function skipLine() {
    while (pos < input.length && input[pos] !== "\n") pos++;
    if (pos < input.length) pos++;
  }

  function readWord(): string {
    const start = pos;
    while (pos < input.length && !" \t\n\r:{}".includes(input[pos])) pos++;
    return input.slice(start, pos);
  }

  function readValue(): string {
    if (pos < input.length && input[pos] === '"') return readQuoted();
    if (pos < input.length && input[pos] === '`') return readBacktick();
    const start = pos;
    while (pos < input.length && !" \t\n\r}".includes(input[pos])) pos++;
    return input.slice(start, pos);
  }

  function readQuoted(): string {
    pos++; // skip "
    const start = pos;
    while (pos < input.length && input[pos] !== '"') pos++;
    const val = input.slice(start, pos);
    pos++; // skip "
    return val;
  }

  function readBacktick(): string {
    pos++; // skip `
    const start = pos;
    while (pos < input.length && input[pos] !== '`') pos++;
    const val = input.slice(start, pos);
    pos++; // skip `
    return val;
  }

  function expect(ch: string) {
    if (input[pos] !== ch) throw new Error(`Expected '${ch}' at ${pos}, got '${input[pos]}'`);
    pos++;
  }

  function parseControl(): ParsedControl {
    const c = makeControl();
    while (pos < input.length) {
      skipWS();
      if (pos >= input.length) break;
      if (input[pos] === '#') { skipLine(); continue; }
      if (input[pos] === '}') { pos++; return c; }

      const key = readWord();
      skipWS(); expect(':'); skipWS();
      const val = readValue();

      switch (key) {
        case "name": c.name = val; break;
        case "cmd": c.cmd = val; break;
        case "arg": c.arg = val; break;
        case "omit": c.omit = val; break;
        case "filepath": c.filepath = val; break;
        case "userprompt": c.userprompt = val; break;
        case "msg": c.msg = val; break;
        case "bg": c.bg = val === "true"; break;
        case "tmo": c.tmo = parseInt(val, 10); break;
        case "check_handler": c.checkHandler = val; break;
        case "delay_handler": c.delayHandler = val; break;
        case "deliver_handler": c.deliverHandler = val; break;
        case "defer_prefix": c.deferPrefix = val; break;
        case "defer_sec": c.deferSec = parseInt(val, 10); break;
        case "stop":
        case "posttool":
          c.triggers.push(val); break;
      }
    }
    throw new Error("Unterminated control block");
  }

  function parseScope(): ParsedScope {
    const sc = makeScope();
    while (pos < input.length) {
      skipWS();
      if (pos >= input.length) break;
      if (input[pos] === '#') { skipLine(); continue; }
      if (input[pos] === '}') { pos++; return sc; }

      const key = readWord();
      if (key === "control") {
        skipWS(); expect('{');
        sc.controls.push(parseControl());
      } else {
        skipWS(); expect(':'); skipWS();
        const val = readValue();
        switch (key) {
          case "path": sc.path = val; break;
          case "decision": sc.decision = val; break;
          case "event": sc.event = val; break;
        }
      }
    }
    throw new Error("Unterminated scope block");
  }

  while (pos < input.length) {
    skipWS();
    if (pos >= input.length) break;
    if (input[pos] === '#') { skipLine(); continue; }

    const word = readWord();
    if (word === "scope") {
      skipWS(); expect('{');
      result.scopes.push(parseScope());
    }
  }

  return result;
}

// Group scopes by event type across all parsed files
export interface EventGroup {
  event: string;
  scopes: (ParsedScope & { source: string })[];
}

export function groupByEvent(files: ParseResult[]): EventGroup[] {
  const map = new Map<string, (ParsedScope & { source: string })[]>();

  for (const file of files) {
    for (const scope of file.scopes) {
      const list = map.get(scope.event) ?? [];
      list.push({ ...scope, source: file.source });
      map.set(scope.event, list);
    }
  }

  // Stable order: PreToolUse first, then alphabetical
  const order = [
    "PreToolUse", "PreToolUseFile", "PostToolUse",
    "PostToolUseDeferred", "PostToolUseFailure",
    "Stop", "UserPromptSubmit", "SessionStart", "PreCompact",
  ];

  const groups: EventGroup[] = [];
  for (const event of order) {
    const scopes = map.get(event);
    if (scopes) groups.push({ event, scopes });
  }
  // Any remaining events not in order
  for (const [event, scopes] of map) {
    if (!order.includes(event)) groups.push({ event, scopes });
  }
  return groups;
}
