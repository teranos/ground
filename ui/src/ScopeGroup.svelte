<script lang="ts">
  import type { ParsedScope } from "./parse.js";
  import ControlRow from "./ControlRow.svelte";

  type FireData = Record<string, {
    count: number;
    lastFired: string | null;
    recent: { session: string; cwd: string; timestamp: string }[];
  }>;

  let { scope, fires }: {
    scope: ParsedScope;
    fires: FireData;
  } = $props();
</script>

<div class="scope-group">
  <div class="scope-header">
    {#if scope.decision !== "allow"}
      <span class="decision-{scope.decision}">{scope.decision}</span>
    {/if}
    <span class="scope-event">{scope.event}</span>
    <span class="scope-path">{scope.path || ""}</span>
  </div>

  {#if scope.controls.length > 0}
    {#each scope.controls as control}
      <ControlRow {control} decision={scope.decision} event={scope.event} {fires} />
    {/each}
  {/if}
</div>
