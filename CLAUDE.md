# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Resolve dependencies
swift package resolve

# Build the library
swift build                    # Debug build
swift build -c release         # Release build (for performance profiling)

# Run tests
swift test                     # Run all tests
swift test --enable-code-coverage  # With coverage

# Run the demo app (macOS testing)
swift run JPAudioEngineDemo
```

Run commands from repository root. Xcode's Product menu triggers equivalent SwiftPM actions.

## Architecture Overview

JPAudioPlayer is a Swift Package supporting iOS 17+ with two distinct player architectures:

### 1. AVPlayer-based Player (iOS-only, stable)
**Location:** `JPAudioPlayer.swift`
- Uses `AVPlayer` and `AVPlayerItem` for streaming
- Integrates with iOS `MPNowPlayingSession` and `MPRemoteCommandCenter`
- Handles lock screen controls, metadata display, and artwork
- Session management via `JPAudioSessionController`
- **Status:** Production-ready, documented in README.md

### 2. AudioToolbox-based Player (iOS + macOS, experimental)
**Key files:**
- `JPStreamingAudioPlayer.swift` - Low-level audio streaming via `AudioFileStream` and `AudioConverter`
- `JPAudioEnginePlayer.swift` - High-level API with AVAudioEngine pipeline and EQ
- `JPAudioEngineDemo/main.swift` - Command-line test harness

**Architecture flow:**
1. **URLSession** fetches streaming data with ICY metadata support
2. **AudioFileStreamParseBytes** parses MP3/AAC packets
3. **AudioConverter** decodes compressed audio to PCM buffers
4. **AVAudioEngine** pipeline applies EQ effects and plays to speakers

**Critical implementation details:**
- Uses C-style callbacks (`audioPropertyListenerCallback`, `audioPacketsListener`, `myAudioConverterComplexInputDataProc`)
- Manages `Unmanaged<T>` pointers to pass Swift objects to C callbacks
- Packet descriptions must use **stable memory addresses** during AudioConverter callbacks
- macOS support requires `#if os(macOS)` guards (no AVAudioSession on macOS)

**Known issues:**
- AudioConverter pointer lifetime bugs (see error -50 in demo output)
- Packet description storage needs proper memory management

## Platform Differences

**iOS:**
- Full AVAudioSession support (interruptions, route changes)
- Media Player framework integration (lock screen controls)
- Requires background audio capability in Info.plist

**macOS:**
- No AVAudioSession (stubs in `JPAudioSessionController`)
- Conditional compilation with `#if os(macOS)` for macOS 10.15+ APIs
- Used for testing during development via `JPAudioEngineDemo`

## Code Style

- Two-space indentation
- `PascalCase` for types/protocols, `camelCase` for methods/variables
- Use `final` or `struct` when inheritance isn't needed
- Public APIs require access modifiers and doc comments
- Test pattern: `test_{Action}_{Expectation}`

## Audio Streaming Specifics

**ICY Metadata Protocol:**
- HTTP header `Icy-MetaData: 1` requests metadata
- Response includes `icy-metaint` header (byte interval)
- Data format: `[audio bytes] [1-byte length] [metadata] [audio bytes]...`
- Implemented in `JPStreamingAudioPlayer.urlSession(_:dataTask:didReceive:)`

**AudioConverter callback pattern:**
```swift
// AudioConverter pulls data via callback
AudioConverterFillComplexBuffer(converter, callbackProc, userData, ...)

// Callback must provide stable pointers until AudioConverter returns
// Store packet descriptions in instance properties, not local variables
```

**Format conversions:**
- Input: MP3/AAC compressed (VBR, variable packet sizes)
- Output: PCM 16-bit signed integer, 44.1kHz, stereo, interleaved
- `AudioStreamPacketDescription` describes compressed packet boundaries

## Testing Strategy

- XCTest suites mirror source structure
- Use dependency injection for `AVPlayer`, session delegates
- Assert state transitions on `JPAudioPlayerStatus`
- Cover: remote commands, metadata, error paths, interruptions
- Run `swift test` before every commit

## Commit Style

Use imperative present tense:
- `feat: add equalizer effects to streaming player`
- `fix: resolve AudioConverter packet description lifetime`
- `refactor: extract ICY metadata parsing`

PRs should include:
- Goal and linked issues
- Validation: `swift test`, device testing
- Console logs for Now Playing/remote command changes

## Security & Configuration

- Validate URL schemes in `JPAudioPlayerItem` (prefer HTTPS)
- Document required Info.plist keys: `NSAppTransportSecurity`, background audio modes
- Clear observers/sessions in `stop()` to prevent MPNowPlayingSession leaks
- Never commit streaming URLs with auth tokens
