# FreeDisplay (app)

The macOS SwiftUI/AppKit menu-bar app composes the shared Packages logic with the real
platform providers. Its internal target/scheme remains `OpenDisplay`; the built product is
`FreeDisplay.app`. Public-only builds use the `OpenDisplay-PublicAPIOnly` scheme.

Generate the local project with `xcodegen generate --spec project.local.yml`. See the
[FreeDisplay help](../../Docs/FreeDisplay-Help.md) for actual controls, capability boundaries,
verification and undo. Builds/tests do not certify hardware or distribution signatures.
