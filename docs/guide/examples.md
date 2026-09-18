# Examples

## Optional profile fields

```luau
local Profile = Waffles.Schema({
    id = Waffles.Types.Integer,
    displayName = Waffles.Types.String,
    clanTag = Waffles.Types.Optional(Waffles.Types.String),
    badges = Waffles.Types.Array(Waffles.Types.Integer),
})

local bytes = Profile:Serialize({
    id = 9001,
    displayName = "Waffle",
    clanTag = nil,
    badges = {10, 20, 30},
})
```

## Shared common keys

Run the same setup on the client and server before sending payloads:

```luau
Waffles.Configure({
    commonKeys = {"type", "id", "position", "rotation", "timestamp"},
})
```

## Mixed dynamic field inside a schema

```luau
local Envelope = Waffles.Schema({
    sequence = Waffles.Types.Integer,
    channel = Waffles.Types.Enum("state", "chat", "effect"),
    body = Waffles.Types.Any,
})
```

## Deterministic persistence blob

```luau
local first = Waffles.SerializeAuto({z = 3, a = 1, m = 2})
local second = Waffles.SerializeAuto({m = 2, z = 3, a = 1})
assert(Waffles.Buffer.Equals(first, second))
```
