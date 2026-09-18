# API reference

## `Waffles.SerializeAuto(value: any): buffer`

Encodes one self-describing supported value.

## `Waffles.DeserializeAuto(data: buffer): any`

Decodes one automatic payload and rejects malformed or mismatched input.

## `Waffles.SerializeBatch(values: {any}): buffer`

Encodes independent values while sharing payload-local caches. Accepts an array or `table.pack` result.

## `Waffles.DeserializeBatch(data: buffer): {any}`

Decodes a batch. The returned table has `n` equal to the encoded slot count.

## `Waffles.Configure(options: Configuration): ()`

Validates and applies a partial configuration update.

## `Waffles.GetConfiguration(): {[string]: any}`

Returns a defensive copy of active configuration.

## `Waffles.Schema(definitionOrFields): Schema`

Builds a reusable schema from a type definition or struct field map.

## `Waffles.SmartSchema(exampleValue: any): Schema`

Infers and returns a fixed reusable schema.

## `schema:Serialize(value: any): buffer`

Validates when enabled, then performs tagless schema encoding.

## `schema:Deserialize(data: buffer): any`

Checks header and schema fingerprint, then decodes the value.

## `schema:Validate(value: any): (boolean, string?)`

Validates without throwing and returns a path-rich failure message.

## `Waffles.RegisterConverter(name: string, converter): number`

Registers a converter and returns its explicit or derived wire ID. Names and IDs must be unique.

## `Waffles.Types`

Contains primitive descriptors and `Array`, `Optional`, `Map`, `Struct`, `Tuple`, and `Enum` constructors.

## `Waffles.Buffer`

Contains `Concat`, `Slice`, `Equals`, `ToHex`, and `FromHex`.

## Version fields

`Waffles.Version` is the package version string. `Waffles.WireVersion` is the numeric automatic/schema wire version.
