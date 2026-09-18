# Tests & benchmarks

`test.project.json` maps the package and the dependency-free test runner. The suite covers primitives, every native datatype above, nesting, Unicode, buffers, numeric boundaries, repeated strings/layouts, schemas, optionals, SmartSchemas, converters, batches, determinism, configuration, truncation at every byte, hostile counts, bad tags, malformed varints, recursion, cycles, and 500 seeded randomized round trips.

The benchmark script is disabled by default in `test.project.json`. Enable it when you intentionally want to profile the current Studio/device environment.

Waffles is available under the MIT License.
