# Quick start

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Waffles = require(ReplicatedStorage.Waffles)

local encoded = Waffles.SerializeAuto({
    coins = 1250,
    name = "Player",
    equipped = true,
})

local decoded = Waffles.DeserializeAuto(encoded)
print(decoded.coins) -- 1250
```

`encoded` is a native Roblox `buffer`.

## Next steps

- [Automatic serialization](/guide/automatic) — how tags, maps, and typed records work.
- [Schemas](/guide/schemas) — tagless encoding for known shapes.
- [Networking](/reference/networking) — the safe client → server pattern.
