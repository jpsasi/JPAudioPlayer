# JPAudioPlayer

A Swift package for playing audio streams on iOS and macOS. JPAudioPlayer provides two distinct player architectures optimized for different use cases.

## Player Architectures

### 1. AVPlayer-Based Player (iOS-only, Production-Ready)
**File:** `JPAudioPlayer.swift`

A high-level player built on AVFoundation's AVPlayer, providing seamless integration with iOS system features.

**Features:**
- Audio streaming from URLs
- Lock screen integration (Now Playing)
- Control Center integration
- Remote command support (play, pause, next, previous)
- Artwork and metadata display
- Automatic session management
- Audio interruption handling
- Route change handling (headphones, AirPlay)

**Best for:** Production iOS apps requiring full system integration.

### 2. AudioToolbox-Based Player (iOS + macOS, Experimental)
**Files:** `JPAudioEnginePlayer.swift`, `JPStreamingAudioPlayer.swift`

A low-level player using AudioToolbox for streaming and AVAudioEngine for effects processing.

**Features:**
- 10-band parametric equalizer (32Hz - 16kHz)
- Cross-platform support (iOS 17+ and macOS)
- Low-level audio control with AudioConverter
- ICY metadata parsing (streaming station info)
- Real-time audio effects
- Direct PCM buffer management

**Best for:** Apps requiring advanced audio processing, EQ effects, or cross-platform support.

## Requirements

- **AVPlayer-based:** iOS 16.0+
- **AudioToolbox-based:** iOS 17.0+ or macOS 10.15+
- Swift 5.9+

## Installation

### Swift Package Manager

Add JPAudioPlayer to your Xcode project:

1. In Xcode, navigate to **File > Add Packages...**
2. Enter the repository URL
3. Choose your desired dependency rule
4. Click **Add Package**

Alternatively, add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jpsasi/JPAudioPlayer.git", from: "1.0.0")
]
```

## Usage

### AVPlayer-Based Player (iOS)

Simple, production-ready streaming with system integration:

```swift
import SwiftUI
import JPAudioPlayer

struct ContentView: View {
    private var player: JPAudioPlayer?
    private let thumbnailImage = UIImage(named: "placeholder")!

    init() {
        let playerItem = JPAudioPlayerItem(
            playerItemType: .stream(
                title: "My Radio Station",
                url: URL(string: "https://stream.example.com/radio")!,
                thumbnailImageUrl: URL(string: "https://example.com/artwork.jpg")
            )
        )

        self.player = JPAudioPlayer(
            playerItem: playerItem,
            thumbnailImage: thumbnailImage
        )

        // Optional: Handle next/previous track commands
        self.player?.playerDelegate = self
    }

    var body: some View {
        VStack(spacing: 20) {
            Button("Play") { player?.play() }
            Button("Pause") { player?.pause() }
            Button("Stop") { player?.stop() }
        }
    }
}

extension ContentView: JPAudioPlayerDelegate {
    func playNextStation() {
        // Load and play next station
    }

    func playPreviousStation() {
        // Load and play previous station
    }
}
```

### AudioToolbox-Based Player with EQ (iOS/macOS)

Advanced streaming with 10-band equalizer:

```swift
import JPAudioPlayer

class AudioController {
    private var player: JPAudioEnginePlayer?

    func setupPlayer() {
        let playerItem = JPAudioPlayerItem(
            playerItemType: .stream(
                title: "Radio Station",
                url: URL(string: "https://stream.example.com/radio")!,
                thumbnailImageUrl: nil
            )
        )

        player = JPAudioEnginePlayer(playerItem: playerItem)

        // Handle metadata updates (song titles, artist info)
        player?.metadataHandler = { metadata in
            print("Now playing: \(metadata)")
        }
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        player?.stop()
    }

    // Configure equalizer presets
    func applyBassBoost() {
        let eq = player?.equalizer
        eq?.globalGain = 0
        eq?.bypass = false

        let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let gains: [Float] = [12, 10, 6, 2, 0, 0, 0, 0, 0, 0]

        eq?.bands.enumerated().forEach { index, band in
            band.frequency = frequencies[index]
            band.gain = gains[index]
            band.bandwidth = 1.0
            band.filterType = .parametric
            band.bypass = false
        }
    }

    func applyTrebleBoost() {
        let eq = player?.equalizer
        let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let gains: [Float] = [0, 0, 0, 0, 0, 0, 4, 6, 10, 12]

        eq?.bands.enumerated().forEach { index, band in
            band.frequency = frequencies[index]
            band.gain = gains[index]
        }
    }

    func resetEQ() {
        player?.equalizer.bands.forEach { $0.gain = 0 }
    }

    func toggleEQ() {
        player?.equalizer.bypass.toggle()
    }
}
```

### EQ Configuration

The 10-band equalizer provides full parametric control:

```swift
let eq = player.equalizer

// Configure individual band
let band = eq.bands[0]
band.frequency = 60      // Center frequency (Hz)
band.gain = 6            // Boost/cut in dB (-96 to +24)
band.bandwidth = 1.0     // Bandwidth in octaves
band.filterType = .parametric
band.bypass = false

// Global controls
eq.globalGain = 0        // Overall volume adjustment
eq.bypass = false        // Enable/disable entire EQ
```

**Standard EQ Bands:**
- Band 0: 32 Hz (Sub-bass)
- Band 1: 64 Hz (Bass)
- Band 2: 125 Hz (Bass)
- Band 3: 250 Hz (Low-mids)
- Band 4: 500 Hz (Mids)
- Band 5: 1 kHz (Mids)
- Band 6: 2 kHz (High-mids)
- Band 7: 4 kHz (Presence)
- Band 8: 8 kHz (Brilliance)
- Band 9: 16 kHz (Air)

## API Reference

### JPAudioPlayer (AVPlayer-based)

**Properties:**
- `playerStatus: JPAudioPlayerStatus` - Current playback status
- `playerDelegate: JPAudioPlayerDelegate?` - Delegate for remote commands

**Methods:**
- `play()` - Start playback
- `pause()` - Pause playback
- `stop()` - Stop and release resources
- `resume()` - Resume from pause

### JPAudioEnginePlayer (AudioToolbox-based)

**Properties:**
- `playerStatus: JPAudioPlayerStatus` - Current playback status
- `equalizer: AVAudioUnitEQ` - 10-band equalizer (read-only)
- `metadataHandler: ((String) -> Void)?` - ICY metadata callback

**Methods:**
- `play()` - Start streaming and playback
- `pause()` - Pause playback
- `stop()` - Stop streaming and release resources

### JPAudioPlayerItem

**Initialization:**
```swift
JPAudioPlayerItem(
    playerItemType: .stream(
        title: String,           // Display title
        url: URL,                // Stream URL
        thumbnailImageUrl: URL?  // Optional artwork URL
    )
)
```

### JPAudioPlayerStatus

Enum representing player state:
- `.notInitialized` - Initial state
- `.buffering` - Loading audio data
- `.playing` - Currently playing
- `.paused` - Playback paused
- `.stopped` - Playback stopped
- `.failed` - Error occurred

## Technical Details

### AudioToolbox Implementation

The AudioToolbox-based player uses a sophisticated streaming pipeline:

1. **URLSession** fetches MP3/AAC stream with ICY metadata support
2. **AudioFileStream** parses compressed audio packets
3. **AudioConverter** decodes to PCM (44.1kHz, Float32, non-interleaved)
4. **Buffer accumulation** combines small chunks into ~1 second buffers
5. **AVAudioEngine** pipeline: Player → EQ → Mixer → Hardware Output
6. **Sample rate conversion** handles hardware rate mismatches (44.1→48kHz)

**Key optimizations:**
- Async buffer scheduling (non-blocking decoder)
- Silent buffer detection (skips AudioConverter priming)
- Partial frame processing (handles status=-1 gracefully)
- Proper accumulation threshold (prevents timing drift)

## Platform Differences

**iOS:**
- Full AVAudioSession support (interruptions, route changes)
- Media Player framework (lock screen, Control Center)
- Background audio capability required in Info.plist

**macOS:**
- No AVAudioSession (uses stub implementation)
- Conditional compilation guards for macOS 10.15+ APIs
- Primarily used for testing during development

## Demo Application

The package includes a command-line demo for macOS:

```bash
swift run JPAudioEngineDemo
```

**Commands:**
- `play` - Start streaming
- `pause` - Pause playback
- `stop` - Stop playback
- `bass` - Apply bass boost EQ
- `treble` - Apply treble boost EQ
- `vocal` - Apply vocal enhancement EQ
- `flat` - Reset EQ to flat (0dB)
- `bypass` - Toggle EQ on/off
- `quit` - Exit application

## Troubleshooting

### Buffer Underruns
If you see "Buffer underrun" warnings:
- Network connection may be unstable
- Stream bitrate may be too high
- Increase `minBuffersBeforePlay` in `JPAudioEnginePipeline`

### Fast/Slow Playback
If audio plays at wrong speed:
- Check sample rate conversion is working (44.1→48kHz)
- Verify buffer accumulation threshold settings
- Ensure hardware output format is detected correctly

### No Audio Output
If playback starts but no sound:
- Verify audio session is configured (iOS)
- Check system volume and mute settings
- Ensure EQ bypass is correct state
- Confirm AVAudioEngine is started

## Build & Test

```bash
# Build the library
swift build

# Run tests
swift test

# Build for release (performance testing)
swift build -c release

# Run demo app (macOS)
swift run JPAudioEngineDemo
```

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.

## Contributing

Check `CLAUDE.md` for repository guidelines, coding style, and testing expectations before opening a pull request.

## Recent Changes

### v1.1.0 - Audio Streaming Fixes
- Fixed broken audio playback in AudioToolbox-based player
- Implemented buffer accumulation pattern (matching reference implementation)
- Skip silent buffers from AudioConverter priming
- Process partial frames from AudioConverter (status=-1)
- Non-blocking async buffer scheduling
- Proper threshold checks to prevent timing drift
- Reduced decode chunk size (8192→4096 frames)

Result: Smooth, continuous audio playback without gaps or speed issues.
