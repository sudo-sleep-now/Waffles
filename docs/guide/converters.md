# Custom converters

Converters run before built-in automatic dispatch, so they can recognize a tagged table or an otherwise unsupported userdata. Register the same converter identifier and implementation on both peers.

```luau
Waffles.RegisterConverter("GridPoint", {
    Id = 7001, -- optional; a stable name hash is used when omitted

    CanSerialize = function(value)
        return type(value) == "table" and value.kind == "GridPoint"
    end,

    Serialize = function(writer, value)
        writer:WriteVarInt(value.x)
        writer:WriteVarInt(value.y)
    end,

    Deserialize = function(reader)
        return {
            kind = "GridPoint",
            x = reader:ReadVarInt("GridPoint.x"),
            y = reader:ReadVarInt("GridPoint.y"),
        }
    end,
})
```

The converter writer exposes `WriteU8`, `WriteU16`, `WriteU32`, `WriteI16`, `WriteI32`, `WriteF32`, `WriteF64`, `WriteVarUInt`, `WriteVarInt`, `WriteString`, `WriteRawString`, `WriteBuffer`, and `WriteRawBuffer`. The reader provides the matching `Read*` methods plus `Remaining` and `Position`. Length-prefixed reads also require a maximum length. Converter code is trusted code and must apply appropriate semantic limits of its own.
