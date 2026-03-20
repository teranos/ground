import { mount } from "svelte";
import App from "./App.svelte";
import { parsePbt, type ParseResult } from "./parse.js";

type ControlFile = { name: string; content: string };

type FireData = Record<string, {
  count: number;
  last_fired: string | null;
  buckets: number[];
}>;

function mockData(): { files: ParseResult[]; fires: FireData } {
  const mock: ControlFile[] = [
    {
      name: "mockery",
      content: `
scope {
  path: ""
  decision: "allow"
  event: "PreToolUse"

  control {
    name: "nice-try"
    cmd: "rm -rf"
    omit: "/"
    msg: "You really thought you could run this outside Tauri?"
  }

  control {
    name: "skill-issue"
    cmd: "git push --force"
    msg: "Ah yes, the classic. Force push to main. What could go wrong."
  }

  control {
    name: "copilot-refugee"
    cmd: "npm install"
    msg: "Another dependency? The node_modules folder weeps."
  }
}

scope {
  path: ""
  decision: "ask"
  event: "PreToolUse"

  control {
    name: "hallucination-check"
    cmd: "claude"
    msg: "Are you sure about that? Like, really sure? Check your sources."
  }

  control {
    name: "vibe-check"
    cmd: "deploy"
    msg: "Deploying on a Friday? Bold. Reckless. Inevitable."
  }
}

scope {
  path: ""
  decision: "deny"
  event: "PreToolUse"

  control {
    name: "no-css-frameworks"
    cmd: "npx tailwindcss"
    msg: "You were just talking about this. Make up your mind."
  }
}

scope {
  path: ""
  decision: "allow"
  event: "Stop"

  control {
    name: "ego-death-mock"
    stop: "I'm confident"
    stop: "I'm sure"
    msg: "Confidence is not evidence. Show your work."
  }

  control {
    name: "graunde-is-watching"
    stop: "no one will notice"
    msg: "Graunde noticed. Graunde always notices."
  }
}

scope {
  path: ""
  decision: "allow"
  event: "SessionStart"

  control {
    name: "mock-binary-check"
    check_handler: "realityCheck"
    msg: "You are running mock data. None of this is real. Touch grass."
  }
}

scope {
  path: ""
  decision: "allow"
  event: "UserPromptSubmit"

  control {
    name: "existential-crisis"
    userprompt: "why"
    msg: "Why indeed. The controls don't know either. They just fire."
  }
}
`,
    },
  ];

  const fires: FireData = {
    "nice-try": { count: 0, last_fired: null, buckets: [0, 0, 0, 0, 0, 0, 0] },
    "skill-issue": { count: 247, last_fired: "2026-03-19T23:00:00Z", buckets: [12, 45, 38, 29, 51, 33, 39] },
    "copilot-refugee": { count: 1842, last_fired: "2026-03-20T02:30:00Z", buckets: [200, 280, 310, 250, 270, 290, 242] },
    "hallucination-check": { count: 99, last_fired: "2026-03-20T01:00:00Z", buckets: [8, 15, 12, 18, 14, 16, 16] },
    "vibe-check": { count: 3, last_fired: "2026-03-14T17:00:00Z", buckets: [0, 0, 0, 0, 0, 1, 2] },
    "no-css-frameworks": { count: 1, last_fired: "2026-03-20T00:47:00Z", buckets: [0, 0, 0, 0, 0, 0, 1] },
    "ego-death-mock": { count: 512, last_fired: "2026-03-20T03:00:00Z", buckets: [60, 72, 80, 65, 78, 85, 72] },
    "graunde-is-watching": { count: 7, last_fired: "2026-03-19T14:00:00Z", buckets: [1, 1, 1, 1, 1, 1, 1] },
    "existential-crisis": { count: 42, last_fired: "2026-03-19T22:00:00Z", buckets: [4, 6, 7, 5, 8, 6, 6] },
  };

  return { files: mock.map(f => parsePbt(f.content, f.name)), fires };
}

async function init() {
  let files: ParseResult[];
  let fires: FireData;

  if ((window as any).__TAURI__) {
    const { invoke } = await import("@tauri-apps/api/core");
    const [rawFiles, firesData] = await Promise.all([
      invoke<ControlFile[]>("read_controls"),
      invoke<FireData>("read_fires"),
    ]);
    files = rawFiles.map(f => parsePbt(f.content, f.name));
    fires = firesData;
  } else {
    const mock = mockData();
    files = mock.files;
    fires = mock.fires;
  }

  mount(App, {
    target: document.getElementById("app")!,
    props: { files, fires },
  });
}

init();
