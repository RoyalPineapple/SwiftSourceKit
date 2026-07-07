# SwiftSourceKit

SwiftSourceKit is a strict Swift 6 wrapper over the public `sourcekitd.h` transport surface.

It exposes raw SourceKit request/response transport as typed Swift values, then layers small typed request wrappers on top. The raw transport is the completion boundary: if public `sourcekitd.h` can represent a request and response shape, SwiftSourceKit should let Swift code send it and receive it without touching C.

```swift
let client = try SourceKitClient()

let raw = try await client.send(.request(.compilerVersion))

let version = try await client.compilerVersion()
```

## Surface

- `SourceKitClient.send(_:)` sends raw `SourceKitValue` requests and returns raw `SourceKitValue` responses.
- `SourceKitClient.send<R: SourceKitRequest>(_:)` sends typed request wrappers.
- `SourceKitValue` models every public response variant kind: null, dictionary, array, int64, string, uid, bool, double, and data.
- `SourceKitValue` supports Swift dictionary, array, string, integer, boolean, and floating-point literals for raw requests.
- Request encoding supports the public request constructors/setters exposed by `sourcekitd.h`: dictionary, array, string, int64, and uid.
- Request-side null, bool, double, and data fail before SourceKit is called because the public request API does not expose constructors/setters for them.

## Generated Shim

Swift cannot directly model every `sourcekitd_variant_t` C ABI shape. The tiny C shim in `Sources/CSourceKitDShim` is generated from a pinned `sourcekitd.h` slice.

`SourceKitUID` constants are generated from Swift's pinned `utils/gyb_sourcekit_support/UIDs.py` protocol source, covering keys, requests, and kinds.

```sh
swift Tools/generate-sourcekitd-shim.swift --self-test
swift Tools/generate-sourcekitd-shim.swift --verify \
  --sourcekitd-header Tests/Fixtures/sourcekitd/sourcekitd.h \
  --output Sources/CSourceKitDShim
swift Tools/generate-sourcekit-uid-constants.swift --self-test
swift Tools/generate-sourcekit-uid-constants.swift --verify
```

Pinned provenance is recorded in `Sources/CSourceKitDShim/sourcekitd-header-provenance.txt` and `Sources/SwiftSourceKit/sourcekit-uid-provenance.txt`.

To intentionally move the wrapper to a newer upstream Swift SourceKit pin:

```sh
swift Tools/update-sourcekit-fixtures.swift <swift-commit-sha>
```

## SourceKitD Probe

CI runs `SourceKitDProbe` outside the test process so sourcekitd ABI crashes fail in an isolated executable instead of taking down the Swift test runner.

```sh
swift run SourceKitDProbe
swift run SourceKitDProbe --library-path /tmp/not-sourcekitd
```

## Tests

```sh
swift test
swift test -c release
```

Some smoke tests query a live local `sourcekitd.framework` when it is available.
