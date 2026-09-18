# Batch serialization

Batch payloads share their string and layout reference tables across all values, reducing overhead for related messages.

```luau
local encoded = Waffles.SerializeBatch({playerState, worldState, chatState})
local values = Waffles.DeserializeBatch(encoded)
```

Use `table.pack` when a batch contains nil positions. The decoded result has an `n` field so all slots remain representable:

```luau
local encoded = Waffles.SerializeBatch(table.pack("first", nil, "third"))
local decoded = Waffles.DeserializeBatch(encoded)
print(decoded.n) -- 3
```
