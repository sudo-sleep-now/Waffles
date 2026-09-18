# Smart schemas

`SmartSchema` infers a fixed reusable schema from an example. String-keyed tables become structs, contiguous tables become arrays, and homogeneous array elements share one inferred type. Heterogeneous positions fall back to `Any`.

```luau
local example = {
    userId = 100,
    name = "Player",
    scores = {10, 20, 30},
    active = true,
}

local schema = Waffles.SmartSchema(example)
local encoded = schema:Serialize(example)
local decoded = schema:Deserialize(encoded)
```

Inference is deterministic and finishes when `SmartSchema` returns. Create a new SmartSchema when the intended structure changes; an already used schema never silently changes its decoding contract.
