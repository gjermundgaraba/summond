# Summond

macOS app plus LaunchAgent that intercepts global key events and opens, focuses,
or moves application windows based on shortcuts configured in the preferences
UI. See [ARCHITECTURE.md](ARCHITECTURE.md) for components, data flow,
concurrency, failure semantics, bundle layout, and signing/notarization notes.

## Commands

`make help` lists every build, test, lint, and packaging target. The CI gate is
`make lint`, `make core-test`, and `make app-test`.
