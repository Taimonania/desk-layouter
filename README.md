# Desk Layouter

A native macOS menu-bar utility for declaring which applications open on which Desktop.

## Build and run

Desk Layouter requires macOS 13 or newer and the Swift toolchain.

```sh
make build
make run
make test
```

The application bundle is written to `.build/Desk Layouter.app`. Desk Layouter runs as a menu-bar-only app; click its menu-bar icon to open the editor window. Closing the editor window leaves the app running.

`make test` runs the assignment planner at its pure data boundary without reading or writing the live macOS Desktop store.
