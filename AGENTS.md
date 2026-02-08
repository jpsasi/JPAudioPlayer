# Repository Guidelines

## Project Structure & Module Organization
The Swift package is defined in `Package.swift` (Swift tools 5.10, iOS 17 target) and exposes a single library target, `JPAudioPlayer`. Core playback code lives in `Sources/JPAudioPlayer`, with responsibilities split across `JPAudioPlayer.swift` (public API and remote controls), `JPAudioSessionController.swift` (session configuration), `JPStreamingAudioPlayer.swift` (stream wiring), and `JPAudioPlayerItem.swift` (item metadata). XCTest suites reside in `Tests/JPAudioPlayerTests` and should mirror the structure of Source files to keep behavior-specific tests easy to find.

## Build, Test, and Development Commands
- `swift package resolve` – refresh dependency pins before a new Xcode version or CI run.
- `swift build` – compile the library; pass `-c release` when profiling audio performance.
- `swift test` – execute the XCTest targets; add `--enable-code-coverage` only if CI thresholds require it.
Run the commands from the repository root or through Xcode’s “Product” menu, which triggers the same SwiftPM actions.

## Coding Style & Naming Conventions
Swift files use two-space indentation, `PascalCase` for types/protocols, and `camelCase` for methods, vars, and enum cases (see `JPAudioPlayerStatus`). Prefer `final` or `struct` when inheritance is unnecessary. Keep public APIs annotated with access modifiers and doc comments, especially for properties surfaced to client apps.

## Testing Guidelines
Tests are built with XCTest. Name test cases after the class under test (`JPAudioPlayerTests`) and individual tests using the `test_{Action}_{Expectation}` pattern. Use dependency injection to substitute `AVPlayer` or session delegates, and assert state transitions on `JPAudioPlayerStatus`. Maintain coverage for remote command handling, metadata fetching, and error paths, and run `swift test` before every push.

## Commit & Pull Request Guidelines
History mixes conventional prefixes (`feat:`) with imperative summaries (“initial code…”). Standardize on present-tense messages such as `feat: wire metadata observers` or `fix: release AVPlayer observers on stop`. Each pull request should include the goal, linked issues, validation notes (`swift test`, device run), and screenshots or Console logs when Now Playing or remote command behavior changes. Keep PRs focused on a single feature or fix.

## Security & Configuration Tips
Audio streaming touches entitlements and ATS rules. Document required `Info.plist` updates (e.g., `NSAppTransportSecurity` exceptions, background audio modes) in the PR. When handling URLs inside `JPAudioPlayerItem`, validate schemes and prefer HTTPS. Clear metadata observers and sessions when stopping playback to avoid leaking `MPNowPlayingSession` references in client apps.
