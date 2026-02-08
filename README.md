# JPAudioPlayer

A Swift package for playing audio streams on iOS. `JPAudioPlayer` provides a simple interface for handling audio playback, session management, and integration with system media controls.

## Features

- **Audio Streaming:** Play audio from a URL.
- **Session Management:** Automatically handles audio session configuration, interruptions, and route changes.
- **Now Playing Integration:** Displays track information (title, metadata, artwork) on the lock screen and in the Control Center.
- **Remote Controls:** Responds to playback commands from the Control Center, headphones, and other remote accessories (play, pause, next, previous).
- **Metadata:** Fetches and displays timed metadata from the audio stream.
- **Customizable:** Use the `JPAudioPlayerDelegate` to control playback flow (e.g., playing the next or previous station).

## Requirements

- iOS 16.0+
- Swift 5.0+

## Installation

You can add `JPAudioPlayer` to your Xcode project as a Swift Package.

1. In Xcode, open your project and navigate to **File > Add Packages...**
2. In the "Search or Enter Package URL" field, enter the repository URL for this package.
3. Choose your desired dependency rule and click **Add Package**.

## Usage

Here's a basic example of how to use `JPAudioPlayer`:

```swift
import SwiftUI
import JPAudioPlayer

struct ContentView: View {
    private var player: JPAudioPlayer?
    private let thumbnailImage = UIImage(named: "placeholder")! // A placeholder image

    init() {
        // Define the audio item to play
        let playerItem = JPAudioPlayerItem(
            playerItemType: .stream(
                title: "My Awesome Radio",
                url: URL(string: "https://your-stream-url.com/stream")!,
                thumbnailImageUrl: URL(string: "https://your-artwork-url.com/image.jpg")
            )
        )

        // Initialize the player
        self.player = JPAudioPlayer(playerItem: playerItem, thumbnailImage: thumbnailImage)
        
        // Set the delegate to handle next/previous track commands
        // self.player?.playerDelegate = self
    }

    var body: some View {
        VStack {
            Button("Play") {
                player?.play()
            }
            Button("Pause") {
                player?.pause()
            }
            Button("Stop") {
                player?.stop()
            }
        }
    }
}

// Implement the delegate if you need to handle next/previous actions
// extension ContentView: JPAudioPlayerDelegate {
//     func playNextStation() {
//         // Your logic to play the next item
//     }
//
//     func playPreviousStation() {
//         // Your logic to play the previous item
//     }
// }
```

## API

### `JPAudioPlayer`
The main class for controlling audio playback.

- `var playerStatus: JPAudioPlayerStatus`: The current status of the player (`.playing`, `.paused`, `.stopped`, etc.).
- `func play()`: Starts playback.
- `func pause()`: Pauses playback.
- `func stop()`: Stops playback and releases the current player item.
- `func resume()`: Resumes playback if paused.

### `JPAudioPlayerItem`
Represents the audio item to be played.

- `init(playerItemType: JPAudioPlayerItemType)`: Creates a new item.
- `JPAudioPlayerItemType`: An enum that defines the type of audio item. Currently supports `.stream(title: String, url: URL, thumbnailImageUrl: URL?)`.

### `JPAudioPlayerDelegate`
A protocol to respond to remote control events for next and previous tracks.

- `func playNextStation()`
- `func playPreviousStation()`

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.

## Contributing

Check `AGENTS.md` for repository guidelines, coding style, and testing expectations before opening a pull request.
