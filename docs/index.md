---
layout: home

hero:
  name: Waffles
  text: Binary serialization for Roblox Luau
  tagline: Dependency-free, high-performance codecs that turn Luau values into native buffer objects — with guarded, deterministic decoders.
  image:
    src: /waffle.svg
    alt: Waffles logo
  actions:
    - theme: brand
      text: Quick start
      link: /guide/quick-start
    - theme: alt
      text: Download
      link: /releases
    - theme: alt
      text: Benchmarks vs Pancakes
      link: /benchmarks
    - theme: alt
      text: API reference
      link: /reference/api

features:
  - title: Two codecs, one package
    details: Self-describing automatic values plus tagless explicit schemas for known shapes.
  - title: Native buffer I/O
    details: Direct buffer.write* / read* ops, pooled writers and readers, one final trim.
  - title: Compact by default
    details: Varints, ZigZag ints, f32 fast-path, sorted maps, string & layout references, selective RLE.
  - title: Roblox natives
    details: Vector, CFrame, Color, UDim, Rect, Ray, sequences, DateTime, Font, EnumItem.
  - title: Guarded decoders
    details: Bounds, count, length, recursion, reference, fingerprint, and version checks.
  - title: Up to 47.8% faster decodes
    details: Verified 5-run medians against Pancakes on 40- and 120-item inventories.
---
