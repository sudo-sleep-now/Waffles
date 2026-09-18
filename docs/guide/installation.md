# Installation

## Rojo

The included `default.project.json` maps `src/` to one ModuleScript named `Waffles` in `ReplicatedStorage`. Build or serve it with your normal Rojo workflow:

```sh
rojo build default.project.json -o Waffles.rbxlx
```

You can also copy the `src` directory into a project mapping. It must remain a single ModuleScript tree: `init.luau` is the module source and `Settings.luau` plus `Internal/` are children.

## Wally

The package is published as `fouroeight/waffles`. For local use, no publication step is required.

Waffles has no runtime dependencies.
