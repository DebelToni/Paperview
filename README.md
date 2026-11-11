# Paperview

An iPadOS/iOS client for [Space](https://space.toni.foo), with a native PDFKit reader and PencilKit annotation tools. The dashboard and collaborative whiteboards load the live Space website in WKWebView.

## Use with Space

The app automatically connects to **https://space.toni.foo**. No backend secrets, API keys, server configuration, or Space source checkout are needed. Sign up or sign in through the app using your own account. Space access requires the server owner's approval; private spaces require a separate invitation or membership.

This repository contains only the Apple client. Space's backend and web app are maintained separately and are not covered by this repository's license. The hosted service has its own access controls and may change independently of this client.

## Build and install

Requirements: a Mac with Xcode and its iOS SDK, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and an iPad or iPhone running iOS/iPadOS 18 or later. Verified with Xcode 27.0 and Swift 5 language mode.

```sh
git clone https://github.com/DebelToni/Paperview.git
cd Paperview
xcodegen generate
open Paperview.xcodeproj
```

In Xcode:

1. Add your own Apple account in Settings → Accounts.
2. Select the Paperview app target. Under Signing & Capabilities, select your own development team and use a unique bundle identifier, such as `com.yourname.Paperview`.
3. Connect and select your device, enable Developer Mode on it if prompted, then build and run. Trust your developer identity in the device's settings if required.

The project deliberately does not specify a development team. Your Apple signing credentials stay in Xcode; never commit certificates, provisioning profiles, passwords, or generated build products. Keep the same team and bundle identifier for future updates so that the app retains its local data.

Free Apple-account provisioning normally expires after seven days. Re-sign and update your installation with Xcode before expiry; each person's provisioning schedule is independent. Do not uninstall to renew: uninstalling removes pending local annotations. Paid developer-account provisioning has different limits.

For an unsigned simulator build:

```sh
xcodegen generate
xcodebuild -project Paperview.xcodeproj -scheme Paperview \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build-for-testing
```

## Tests

Local unit tests do not need a Space account or the private backend. After the simulator build above, configure the test host to use an isolated loopback origin so it cannot load production:

```sh
python3 scripts/configure-unit-tests.py build/DerivedData/Build/Products
xcodebuild test-without-building \
  -xctestrun build/DerivedData/Build/Products/Paperview_unit.xctestrun \
  -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)' \
  -only-testing:PaperviewTests -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
```

Choose an available iPad simulator from `xcrun simctl list devices available`. Tests requiring disposable backend/account fixtures skip when those fixtures are absent. End-to-end integration and UI tests are maintained with the private Space test environment; do not supply production credentials as test fixtures.

## Reader and saving

- Continuous PDF scrolling and zoom, native Pencil ink, highlighter, text, erasing, undo/redo, shared annotations and annotated PDF export.
- Shared annotation edits synchronize with Space. Independent edits merge; conflicting edits require an explicit choice.
- Completed native edits are journaled locally before upload. Pending edits are scoped to the authorized account and paper.
- Opening a paper requires a connection and authorization. Original PDFs are not persistently cached for offline reading. An already-open paper can retain completed handwriting during a connection failure.
- Questions marked in pink are saved annotations, not AI requests.

## License

[MIT](LICENSE), copyright Anton Ivanov. Apple frameworks and development tools remain subject to their respective terms.
