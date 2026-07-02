# SwiftSourceKit Completion Contract

SwiftSourceKit is complete when public Swift code can use SourceKit through strict Swift 6 types without touching `dlopen`, `dlsym`, C function pointers, unsafe pointers, `sourcekitd_variant_t`, or response lifetimes.

The complete public surface is:

```swift
public actor SourceKitClient {
    public func send(_ request: SourceKitValue) async throws -> SourceKitValue
    public func send<Request: SourceKitRequest>(_ request: Request) async throws -> Request.Response
}
```

Typed requests are convenience. Raw `SourceKitValue` transport is the full wrapper boundary.

`SourceKitValue` represents every public `sourcekitd_variant_type_t` response kind:

- null
- dictionary
- array
- int64
- string
- uid
- bool
- double
- data

Request encoding intentionally supports only the public request shapes that `sourcekitd.h` can construct:

- dictionary
- array
- string
- int64
- uid

Null, bool, double, and data are response values, but the public request API does not expose constructors or setters for them. SwiftSourceKit rejects those request values before calling SourceKit.
