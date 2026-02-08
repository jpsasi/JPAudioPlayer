# Repository Guidelines

## Project Structure & Module Organization
- `JPAudioPlayer/Package.swift` defines the Swift Package target and platforms.
- Source code lives in `JPAudioPlayer/Sources/JPAudioPlayer/` (e.g., `JPAudioPlayer.swift`, `JPStreamingAudioPlayer.swift`).
- Tests live in `JPAudioPlayer/Tests/JPAudioPlayerTests/`.
- There are no dedicated asset bundles in this package; any images/audio are provided by apps that consume the library.

## Build, Test, and Development Commands
Run these from the package root (`JPAudioPlayer/`).
- `swift build` — builds the Swift package.
- `swift test` — runs the XCTest suite.
- Open `JPAudioPlayer/Package.swift` in Xcode to build/run via the IDE.

## Coding Style & Naming Conventions
- Swift conventions: PascalCase for types, camelCase for properties/functions.
- Prefer `let` for constants and avoid force unwrapping (`!`) unless absolutely necessary.
- Use async/await when possible; avoid Combine unless required by APIs.
- Indentation: 4 spaces. No formatter or linter is configured in this repo.

## Testing Guidelines
- Framework: XCTest.
- Test files live in `JPAudioPlayer/Tests/JPAudioPlayerTests/`.
- Name tests with the `test...` prefix (e.g., `testPlaybackStarts()`), and keep tests deterministic.
- Some example tests are currently stubbed/commented; add new tests alongside related code changes.

## Commit & Pull Request Guidelines
- Commit messages in history are short, sentence-style (e.g., "Thumbnail image is made optional") with occasional Conventional Commit prefixes (e.g., `feat:`). Either style is acceptable; keep it concise and descriptive.
- PRs should include: a clear description, affected files or modules, and any behavior changes. Add screenshots/logs only if UI or media playback behavior changes.

## Configuration & Integration Notes
- This is a library package targeting iOS (see `Package.swift`).
- Streaming URLs and artwork are provided by the host app; do not hardcode production endpoints in library code.
