# SwiftSourceKit

SwiftSourceKit is a strict Swift 6 wrapper over the public `sourcekitd.h` transport surface.

It exposes raw SourceKit request/response transport as typed Swift values, then layers small typed request wrappers on top. The raw transport is the completion boundary: if public `sourcekitd.h` can represent a request and response shape, SwiftSourceKit should let Swift code send it and receive it without touching C.

```swift
let client = try SourceKitClient()

let raw = try await client.send(.dictionary([
    .Key.request: .uid(.Request.compilerVersion),
]))

let version = try await client.compilerVersion()
```

## Surface

- `SourceKitClient.send(_:)` sends raw `SourceKitValue` requests and returns raw `SourceKitValue` responses.
- `SourceKitClient.send<R: SourceKitRequest>(_:)` sends typed request wrappers.
- `SourceKitValue` models every public response variant kind: null, dictionary, array, int64, string, uid, bool, double, and data.
- Request encoding supports the public request constructors/setters exposed by `sourcekitd.h`: dictionary, array, string, int64, and uid.
- Request-side null, bool, double, and data fail before SourceKit is called because the public request API does not expose constructors/setters for them.

## Generated Shim

Swift cannot directly model every `sourcekitd_variant_t` C ABI shape. The tiny C shim in `Sources/CSourceKitDShim` is generated from a pinned `sourcekitd.h` slice.

```sh
swift Tools/generate-sourcekitd-shim.swift --self-test
swift Tools/generate-sourcekitd-shim.swift --verify \
  --sourcekitd-header Tests/Fixtures/sourcekitd/sourcekitd.h \
  --output Sources/CSourceKitDShim
```

The pinned header provenance is recorded in `Sources/CSourceKitDShim/sourcekitd-header-provenance.txt`.

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

Most unsafe-boundary coverage uses a fake sourcekitd dylib built from `Tests/Fixtures/FakeSourceKitD`. Some smoke tests query a live local `sourcekitd.framework` when it is available.
