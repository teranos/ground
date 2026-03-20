<script lang="ts">
  import type { ParseResult } from "./parse.js";
  import ScopeGroup from "./ScopeGroup.svelte";

  type FireData = Record<string, {
    count: number;
    last_fired: string | null;
    buckets: number[];
  }>;

  let { files, fires }: {
    files: ParseResult[];
    fires: FireData;
  } = $props();
</script>

<div class="grid">
  {#each files as file}
    {#each file.scopes as scope}
      <div class="grid-card">
        <div class="card-source">{file.source}</div>
        <ScopeGroup {scope} {fires} />
      </div>
    {/each}
  {/each}
</div>
