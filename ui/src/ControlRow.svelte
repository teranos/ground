<script lang="ts">
  import type { ParsedControl } from "./parse.js";

  type FireData = Record<string, {
    count: number;
    lastFired: string | null;
    buckets: number[];
  }>;

  let { control, decision, event, fires }: {
    control: ParsedControl;
    decision: string;
    event: string;
    fires: FireData;
  } = $props();

  const fire = $derived(fires[control.name]);

  // Collect the DSL fields that are set on this control
  function fields(): { key: string; value: string }[] {
    const f: { key: string; value: string }[] = [];
    if (control.cmd) f.push({ key: "cmd", value: control.cmd });
    if (control.filepath) f.push({ key: "filepath", value: control.filepath });
    if (control.userprompt) f.push({ key: "userprompt", value: control.userprompt });
    if (control.checkHandler) f.push({ key: "check_handler", value: control.checkHandler });
    if (control.delayHandler) f.push({ key: "delay_handler", value: control.delayHandler });
    if (control.deliverHandler) f.push({ key: "deliver_handler", value: control.deliverHandler });
    for (const t of control.triggers) {
      const key = event === "Stop" ? "stop" : "posttool";
      f.push({ key, value: t });
    }
    if (control.deferPrefix) f.push({ key: "defer_prefix", value: control.deferPrefix });
    if (control.deferSec) f.push({ key: "defer_sec", value: String(control.deferSec) });
    if (control.tmo) f.push({ key: "tmo", value: String(control.tmo) });
    return f;
  }

  // Modifiers as pills with type for styling
  function pills(): { text: string; type: string }[] {
    const p: { text: string; type: string }[] = [];
    if (control.omit) p.push({ text: "omit: " + control.omit, type: "omit" });
    if (control.arg) p.push({ text: "arg: " + control.arg, type: "arg" });
    if (control.bg) p.push({ text: "bg", type: "bg" });
    return p;
  }

  function barHeight(bucket: number, max: number): string {
    if (max === 0) return "0";
    return Math.round((bucket / max) * 14) + "px";
  }
</script>

<div class="control-row {decision}">
  <div class="control-layout">
    <div class="control-body">
      <div class="control-top">
        <span class="control-name">{control.name}</span>
        {#each fields() as { key, value }}
          <span class="control-field"><span class="field-key">{key}:</span> {value}</span>
        {/each}
        {#each pills() as pill}
          <span class="control-pill pill-{pill.type}">{pill.text}</span>
        {/each}
      </div>
      {#if control.msg}
        <div class="control-msg">{control.msg}</div>
      {/if}
    </div>

    {#if fire?.count}
      {@const max = Math.max(...fire.buckets)}
      <div class="fire-bar">
        <span class="fire-count">{fire.count}</span>
        <div class="spark">
          {#each fire.buckets as b}
            <div class="spark-bar" style="height: {barHeight(b, max)}"></div>
          {/each}
        </div>
      </div>
    {/if}
  </div>
</div>
