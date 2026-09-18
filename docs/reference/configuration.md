# Configuration

Call `Configure` with only the fields to update. Unknown fields and invalid types or ranges fail with a `[Waffles]` error.

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
| `stringCacheMinLength` | `4` | Minimum length for payload-local string references. |
| `schemaValidationEnabled` | `true` | Validate while schema values are encoded. |
| `strictBoundsChecking` | `true` | Also reject trailing bytes; primitive reads are always checked. |
| `encodeSnapshotCacheEnabled` | `true` | Reuse encoded bytes for unchanged table identities. |
| `decodeSnapshotCacheEnabled` | `true` | Two-hit decoded-value cache; first and second decodes stay direct. |
| `maxDepth` | `64` | Maximum automatic nesting depth. |
| `maxCollectionCount` | `100000` | Maximum array, map, layout, sequence, or batch count. |
| `maxRecordCells` | `8000000` | Maximum decoded cells in one compact typed/schema record array. |
| `maxRecordFields` | `1024` | Maximum fields in one compact typed/schema record array. |
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
    maxRecordCells = 2000000,
    maxPayloadBytes = 4 * 1024 * 1024,
})
```

`GetConfiguration()` returns a copy of the active settings.
