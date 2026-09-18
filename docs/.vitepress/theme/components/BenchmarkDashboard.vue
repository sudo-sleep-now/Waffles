<template>
  <div class="bench-wrap">
    <div class="bench-sub">Final verified benchmark · 5-run medians · local Luau -O2 · lower is better</div>
    <div class="bench-legend">
      <span><span class="dot" style="display:inline-block;width:9px;height:9px;border-radius:50%;background:#e8b04b;margin-right:6px"></span>Waffles</span>
      <span><span class="dot" style="display:inline-block;width:9px;height:9px;border-radius:50%;background:#d38a67;margin-right:6px"></span>Pancakes</span>
    </div>

    <div class="bench-filters" role="group" aria-label="Mode filter">
      <button v-for="m in modes" :key="m" :class="{ on: mode === m }" @click="mode = m">{{ m }}</button>
    </div>
    <div class="bench-filters" role="group" aria-label="Size filter">
      <button v-for="s in sizes" :key="s" :class="{ on: size === s }" @click="size = s">{{ s }}</button>
    </div>

    <div class="bench-grid">
      <div v-for="card in filtered" :key="card.title" class="bench-card">
        <h4>{{ card.title }}</h4>
        <div v-for="r in card.rows" :key="r.label" class="bench-row">
          <div class="bench-top"><span class="lbl">{{ r.label }}</span><span class="adv">{{ r.adv }}</span></div>
          <div class="bar-line">
            <span class="btag w">W</span>
            <div class="track"><div class="fill w" :style="{ width: pct(r.w, r.p) }"></div></div>
            <span class="bval w">{{ r.ws }}</span>
          </div>
          <div class="bar-line">
            <span class="btag p">P</span>
            <div class="track"><div class="fill p" style="width:100%"></div></div>
            <span class="bval p">{{ r.ps }}</span>
          </div>
        </div>
      </div>
    </div>

    <p class="bench-note">Light 40-item and heavy 120-item nested inventories. Warm = steady-state loop, cold = first call, changing = fresh mutated input. Startup require numbers are in µs; schema setup in ms. Keep the Pancakes commit, Luau build, optimization level, CPU, and GC policy pinned when comparing runs.</p>
  </div>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue'

interface Row { label: string; kind: 'Auto' | 'Schema' | 'Setup'; size: '40' | '120'; adv: string; w: number; p: number; ws: string; ps: string }
interface Card { title: string; rows: Row[] }

const modes = ['All', 'Auto', 'Schema'] as const
const sizes = ['All sizes', '40-item', '120-item'] as const
const mode = ref<(typeof modes)[number]>('All')
const size = ref<(typeof sizes)[number]>('All sizes')

const DATA: Card[] = [
  { title: 'Startup', rows: [
    { label: 'Module require · 40', kind: 'Auto', size: '40', adv: '46.4% W advantage', w: 6637.035, p: 12371.48, ws: '6,637.035', ps: '12,371.48' },
    { label: 'Module require · 120', kind: 'Auto', size: '120', adv: '47.5% W advantage', w: 6775.229, p: 12902.787, ws: '6,775.229', ps: '12,902.787' },
    { label: 'Schema setup · 40', kind: 'Schema', size: '40', adv: '12.9% W advantage', w: 1.48, p: 1.7, ws: '1.48', ps: '1.7' },
    { label: 'Schema setup · 120', kind: 'Schema', size: '120', adv: '28.2% W advantage', w: 1.45, p: 2.02, ws: '1.45', ps: '2.02' },
  ]},
  { title: 'Output size · bytes', rows: [
    { label: 'Auto · 40', kind: 'Auto', size: '40', adv: '10.2% W advantage', w: 570, p: 635, ws: '570', ps: '635' },
    { label: 'Auto · 120', kind: 'Auto', size: '120', adv: '12.0% W advantage', w: 1619, p: 1840, ws: '1,619', ps: '1,840' },
    { label: 'Schema · 40', kind: 'Schema', size: '40', adv: '5.5% W advantage', w: 587, p: 621, ws: '587', ps: '621' },
    { label: 'Schema · 120', kind: 'Schema', size: '120', adv: '6.4% W advantage', w: 1765, p: 1886, ws: '1,765', ps: '1,886' },
  ]},
  { title: 'Cold encode · µs', rows: [
    { label: 'Auto · 40', kind: 'Auto', size: '40', adv: '15.3% W advantage', w: 63.527, p: 74.977, ws: '63.527', ps: '74.977' },
    { label: 'Auto · 120', kind: 'Auto', size: '120', adv: '14.8% W advantage', w: 115.965, p: 136.164, ws: '115.965', ps: '136.164' },
    { label: 'Schema · 40', kind: 'Schema', size: '40', adv: '29.8% W advantage', w: 60.427, p: 86.046, ws: '60.427', ps: '86.046' },
    { label: 'Schema · 120', kind: 'Schema', size: '120', adv: '29.5% W advantage', w: 105.055, p: 149.003, ws: '105.055', ps: '149.003' },
  ]},
  { title: 'Cold decode · µs', rows: [
    { label: 'Auto · 40', kind: 'Auto', size: '40', adv: '28.6% W advantage', w: 36.868, p: 51.668, ws: '36.868', ps: '51.668' },
    { label: 'Auto · 120', kind: 'Auto', size: '120', adv: '17.3% W advantage', w: 81.417, p: 98.495, ws: '81.417', ps: '98.495' },
    { label: 'Schema · 40', kind: 'Schema', size: '40', adv: '10.9% W advantage', w: 35.579, p: 39.929, ws: '35.579', ps: '39.929' },
    { label: 'Schema · 120', kind: 'Schema', size: '120', adv: '11.5% W advantage', w: 84.816, p: 95.815, ws: '84.816', ps: '95.815' },
  ]},
  { title: 'Warm encode · µs', rows: [
    { label: 'Auto · 40', kind: 'Auto', size: '40', adv: '19.1% W advantage', w: 4.479, p: 5.537, ws: '4.479', ps: '5.537' },
    { label: 'Auto · 120', kind: 'Auto', size: '120', adv: '23.8% W advantage', w: 12.298, p: 16.14, ws: '12.298', ps: '16.14' },
    { label: 'Schema · 40', kind: 'Schema', size: '40', adv: '14.2% W advantage', w: 4.412, p: 5.145, ws: '4.412', ps: '5.145' },
    { label: 'Schema · 120', kind: 'Schema', size: '120', adv: '21.6% W advantage', w: 12.412, p: 15.828, ws: '12.412', ps: '15.828' },
  ]},
  { title: 'Warm decode · µs', rows: [
    { label: 'Auto · 40', kind: 'Auto', size: '40', adv: '45.7% W advantage', w: 2.04, p: 3.758, ws: '2.04', ps: '3.758' },
    { label: 'Auto · 120', kind: 'Auto', size: '120', adv: '47.8% W advantage', w: 5.681, p: 10.881, ws: '5.681', ps: '10.881' },
    { label: 'Schema · 40', kind: 'Schema', size: '40', adv: '44.5% W advantage', w: 2.115, p: 3.814, ws: '2.115', ps: '3.814' },
    { label: 'Schema · 120', kind: 'Schema', size: '120', adv: '47.8% W advantage', w: 5.711, p: 10.95, ws: '5.711', ps: '10.95' },
  ]},
  { title: 'Changing encode · µs', rows: [
    { label: 'Auto · 40', kind: 'Auto', size: '40', adv: '16.2% W advantage', w: 23.171, p: 27.648, ws: '23.171', ps: '27.648' },
    { label: 'Auto · 120', kind: 'Auto', size: '120', adv: '6.6% W advantage', w: 59.955, p: 64.199, ws: '59.955', ps: '64.199' },
    { label: 'Schema · 40', kind: 'Schema', size: '40', adv: '8.6% W advantage', w: 19.759, p: 21.629, ws: '19.759', ps: '21.629' },
    { label: 'Schema · 120', kind: 'Schema', size: '120', adv: '17.7% W advantage', w: 53.108, p: 64.508, ws: '53.108', ps: '64.508' },
  ]},
  { title: 'Changing decode · µs', rows: [
    { label: 'Auto · 40', kind: 'Auto', size: '40', adv: '4.7% W advantage', w: 18.907, p: 19.849, ws: '18.907', ps: '19.849' },
    { label: 'Auto · 120', kind: 'Auto', size: '120', adv: '5.1% W advantage', w: 48.235, p: 50.837, ws: '48.235', ps: '50.837' },
    { label: 'Schema · 40', kind: 'Schema', size: '40', adv: '25.8% W advantage', w: 18.934, p: 25.52, ws: '18.934', ps: '25.52' },
    { label: 'Schema · 120', kind: 'Schema', size: '120', adv: '26.8% W advantage', w: 55.286, p: 75.478, ws: '55.286', ps: '75.478' },
  ]},
]

function pct(w: number, p: number): string {
  return `${((w / Math.max(w, p)) * 100).toFixed(1)}%`
}

const filtered = computed<Card[]>(() => {
  const wantSize = size.value === 'All sizes' ? null : size.value.startsWith('40') ? '40' : '120'
  return DATA.map((c) => ({
    ...c,
    rows: c.rows.filter(
      (r) =>
        (mode.value === 'All' || r.kind === mode.value || (c.title === 'Startup' && mode.value === 'All')) &&
        (!wantSize || r.size === wantSize),
    ),
  })).filter((c) => {
    if (c.title === 'Startup') {
      // Startup rows are require/setup, not Auto/Schema payloads — keep visible for All only
      if (mode.value !== 'All') return false
      return c.rows.length > 0
    }
    return c.rows.length > 0
  })
})
</script>
