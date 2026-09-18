<template>
  <div class="rel-card">
    <div v-if="loading" class="rel-muted">Checking GitHub for the latest release…</div>

    <div v-else-if="error || !rel" class="rel-muted">
      Couldn't reach the GitHub API right now. Get Waffles directly from
      <a href="https://github.com/sudo-sleep-now/Waffles/releases" target="_blank" rel="noreferrer">github.com/sudo-sleep-now/Waffles/releases</a>.
    </div>

    <div v-else>
      <div class="rel-top">
        <span class="rel-tag">{{ rel.tag_name }}</span>
        <span class="rel-name">{{ rel.name || rel.tag_name }}</span>
      </div>
      <div class="rel-meta">
        Published {{ date }} ·
        <a :href="rel.html_url" target="_blank" rel="noreferrer">view on GitHub</a>
      </div>

      <div v-if="rel.assets.length" class="rel-assets">
        <a
          v-for="a in rel.assets"
          :key="a.id"
          class="rel-btn"
          :href="a.browser_download_url"
        >
          ↓ {{ a.name }} <span>({{ size(a.size) }})</span>
        </a>
      </div>
      <div v-else class="rel-muted">No binary assets on this release — use the source archives below.</div>

      <div class="rel-src">
        Source:
        <a :href="`https://github.com/sudo-sleep-now/Waffles/archive/refs/tags/${rel.tag_name}.zip`">.zip</a>
        ·
        <a :href="`https://github.com/sudo-sleep-now/Waffles/archive/refs/tags/${rel.tag_name}.tar.gz`">.tar.gz</a>
      </div>

      <details v-if="rel.body" class="rel-notes">
        <summary>Release notes</summary>
        <pre>{{ rel.body }}</pre>
      </details>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'

interface Asset {
  id: number
  name: string
  size: number
  browser_download_url: string
}
interface Release {
  tag_name: string
  name: string
  html_url: string
  published_at: string
  body: string
  assets: Asset[]
}

const loading = ref(true)
const error = ref(false)
const rel = ref<Release | null>(null)

const date = computed(() =>
  rel.value ? new Date(rel.value.published_at).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : '',
)

function size(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / 1024 / 1024).toFixed(2)} MB`
}

onMounted(async () => {
  try {
    const r = await fetch('https://api.github.com/repos/sudo-sleep-now/Waffles/releases/latest')
    if (!r.ok) throw new Error(`GitHub API: ${r.status}`)
    rel.value = (await r.json()) as Release
  } catch {
    error.value = true
  } finally {
    loading.value = false
  }
})
</script>

<style scoped>
.rel-card {
  border: 1px solid var(--vp-c-border);
  border-radius: 16px;
  background: #1e1610;
  padding: 18px;
  margin: 18px 0;
}
.rel-muted {
  color: var(--vp-c-text-2);
  font-size: 14px;
}
.rel-top {
  display: flex;
  align-items: baseline;
  gap: 10px;
  flex-wrap: wrap;
}
.rel-tag {
  font-family: var(--vp-font-family-mono);
  font-weight: 800;
  font-size: 20px;
  color: #e8b04b;
  background: rgba(232, 176, 75, 0.12);
  border: 1px solid #6b5326;
  padding: 2px 12px;
  border-radius: 999px;
}
.rel-name {
  font-weight: 700;
  font-size: 16px;
}
.rel-meta {
  color: var(--vp-c-text-2);
  font-size: 13px;
  margin: 8px 0 4px;
}
.rel-assets {
  display: flex;
  gap: 10px;
  flex-wrap: wrap;
  margin: 14px 0 6px;
}
.rel-btn {
  display: inline-block;
  background: #e8b04b;
  color: #1d1407 !important;
  font-weight: 700;
  font-size: 14px;
  padding: 10px 18px;
  border-radius: 10px;
  text-decoration: none !important;
}
.rel-btn:hover {
  filter: brightness(1.07);
}
.rel-btn span {
  font-weight: 600;
  opacity: 0.7;
}
.rel-src {
  font-size: 13.5px;
  color: var(--vp-c-text-2);
  margin-top: 8px;
}
.rel-notes {
  margin-top: 12px;
  font-size: 13.5px;
}
.rel-notes summary {
  cursor: pointer;
  font-weight: 650;
}
.rel-notes pre {
  white-space: pre-wrap;
  background: #120d08;
  border: 1px solid var(--vp-c-border);
  border-radius: 10px;
  padding: 12px 14px;
  font-size: 12.5px;
  color: var(--vp-c-text-2);
}
</style>
