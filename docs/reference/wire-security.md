# Wire format & security

## Wire-format-sensitive settings

The following must match between sender and receiver:

- `commonKeys`, including exact ordering
- `stringCacheMinLength`
- registered custom converter identifiers and bodies for converters in use
- the Waffles wire version

The current release advertises wire version 2 because primitive schema struct-arrays use the A6 columnar representation. Version-1 payloads are not accepted by a version-2 reader; deploy the rebuilt artifact to every peer.

The first two are covered by the header fingerprint and fail explicitly when they differ. A missing converter ID also fails explicitly. `maxVarintBytes` is a receiver safety limit and must be large enough for values sent by the peer.

Compression threshold, pools, writer size, validation, sorted-key caches, and allocation ceilings do not change the meaning of successfully encoded bytes. They need not match, though a receiver may reject data above its own limits.

Changing configuration while an encode or decode call is running is not supported. Configure Waffles during application startup.

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

Choose lower limits for narrow remote protocols. Wrap calls that process untrusted clients in `pcall`, rate-limit remote traffic, and disconnect or penalize abusive senders according to your game policy.

::: warning Trust mode
`sortedKeysCacheTrustMode = true` is an explicit performance tradeoff. Do not mutate a cached table's key set while it is enabled. Values may still change.
:::
