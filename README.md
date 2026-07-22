# Desk Layouter

A native macOS menu-bar utility for declaring which applications open on which Desktop.

## Build and run

Desk Layouter requires macOS 13 or newer and the Swift toolchain.

```sh
make build
make run
make test
make test-desktop-placement
```

The application bundle is written to `.build/Desk Layouter.app`. Desk Layouter runs as a menu-bar-only app; launching it opens the editor window automatically, and clicking its menu-bar icon opens or focuses that window. Closing the editor window leaves the app running.

`make test` runs the assignment planner at its pure data boundary without reading or writing the live macOS Desktop store.

`make test-desktop-placement` temporarily applies an Assignment to a disposable app, launches it, and verifies its actual Desktop. The probe restores `app-bindings`, reapplies that original snapshot to the current session, returns to the original active Desktop, and removes probe processes even when it fails.

## Support

[Report a problem on GitHub](https://github.com/Taimonania/desk-layouter/issues/new). Please include your Desk Layouter version, macOS version, expected behavior, and actual behavior. The in-app Settings action opens the same GitHub issue path with these details prefilled.
