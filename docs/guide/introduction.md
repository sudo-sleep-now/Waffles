# Introduction

Waffles is a dependency-free, high-performance binary serialization package for Roblox. It turns Luau values and common Roblox datatypes into native `buffer` objects and reconstructs them with guarded, deterministic decoders on both the client and server.

## Two complementary codecs

- **Automatic serialization** stores compact type tags, so a receiver needs only the buffer.
- **Explicit schemas** omit runtime type information when sender and receiver already know the shape.

The current format begins with a short magic value, wire version, payload kind, and a fingerprint of string-reference settings. Schema payloads also contain a schema fingerprint. No package name or verbose metadata is repeated in a payload.

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

## Where to go next

1. [Installation](/guide/installation) — Rojo / Wally setup.
2. [Quick start](/guide/quick-start) — encode your first value in 30 seconds.
3. [Benchmarks](/benchmarks) — Waffles vs Pancakes, verified numbers.
