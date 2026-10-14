# Zeta Toolchain

Package management for [Haliade OS](https://github.com/gretagen). Two tools:

| Tool | What |
|---|---|
| `zeta-makepkg` | Build engine: `.recipe` → binary tarball + `package.lua` |
| `zeta-cli` | Interactive wizard: prompts → `.recipe` file |

## Quick Start

```sh
# Create a recipe interactively
./cli/zeta-cli

# Build it
./builder/zeta-makepkg mypkg.recipe --output ~/zeta-packages

# Install system-wide
make install
```

## Recipe Format

Declarative Lua — no functions, just data:

```lua
return {
  name           = "mypkg",
  version        = "1.0",
  summary        = "Short description",
  url            = "https://.../src.tar.gz",
  deps           = { "libfoo", "libbar>=2.0" },
  build_system   = "autotools",       -- autotools | cmake | meson | make | cargo | custom
  configure_args = { "--enable-x" },
  test           = "${DESTDIR}/usr/bin/mypkg --version",
}
```

**Build systems**: `autotools`, `cmake`, `meson`, `make`, `cargo`, `custom`

## Structure

```
toolchain/
├── cli/          zeta-cli — recipe wizard
├── builder/      zeta-makepkg — build engine
├── lib/          shared Lua modules
├── examples/     example .recipe files
└── Makefile
```

## Requirements

- Lua 5.1+
- `curl` or `wget` (source downloads)
- `tar`, `sha256sum` (packaging)
- Build tools for your chosen `build_system` (gcc, meson, cmake, cargo, etc.)

## License

MIT
