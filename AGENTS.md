# Paperview

Standalone Apple client for https://space.toni.foo. See README.md for build, personal signing and isolated unit-test commands. The app builds without Space's backend or web source.

- Preserve exact-origin navigation, script-bridge checks, HttpOnly cookie isolation, membership/guest authorization and explicit annotation conflicts. The accounts origin permits navigation, not Space native API privileges.
- Native annotations round-trip through Space's portable schema. Journal completed edits before upload; preserve original merge baselines, pending edits and native PencilKit archives.
- Production uses the fixed public Space origin. Test-origin overrides remain DEBUG-only and loopback-only. Never use production accounts or content as test fixtures.
- Do not commit signing identities, provisioning profiles, credentials, app data, generated Xcode projects or build products. Test in an isolated simulator; physical installation and data migration require separate authorization.
