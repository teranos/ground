import { mount } from "svelte";
import { invoke } from "@tauri-apps/api/core";
import App from "./App.svelte";
import { parseTextproto, type ParseResult } from "./parse.js";

type TextprotoFile = { name: string; content: string };

type FireData = Record<string, {
  count: number;
  last_fired: string | null;
  buckets: number[];
}>;

async function init() {
  const [rawFiles, fires] = await Promise.all([
    invoke<TextprotoFile[]>("read_textprotos"),
    invoke<FireData>("read_fires"),
  ]);

  const files = rawFiles.map(f => parseTextproto(f.content, f.name));

  mount(App, {
    target: document.getElementById("app")!,
    props: { files, fires },
  });
}

init();
