# Changelog

## 1.1.0 - 2026-09-18

- Added bounded compact-record decoding with packed optional presence masks.
- Enforced compact string limits, including cached-plan revalidation, and
  preserved negative zero in automatic record arrays.
- Added compact one-byte framing for repeated strings in A6 schema columns.
- Restored warm decode performance with two-hit hybrid admission: fresh network
  buffers decode directly, repeated identities use isolated snapshots only
  after promotion, and promoted exact wires can serve fresh buffer objects
  after full equality validation. Added no-receiver primitive column readers
  for compact Auto and A6 schema arrays.
- Added a reproducible Pancakes comparison harness covering five fresh Luau
  processes, cold/warm same-buffer and fresh-buffer decode, changing inputs,
  startup/setup cost, and output size; refreshed the benchmark dashboard and
  inline warm-decode visualization with the measured medians.
- Enabled decode snapshot caching by default, stabilized struct definitions by
  cloning field tables, and rebuilt the Rojo artifact for wire version 2.

## 1.0.0 - 2026-09-17

- Initial Waffles release with automatic serialization, reusable schemas,
  SmartSchema inference, custom converters, Roblox datatype codecs, guarded
  decoding, batch payloads, pooling, RLE, and buffer helpers.
