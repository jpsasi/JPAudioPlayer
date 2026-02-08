import Foundation
import JPAudioPlayer

final class DemoController {
  private let player: JPAudioEnginePlayer
  private let commandQueue = DispatchQueue(label: "jp.demo.commands")
  private let streamURL = URL(string: "https://a9radio1-a9media.radioca.st/stream")!
  
  init() {
    let item = JPAudioPlayerItem(playerItemType: .stream(
      title: "A9 Radio",
      url: streamURL,
      thumbnailImageUrl: nil
    ))
    player = JPAudioEnginePlayer(playerItem: item)
    player.metadataHandler = { metadata in
      print("Metadata: \(metadata)")
    }
  }
  
  func start() {
    print("\n=== JPAudioEngine Demo ===")
    print("Commands:")
    print("  play, pause, stop, quit")
    print("  bass    - Boost bass frequencies")
    print("  treble  - Boost treble frequencies")
    print("  vocal   - Boost vocal frequencies")
    print("  flat    - Reset EQ to flat")
    print("  bypass  - Toggle EQ bypass")
    readInput()
    RunLoop.main.run()
  }
  
  private func readInput() {
    commandQueue.async { [weak self] in
      while let line = readLine(strippingNewline: true) {
        self?.handle(command: line.lowercased())
      }
    }
  }
  
  private func handle(command: String) {
    switch command {
      case "play":
        player.play()
        print("Playback started")
      case "pause":
        player.pause()
        print("Playback paused")
      case "stop":
        player.stop()
        print("Playback stopped")
      case "quit":
        player.stop()
        print("Bye")
        CFRunLoopStop(CFRunLoopGetMain())

      // EQ Commands
      case "bass":
        configureBassBoost()
        print("✓ Bass boost applied (+12dB at 60Hz, +8dB at 170Hz)")
      case "treble":
        configureTrebleBoost()
        print("✓ Treble boost applied (+10dB at 10kHz, +8dB at 6kHz)")
      case "vocal":
        configureVocalBoost()
        print("✓ Vocal boost applied (+6dB at 1kHz-3kHz)")
      case "flat":
        configureFlatEQ()
        print("✓ EQ reset to flat (0dB all bands)")
      case "bypass":
        toggleEQBypass()

      default:
        print("Unknown command: \(command)")
    }
  }

  // EQ Configuration Methods
  private func configureBassBoost() {
    let eq = player.equalizer
    eq.globalGain = 0
    eq.bypass = false

    // Configure 10-band EQ for bass boost
    // Bands: 32Hz, 64Hz, 125Hz, 250Hz, 500Hz, 1kHz, 2kHz, 4kHz, 8kHz, 16kHz
    let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    let gains: [Float] = [12, 10, 6, 2, 0, 0, 0, 0, 0, 0]  // Heavy bass boost

    for (index, band) in eq.bands.enumerated() {
      band.frequency = frequencies[index]
      band.gain = gains[index]
      band.bandwidth = 1.0
      band.filterType = .parametric
      band.bypass = false
    }
  }

  private func configureTrebleBoost() {
    let eq = player.equalizer
    eq.globalGain = 0
    eq.bypass = false

    let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    let gains: [Float] = [0, 0, 0, 0, 0, 0, 4, 6, 10, 12]  // Heavy treble boost

    for (index, band) in eq.bands.enumerated() {
      band.frequency = frequencies[index]
      band.gain = gains[index]
      band.bandwidth = 1.0
      band.filterType = .parametric
      band.bypass = false
    }
  }

  private func configureVocalBoost() {
    let eq = player.equalizer
    eq.globalGain = 0
    eq.bypass = false

    let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    let gains: [Float] = [0, 0, -2, 0, 2, 6, 6, 4, 0, 0]  // Boost vocal range

    for (index, band) in eq.bands.enumerated() {
      band.frequency = frequencies[index]
      band.gain = gains[index]
      band.bandwidth = 1.0
      band.filterType = .parametric
      band.bypass = false
    }
  }

  private func configureFlatEQ() {
    let eq = player.equalizer
    eq.globalGain = 0
    eq.bypass = false

    for band in eq.bands {
      band.gain = 0  // Reset all bands to 0dB
      band.bypass = false
    }
  }

  private func toggleEQBypass() {
    let eq = player.equalizer
    eq.bypass.toggle()
    print(eq.bypass ? "✓ EQ bypassed (disabled)" : "✓ EQ active (enabled)")
  }
}

let controller = DemoController()
controller.start()
