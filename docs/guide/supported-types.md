# Supported types

Automatic serialization supports:

- `nil`
- booleans
- numbers, including infinities and NaN
- strings, including arbitrary bytes and UTF-8 text
- native buffers
- contiguous arrays
- dictionaries with boolean, number, or string keys
- arbitrarily mixed nested structures up to the configured depth

Integer encoding supports the signed range `-4,503,599,627,370,495..4,503,599,627,370,495`. Integral numbers outside that range use `f64`.

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

Vector and color components use native-width floating-point representations. `CFrame` components use `f64`. Invalid sequence, color, enum, font, and BrickColor metadata is rejected during decoding.
