# Kubar

Basic macOS menu bar app written in Swift.

## Open in Xcode

Open `Kubar.xcodeproj`, then run the `Kubar` target.

The app uses SwiftUI's `MenuBarExtra` and sets `LSUIElement=YES`, so it appears in the macOS menu bar without a Dock icon.

## Command line

`kubar` is a cross-platform CLI (macOS, Linux, Windows) built on the same `KubarCore` package. It needs `kubectl` on PATH.

```sh
swift run kubar                                # status + nodes for the current context
swift run kubar contexts
swift run kubar namespaces
swift run kubar deployments -n <namespace>
swift run kubar pods -n <namespace> -d <deployment>
swift run kubar -c <context> -w nodes          # pick a context, refresh every 10s
```

Run `swift test` to test the core.
