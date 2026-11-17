# Native board

The dashboard and board use UIKit and PencilKit. The linked Rust Space engine remains the portable authority for document operations and geometry, shared with Space; the private engine source is not included or MIT-licensed here. Website deployments do not update the native board: changes require rebuilding and updating the app. Authentication and guest bootstrap use WebKit; HTML board content runs in a sandboxed WebKit view.

## Engine build input

The app requires a compatible `Vendor/SpaceEngine.xcframework`, supplied by the owner under separate terms or generated from an authorized private Space checkout. No public engine availability or redistribution rights are implied. The backend and web source are not needed by public clients.

To generate the framework on a Mac from an authorized checkout, install Rust and the `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and `x86_64-apple-ios` targets, then run:

```sh
scripts/build-native-engine.sh /path/to/authorized-space-checkout
```

The script builds locked release static libraries and packages the device slice and universal arm64/x86_64 simulator slice with Xcode. It fails if the output framework already exists; move or remove the previous generated framework before regenerating. An owner-provided framework must be compatible with the client and intended build destinations. Build 15 requires the engine's `serde_json/float_roundtrip` fix: `BoardEngineTests.testNativeDispatchPreservesCoordinateBitsAcrossRepeatedPollReplacement` detects older binaries that change coordinates during transport and cause false conflicts.

## Text and ink

Native TextKit and CoreGraphics render text and math using SwiftMath 1.7.3 pinned to `fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7`. Bundled marked, highlight.js and Lezer parsers run offline in JavaScriptCore, not WebKit or a network service. Unsupported math remains visible and its source is preserved. Third-party notices are bundled in `Paperview/Board/Resources/TextTools-LICENSES.txt`; SwiftMath packages its `mathFonts.bundle` with its own license and GUST font notice.

With Pen selected, Pencil draws and one finger pans; two fingers pan/pinch in other tools. Select permits finger object editing, while read-only viewers can navigate and inspect without mutating content. Papers opens directly from the navigation bar. Selected papers expose Open PDF; object-specific actions live in Selection and the long-press menu. Finger/pointer double-tap opens cards, never Pencil contact.

Completed board edits and native PencilKit archives are journaled locally before upload, scoped to identity and space. The backward-compatible journal includes an optional pending-submission receipt so a lost upload response cannot discard edits made during the request or silently repeat an uncertain write. Shared conflicts require explicit review, including stale contact intents; raw ink recovery can be exported. A contact that cannot be fully converted retains its entire native drawing instead of saving a partial stroke set. Native archives retain complete PencilKit data, while portable ink is constant-width and sampled to at most 20,000 points.

Original PDFs are not persistently cached. Board media uses ephemeral protected files with a 64 MiB source limit and a 24-million-pixel application limit. These limits do not bound AVPlayer’s internal decoder memory.

## Testing and installation

The [README](README.md#tests) describes isolated loopback unit-test configuration; use synthetic fixtures, never production accounts or content. A simulator build is separate from physical installation, which requires Apple signing. Preserve the same signing team and bundle identity when updating an existing installation, and never uninstall while edits are pending.
