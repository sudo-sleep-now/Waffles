# Benchmarks: Pancakes vs Waffles

Final verified benchmark · 5-run medians · local Luau -O2 · **lower is better**.

Waffles (mine) beats Pancakes (direct competitor) in **every measured case** — startup, payload size, and cold / warm / changing encode and decode, across Auto and Schema codecs at both 40-item (light) and 120-item (heavy) nested inventories.

<BenchmarkDashboard />

## How to read this

- **Startup** — module require cost plus one-time schema setup. Waffles requires ~46–47% faster.
- **Output size** — encoded bytes. Waffles is 5–12% smaller.
- **Cold** — first-call cost with no caches warm. Waffles leads by 11–30%.
- **Warm** — steady-state loop. Decode is the standout: Waffles is ~45–48% faster.
- **Changing** — fresh mutated input each iteration (caches can't just replay). Waffles still leads every case.

## Reproduce it

No benchmark numbers should be taken on faith — run the included benchmark script in your target Roblox environment. Device, payload, Studio mode, and engine version materially affect results. It mirrors the external comparison's light 40-item and heavy 120-item nested inventories and reports warm encode/decode microseconds, cold first-call timings, same-buffer and fresh-buffer warm decode, changing-input diagnostics, startup/setup overhead, and output bytes.
