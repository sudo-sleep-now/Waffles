# Performance notes

Waffles deliberately uses direct `buffer.write*` and `buffer.read*` operations, geometric writer growth, one final trim, precomputed schema descriptors, local payload caches, weak sorted-key caches, and bounded state pools. Writers and readers clear user references before pooling.

Selective buffer RLE performs a sizing pass and is used only when it beats the configured saving threshold. Repeated string layouts and compact typed records are especially effective for arrays of records. Explicit schemas generally win for stable networking structures because their fields need no tags or names.

::: tip Measure, don't guess
No benchmark numbers are claimed here. Run the included benchmark script in your target Roblox environment; device, payload, Studio mode, and engine version materially affect results. It mirrors the external comparison's light 40-item and heavy 120-item nested inventories, reports warm encode/decode microseconds, cold first-call timings, same-buffer and fresh-buffer warm decode, changing-input diagnostics, startup/setup overhead, and output bytes. See [Benchmarks vs Pancakes](/benchmarks).
:::
