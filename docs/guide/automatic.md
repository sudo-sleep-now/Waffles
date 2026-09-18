# Automatic serialization

`SerializeAuto` inspects each value once, writes a compact tag, and then writes the value. Small signed integers use ZigZag varints. Strings and buffers are length-prefixed. Tables are encoded as arrays when their keys are exactly `1..n`; other tables are maps.

Map keys are sorted by a stable order: booleans, numbers, then strings. Maps with only string keys define a key layout on first use; another map with the same sorted layout writes only a layout reference and its values. Long strings can similarly be referenced after their first appearance.

Arrays containing two or more homogeneous primitive records use a compact typed-record layout: field names and primitive kinds are written once, optional presence is bit-packed, and values are emitted column-wise.

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
