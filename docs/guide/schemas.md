# Schemas

Schemas are reusable objects. Their sorted field order, nested descriptors, and wire fingerprint are computed once.

```luau
local PlayerSchema = Waffles.Schema({
    userId = Waffles.Types.Integer,
    username = Waffles.Types.String,
    position = Waffles.Types.Vector3,
    alive = Waffles.Types.Boolean,
    inventory = Waffles.Types.Array(Waffles.Types.Struct({
        itemId = Waffles.Types.Integer,
        quantity = Waffles.Types.Integer,
    })),
})

local encoded = PlayerSchema:Serialize({
    userId = 123456,
    username = "Player",
    position = Vector3.new(1, 2, 3),
    alive = true,
    inventory = {{itemId = 42, quantity = 3}},
})

local player = PlayerSchema:Deserialize(encoded)
```

Available primitives include `Any`, `Nil`, `Boolean`, `String`, `Number`, `Integer`, `Buffer`, and all Roblox types listed in [Supported types](/guide/supported-types). Composite constructors:

```luau
Waffles.Types.Array(elementType)
Waffles.Types.Optional(innerType)
Waffles.Types.Map(keyType, valueType)
Waffles.Types.Struct({field = typeDefinition})
Waffles.Types.Tuple(firstType, secondType, ...)
Waffles.Types.Enum("valueA", "valueB", ...)
```

Schema maps accept Boolean, String, Number, Integer, or Enum keys. `Any` embeds one automatic value and is useful at deliberately dynamic boundaries. A schema payload can only be decoded by an equivalent schema; a mismatch fails before reading the body.

## Schema validation

Validation is enabled by default. Errors include the complete nested path, expected type, and received category:

```text
[Waffles] Schema validation failed at value.inventory[2].itemId: expected integer, received string "bad"
```

Validate without serializing:

```luau
local valid, message = PlayerSchema:Validate(candidate)
if not valid then
    warn(message)
end
```

Trusted, performance-critical code can disable encode-time validation:

```luau
Waffles.Configure({schemaValidationEnabled = false})
```

Decoding remains bounds-checked. With validation disabled, the caller is responsible for matching every schema field.
