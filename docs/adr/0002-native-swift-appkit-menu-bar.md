# Native Swift + AppKit menu-bar app

The app is built as a native **Swift + AppKit** menu-bar utility (`LSUIElement`, no Dock icon), with SwiftUI used only for the editor window. It runs unsigned/self-installed — personal use, no App Store, no notarization.

Electron and Tauri were considered and rejected: they add a runtime but grant **zero** extra ability to control Desktops/Spaces (the app's core job), which lives entirely in native macOS frameworks and the `com.apple.spaces` store. A native app also means direct, unsandboxed access to `NSWorkspace`, `SMAppService`, and (for the future window-layout feature) the Accessibility API, with no bridging overhead.
