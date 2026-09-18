# Buffer helpers

```luau
local joined = Waffles.Buffer.Concat(a, b, c)
local middle = Waffles.Buffer.Slice(joined, firstOffset, lastOffsetExclusive)
local same = Waffles.Buffer.Equals(a, b)
local hex = Waffles.Buffer.ToHex(a)
local restored = Waffles.Buffer.FromHex(hex)
```

Offsets are zero-based, matching Roblox buffer APIs. `Slice` uses an exclusive end offset.
