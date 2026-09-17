# Waffles

Waffles is a dependency-free, high-performance binary serialization package for
Roblox. It turns Luau values and common Roblox datatypes into native `buffer`
objects and reconstructs them with guarded, deterministic decoders on both the
client and server.

## Table of contents

1. [What Waffles is](#what-waffles-is)
2. [Features](#features)
3. [Installation](#installation)
4. [Quick start](#quick-start)
5. [Automatic serialization](#automatic-serialization)
6. [Supported types](#supported-types)
7. [Roblox datatype support](#roblox-datatype-support)
8. [Schemas](#schemas)
9. [Schema validation](#schema-validation)
10. [Smart schemas](#smart-schemas)
11. [Batch serialization](#batch-serialization)
12. [Custom converters](#custom-converters)
13. [Buffer helpers](#buffer-helpers)
14. [Configuration](#configuration)
15. [Networking](#networking)
16. [Wire-format-sensitive settings](#wire-format-sensitive-settings)
17. [Security considerations](#security-considerations)
18. [Performance notes](#performance-notes)
19. [API reference](#api-reference)
20. [Examples](#examples)
21. [Troubleshooting](#troubleshooting)
22. [Limitations](#limitations)

## What Waffles is

Waffles provides two complementary codecs:

- Automatic serialization stores compact type tags, so a receiver needs only
  the buffer.
- Explicit schemas omit runtime type information when sender and receiver
  already know the shape.

The v1 format begins with a short magic value, wire version, payload kind, and
a fingerprint of string-reference settings. Schema payloads also contain a
schema fingerprint. No package name or verbose metadata is repeated in a
payload.

## Features

- Native Roblox `buffer` output with no binary-string construction.
- Unsigned varints and ZigZag signed integers.
- Exact `f64` fallback plus `f32` when it round-trips exactly.
- Deterministically sorted maps.
- Payload-local repeated-string and repeated-layout references.
- Configurable common dictionary keys.
- Selective run-length encoding for compressible buffers.
- Reusable explicit schemas and inferred SmartSchemas.
- Native codecs for common Roblox value types.
- Custom converters with stable numeric identifiers.
- Pooled growable writers and reset readers.
- Strict bounds, count, length, recursion, reference, and version checks.

## Installation

### Rojo

The included `default.project.json` maps `src/` to one ModuleScript named
`Waffles` in `ReplicatedStorage`. Build or serve it with your normal Rojo
workflow:

```sh
rojo build default.project.json -o Waffles.rbxlx
```

You can also copy the `src` directory into a project mapping. It must remain a
single ModuleScript tree: `init.luau` is the module source and `Settings.luau`
plus `Internal/` are children.

### Wally

`wally.toml` uses the publication placeholder `placeholder/waffles`. Replace
the scope before publishing. For local use, no publication step is required.

Waffles has no runtime dependencies.

## Quick start

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

## Automatic serialization

`SerializeAuto` inspects each value once, writes a compact tag, and then writes
the value. Small signed integers use ZigZag varints. Strings and buffers are
length-prefixed. Tables are encoded as arrays when their keys are exactly
`1..n`; other tables are maps.

Map keys are sorted by a stable order: booleans, numbers, then strings. Maps
with only string keys define a key layout on first use; another map with the
same sorted layout writes only a layout reference and its values. Long strings
can similarly be referenced after their first appearance.

```luau
local payload = {
    players = {
        {id = 1, displayName = "BreakfastFan"},
        {id = 2, displayName = "SyrupEnjoyer"},
    },
    serverTime = DateTime.now(),
}

local data = Waffles.SerializeAuto(payload)
local copy = Waffles.DeserializeAuto(data)
```

## Supported types

Automatic serialization supports:

- `nil`
- booleans
- numbers, including infinities and NaN
- strings, including arbitrary bytes and UTF-8 text
- native buffers
- contiguous arrays
- dictionaries with boolean, number, or string keys
- arbitrarily mixed nested structures up to the configured depth

Integer encoding supports the signed range
`-4,503,599,627,370,495..4,503,599,627,370,495`. Integral numbers outside
that range use `f64`.

## Roblox datatype support

Automatic codecs are included for:

- `Vector2`, `Vector3`, `Vector2int16`, `Vector3int16`
- `CFrame`
- `Color3`, `BrickColor`
- `UDim`, `UDim2`
- `Rect`, `Ray`
- `NumberRange`
- `NumberSequence`, `NumberSequenceKeypoint`
- `ColorSequence`, `ColorSequenceKeypoint`
- `DateTime`
- `Font`
- `EnumItem`

Vector and color components use native-width floating-point representations.
`CFrame` components use `f64`. Invalid sequence, color, enum, font, and
BrickColor metadata is rejected during decoding.

## Schemas

Schemas are reusable objects. Their sorted field order, nested descriptors, and
wire fingerprint are computed once.

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

Available primitives include `Any`, `Nil`, `Boolean`, `String`, `Number`,
`Integer`, `Buffer`, and all Roblox types listed above. Composite constructors:

```luau
Waffles.Types.Array(elementType)
Waffles.Types.Optional(innerType)
Waffles.Types.Map(keyType, valueType)
Waffles.Types.Struct({field = typeDefinition})
Waffles.Types.Tuple(firstType, secondType, ...)
Waffles.Types.Enum("valueA", "valueB", ...)
```

Schema maps accept Boolean, String, Number, Integer, or Enum keys. `Any` embeds
one automatic value and is useful at deliberately dynamic boundaries. A schema
payload can only be decoded by an equivalent schema; a mismatch fails before
reading the body.

## Schema validation

Validation is enabled by default. Errors include the complete nested path,
expected type, and received category:

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

Decoding remains bounds-checked. With validation disabled, the caller is
responsible for matching every schema field.

## Smart schemas

`SmartSchema` infers a fixed reusable schema from an example. String-keyed
tables become structs, contiguous tables become arrays, and homogeneous array
elements share one inferred type. Heterogeneous positions fall back to `Any`.

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

Inference is deterministic and finishes when `SmartSchema` returns. Create a
new SmartSchema when the intended structure changes; an already used schema
never silently changes its decoding contract.

## Batch serialization

Batch payloads share their string and layout reference tables across all
values, reducing overhead for related messages.

```luau
local encoded = Waffles.SerializeBatch({playerState, worldState, chatState})
local values = Waffles.DeserializeBatch(encoded)
```

Use `table.pack` when a batch contains nil positions. The decoded result has an
`n` field so all slots remain representable:

```luau
local encoded = Waffles.SerializeBatch(table.pack("first", nil, "third"))
local decoded = Waffles.DeserializeBatch(encoded)
print(decoded.n) -- 3
```

## Custom converters

Converters run before built-in automatic dispatch, so they can recognize a
tagged table or an otherwise unsupported userdata. Register the same converter
identifier and implementation on both peers.

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

The converter writer exposes `WriteU8`, `WriteU16`, `WriteU32`, `WriteI16`, `WriteI32`,
`WriteF32`, `WriteF64`, `WriteVarUInt`, `WriteVarInt`, `WriteString`,
`WriteRawString`, `WriteBuffer`, and `WriteRawBuffer`. The reader provides the
matching `Read*` methods plus `Remaining` and `Position`. Length-prefixed reads
also require a maximum length. Converter code is trusted code and must apply
appropriate semantic limits of its own.

## Buffer helpers

```luau
local joined = Waffles.Buffer.Concat(a, b, c)
local middle = Waffles.Buffer.Slice(joined, firstOffset, lastOffsetExclusive)
local same = Waffles.Buffer.Equals(a, b)
local hex = Waffles.Buffer.ToHex(a)
local restored = Waffles.Buffer.FromHex(hex)
```

Offsets are zero-based, matching Roblox buffer APIs. `Slice` uses an exclusive
end offset.

## Configuration

Call `Configure` with only the fields to update. Unknown fields and invalid
types or ranges fail with a `[Waffles]` error.

| Setting | Default | Meaning |
| --- | ---: | --- |
| `poolingEnabled` | `true` | Reuse reset writer and reader state. |
| `writerPoolMaxPerBucket` | `8` | Maximum writers retained per capacity. |
| `maxPooledWriterSize` | `1048576` | Do not retain writer buffers larger than this. |
| `readerPoolMax` | `16` | Maximum reset readers retained. |
| `initialWriterSize` | `256` | Initial power-of-two writer capacity. |
| `rleThreshold` | `0.15` | Required fractional saving before buffer RLE. |
| `sortedKeysCacheEnabled` | `true` | Cache sorted keys with weak table keys. |
| `sortedKeysCacheTrustMode` | `false` | Skip mutation checks for cached keys; unsafe if map keys change. |
| `commonKeys` | `{}` | Ordered shared dictionary-key list. |
| `stringCacheMinLength` | `16` | Minimum length for payload-local string references. |
| `schemaValidationEnabled` | `true` | Validate before schema encoding. |
| `strictBoundsChecking` | `true` | Also reject trailing bytes; primitive reads are always checked. |
| `maxDepth` | `64` | Maximum automatic nesting depth. |
| `maxCollectionCount` | `100000` | Maximum array, map, layout, sequence, or batch count. |
| `maxStringBytes` | `8388608` | Maximum one-string byte length. |
| `maxBufferBytes` | `16777216` | Maximum one-buffer byte length. |
| `maxPayloadBytes` | `33554432` | Maximum input or output payload length. |
| `maxVarintBytes` | `8` | Maximum accepted varint width. |
| `debugAsserts` | `false` | Enable additional internal invariant checks. |

Example:

```luau
Waffles.Configure({
    commonKeys = {"id", "name", "position", "velocity"},
    stringCacheMinLength = 12,
    maxCollectionCount = 25000,
    maxPayloadBytes = 4 * 1024 * 1024,
})
```

`GetConfiguration()` returns a copy of the active settings.

## Networking

```luau
-- Client
RemoteEvent:FireServer(Waffles.SerializeAuto({action = "equip", slot = 3}))

-- Server
RemoteEvent.OnServerEvent:Connect(function(player, payload)
    if typeof(payload) ~= "buffer" then
        return
    end

    local ok, message = pcall(function()
        local data = Waffles.DeserializeAuto(payload)
        -- Authorize and validate gameplay meaning here.
    end)

    if not ok then
        warn("Rejected Waffles payload from", player, message)
    end
end)
```

Default decoding is suitable for parsing client-provided buffers: it checks
every read and applies allocation limits. Binary safety is not gameplay trust;
the server must still authorize actions and validate domain-specific ranges.

Prefer an explicit schema for high-frequency remotes whose structure is known.
It reduces both type-tag bytes and dispatch work.

## Wire-format-sensitive settings

The following must match between sender and receiver:

- `commonKeys`, including exact ordering
- `stringCacheMinLength`
- registered custom converter identifiers and bodies for converters in use
- the Waffles wire version

The first two are covered by the header fingerprint and fail explicitly when
they differ. A missing converter ID also fails explicitly. `maxVarintBytes` is
a receiver safety limit and must be large enough for values sent by the peer.

Compression threshold, pools, writer size, validation, sorted-key caches, and
allocation ceilings do not change the meaning of successfully encoded bytes.
They need not match, though a receiver may reject data above its own limits.

Changing configuration while an encode or decode call is running is not
supported. Configure Waffles during application startup.

## Security considerations

Waffles treats every decoded payload as hostile by default:

- Typed reads check remaining bytes before touching the source buffer.
- Varints reject overflow and excessive continuation bytes.
- Declared strings, buffers, collections, batches, and nesting are limited.
- Counts must be plausible for the remaining payload before allocation.
- String, layout, common-key, enum, and converter references are validated.
- RLE runs must exactly fill their declared output.
- Unknown versions, payload kinds, tags, and schema fingerprints fail.
- Cyclic input tables fail instead of recursing forever.
- Strict mode rejects trailing bytes.

Choose lower limits for narrow remote protocols. Wrap calls that process
untrusted clients in `pcall`, rate-limit remote traffic, and disconnect or
penalize abusive senders according to your game policy.

`sortedKeysCacheTrustMode = true` is an explicit performance tradeoff. Do not
mutate a cached table's key set while it is enabled. Values may still change.

## Performance notes

Waffles deliberately uses direct `buffer.write*` and `buffer.read*` operations,
geometric writer growth, one final trim, precomputed schema descriptors, local
payload caches, weak sorted-key caches, and bounded state pools. Writers and
readers clear user references before pooling.

Selective buffer RLE performs a sizing pass and is used only when it beats the
configured saving threshold. Repeated string layouts are especially effective
for arrays of records. Explicit schemas generally win for stable networking
structures because their fields need no tags or names.

No benchmark numbers are claimed here. Run the included benchmark script in
your target Roblox environment; device, payload, Studio mode, and engine
version materially affect results. It measures encode/decode time, output size,
and approximate Lua heap movement for automatic, schema, repeated-record,
large-array, string-heavy, and deep payloads.

## API reference

### `Waffles.SerializeAuto(value: any): buffer`

Encodes one self-describing supported value.

### `Waffles.DeserializeAuto(data: buffer): any`

Decodes one automatic payload and rejects malformed or mismatched input.

### `Waffles.SerializeBatch(values: {any}): buffer`

Encodes independent values while sharing payload-local caches. Accepts an array
or `table.pack` result.

### `Waffles.DeserializeBatch(data: buffer): {any}`

Decodes a batch. The returned table has `n` equal to the encoded slot count.

### `Waffles.Configure(options: Configuration): ()`

Validates and applies a partial configuration update.

### `Waffles.GetConfiguration(): {[string]: any}`

Returns a defensive copy of active configuration.

### `Waffles.Schema(definitionOrFields): Schema`

Builds a reusable schema from a type definition or struct field map.

### `Waffles.SmartSchema(exampleValue: any): Schema`

Infers and returns a fixed reusable schema.

### `schema:Serialize(value: any): buffer`

Validates when enabled, then performs tagless schema encoding.

### `schema:Deserialize(data: buffer): any`

Checks header and schema fingerprint, then decodes the value.

### `schema:Validate(value: any): (boolean, string?)`

Validates without throwing and returns a path-rich failure message.

### `Waffles.RegisterConverter(name: string, converter): number`

Registers a converter and returns its explicit or derived wire ID. Names and
IDs must be unique.

### `Waffles.Types`

Contains primitive descriptors and `Array`, `Optional`, `Map`, `Struct`,
`Tuple`, and `Enum` constructors.

### `Waffles.Buffer`

Contains `Concat`, `Slice`, `Equals`, `ToHex`, and `FromHex`.

### Version fields

`Waffles.Version` is the package version string. `Waffles.WireVersion` is the
numeric automatic/schema wire version.

## Examples

### Optional profile fields

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

### Shared common keys

Run the same setup on the client and server before sending payloads:

```luau
Waffles.Configure({
    commonKeys = {"type", "id", "position", "rotation", "timestamp"},
})
```

### Mixed dynamic field inside a schema

```luau
local Envelope = Waffles.Schema({
    sequence = Waffles.Types.Integer,
    channel = Waffles.Types.Enum("state", "chat", "effect"),
    body = Waffles.Types.Any,
})
```

### Deterministic persistence blob

```luau
local first = Waffles.SerializeAuto({z = 3, a = 1, m = 2})
local second = Waffles.SerializeAuto({m = 2, z = 3, a = 1})
assert(Waffles.Buffer.Equals(first, second))
```

## Troubleshooting

### `String-reference configuration does not match the payload`

Make `commonKeys` and `stringCacheMinLength` identical on both peers and apply
them before encoding or decoding.

### `Schema does not match the encoded payload`

The receiver used a different field/type definition. Deploy schema changes to
both peers together or version your remote message at the application layer.

### `Unexpected end of buffer`

The payload was truncated, was decoded by the wrong entry point, or is not a
Waffles buffer. Do not retry decoding it as another type.

### `Unsupported value type: Instance`

Instances are intentionally not serialized. Send stable application IDs or
register a converter that resolves only an explicitly safe identifier.

### A schema value fails at a nested path

The message names the exact field or array position. Fix the producing value;
do not disable validation unless the producer is already strictly typed and
trusted.

### Payload rejected by a configured maximum

Prefer reducing or splitting the message. Raise a limit only after assessing
the remote's memory and abuse impact.

## Limitations

- Cyclic graphs and shared table identity are not preserved. Repeated table
  values decode as independent tables.
- Automatic dictionary keys are limited to booleans, numbers, and strings.
- Roblox `Instance`, functions, threads, and connections are unsupported.
- Converter registration is process-local and intentionally cannot be replaced
  after registration.
- Empty Luau tables have no intrinsic array/map identity and encode as arrays.
- Automatic format compatibility is tied to `WireVersion`; schema compatibility
  is additionally tied to the schema fingerprint.
- Waffles provides binary structural safety, not encryption, authentication,
  authorization, or domain validation.

## Tests and benchmarks

`test.project.json` maps the package and the dependency-free test runner. The
suite covers primitives, every native datatype above, nesting, Unicode,
buffers, numeric boundaries, repeated strings/layouts, schemas, optionals,
SmartSchemas, converters, batches, determinism, configuration, truncation at
every byte, hostile counts, bad tags, malformed varints, recursion, cycles, and
500 seeded randomized round trips.

The benchmark script is disabled by default in `test.project.json`. Enable it
when you intentionally want to profile the current Studio/device environment.

Waffles is available under the MIT License.
