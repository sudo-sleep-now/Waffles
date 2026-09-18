# Pancakes comparison

`Benchmark.server.luau` is the Roblox/Studio companion and prints one
machine-readable `RESULT` line for each Waffles Auto/Schema case. It reports
cold encode/decode, warm encode, warm same-buffer decode after cache admission,
warm fresh-buffer decode, changing-input encode/decode, and output bytes.

The published comparison dashboard uses five fresh Luau processes for every
Pancakes/Waffles × Auto/Schema × 40/120-item case. The recorded environment is
Luau 0.738 with `-O2`; Pancakes is pinned to commit
`0c03c004a1600c2380e2ca00977256773b156ff6`. Keep the runtime, optimization
level, CPU, and GC policy fixed when collecting new medians.

Run the committed matrix with the pinned checkouts explicitly:

```bash
PANCAKES_DIR=/path/to/pancakes \
LUAU_BIN=/path/to/luau \
benchmarks/run-pancakes-vs-waffles.sh > /tmp/pancakes-vs-waffles.txt
```

The runner stages both libraries into a flat directory for plain Luau,
launches five fresh processes per case, and emits one `RESULT` line per
process. The dashboard values are medians of those lines.

Fresh-buffer decode deliberately means a new buffer object containing the same
wire bytes. Both implementations may serve that case from a previously
promoted exact-wire snapshot; Waffles still leaves a unique wire on the direct
path and validates every content hit with `buffersEqual`. The changing-input
decode row is the direct-path comparison when neither implementation can reuse
a stable snapshot.
