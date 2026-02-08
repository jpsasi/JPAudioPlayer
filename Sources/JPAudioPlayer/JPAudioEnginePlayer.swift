import Foundation
import AVFoundation

public final class JPAudioEnginePlayer: NSObject {
  private let playerItem: JPAudioPlayerItem
  private let streamingPlayer: JPStreamingAudioPlayer
  private let pipeline: JPAudioEnginePipeline
  private let sessionController: JPAudioSessionController
  public private(set) var playerStatus: JPAudioPlayerStatus = .notInitialized
  public var metadataHandler: ((String) -> Void)?
  private var isSessionConfigured = false

  // Expose equalizer for testing/configuration
  public var equalizer: AVAudioUnitEQ {
    return pipeline.equalizerNode
  }
  
  public init(playerItem: JPAudioPlayerItem) {
    self.playerItem = playerItem
    self.streamingPlayer = JPStreamingAudioPlayer()
    self.pipeline = JPAudioEnginePipeline()
    self.sessionController = JPAudioSessionController()
    super.init()
    self.streamingPlayer.delegate = self
    self.sessionController.sessionDelegate = self
  }
  
  public func play() {
    guard let url = playerItem.playerItemType.streamURL else { return }
    if !isSessionConfigured {
      do {
        try sessionController.configure()
        isSessionConfigured = true
      } catch {
        print("Failed to configure audio session: \(error)")
      }
    }
    playerStatus = .buffering
    streamingPlayer.startStreaming(url: url)
  }
  
  public func pause() {
    pipeline.pause()
    playerStatus = .paused
  }
  
  public func stop() {
    streamingPlayer.stop()
    pipeline.stop()
    playerStatus = .stopped
  }
}

extension JPAudioEnginePlayer: JPStreamingAudioPlayerDelegate {
  public func streamingAudioPlayer(_ player: JPStreamingAudioPlayer,
                                   didDecode buffer: AVAudioPCMBuffer,
                                   format: AVAudioFormat) {
    pipeline.enqueue(buffer: buffer)
    playerStatus = .playing
  }
  
  public func streamingAudioPlayer(_ player: JPStreamingAudioPlayer,
                                   didReceiveMetadata metadata: String) {
    metadataHandler?(metadata)
  }
  
  public func streamingAudioPlayer(_ player: JPStreamingAudioPlayer,
                                   didStopWithError error: Error?) {
    pipeline.stop()
    playerStatus = error == nil ? .stopped : .failed
  }
}

extension JPAudioEnginePlayer: JPSessionControllerDelegate {
  public func sessionControllerDidBeginInterruption() {
    pause()
  }
  
  public func sessionControllerDidEndInterruption(canResume: Bool) {
    if canResume {
      play()
    }
  }
  
  public func sessionControllerRouteChangeOldDeviceNotAvailable() {
    pause()
  }
  
  public func sessionControllerRouteChangeNewDeviceAvailable() {
    play()
  }
}

final class JPAudioEnginePipeline {
  private let engine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private let eqNode = AVAudioUnitEQ(numberOfBands: 10)
  private var currentFormat: AVAudioFormat?
  private let queue = DispatchQueue(label: "jp.audio.engine.pipeline")
  var equalizerNode: AVAudioUnitEQ { eqNode }

  // Buffering state
  private var scheduledBufferCount: Int = 0
  private let minBuffersBeforePlay: Int = 5  // Wait for 5 buffers before starting
  private var hasStartedPlaying: Bool = false
  private var totalBuffersScheduled: Int = 0  // Total count of all buffers ever scheduled
  private var totalBuffersConsumed: Int = 0  // Total count of all buffers consumed

  init() {
    engine.attach(playerNode)
    engine.attach(eqNode)
    eqNode.bypass = false
    eqNode.bands.forEach { $0.bypass = false }
  }
  
  func enqueue(buffer: AVAudioPCMBuffer) {
    // MUST use sync to maintain buffer order (async causes overlapping audio!)
    queue.sync {
      do {
        try prepareEngineIfNeeded(format: buffer.format)

        // Schedule buffer with completion handler to track buffer count
        scheduledBufferCount += 1
        totalBuffersScheduled += 1
        let bufferNum = totalBuffersScheduled
        print("⏫ Scheduled buffer #\(bufferNum) - queue size: \(scheduledBufferCount)")

        // Use .dataPlayedBack to get callback when audio is ACTUALLY played, not just consumed
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] callbackType in
          self?.queue.async {
            guard let self = self else { return }
            self.scheduledBufferCount -= 1
            self.totalBuffersConsumed += 1
            print("⏬ Played buffer #\(bufferNum) - queue size: \(self.scheduledBufferCount)")

            // If we're running low on buffers, log it
            if self.hasStartedPlaying && self.scheduledBufferCount < 2 {
              print("⚠️ Warning: Buffer underrun, only \(self.scheduledBufferCount) buffers remaining")
            }
          }
        }

        // Start playback only after we have enough buffers queued
        if !hasStartedPlaying && scheduledBufferCount >= minBuffersBeforePlay {
          print("Buffered \(scheduledBufferCount) chunks, starting playback...")
          hasStartedPlaying = true
          playerNode.play()

          // Verify the actual playback format
          print("🎵 Player node format: \(playerNode.outputFormat(forBus: 0).sampleRate) Hz")
          print("🎵 Buffer format: \(buffer.format.sampleRate) Hz")
          print("🎵 Engine output: \(engine.outputNode.outputFormat(forBus: 0).sampleRate) Hz")
        }
      } catch {
        print("Failed to enqueue buffer: \(error)")
      }
    }
  }
  
  func pause() {
    queue.sync {
      playerNode.pause()
    }
  }
  
  func stop() {
    queue.sync {
      playerNode.stop()
      if engine.isRunning {
        engine.stop()
      }
      engine.reset()
      currentFormat = nil
      // Reset buffering state
      scheduledBufferCount = 0
      hasStartedPlaying = false
      totalBuffersScheduled = 0
      totalBuffersConsumed = 0
    }
  }
  
  private func prepareEngineIfNeeded(format: AVAudioFormat) throws {
    if currentFormat == nil ||
        currentFormat?.channelCount != format.channelCount ||
        currentFormat?.sampleRate != format.sampleRate {
      try reconnectGraph(format: format)
    } else if !engine.isRunning {
      try engine.start()
    }
  }
  
  private func reconnectGraph(format: AVAudioFormat) throws {
    if engine.isRunning {
      engine.stop()
    }
    engine.reset()
    engine.disconnectNodeOutput(playerNode)
    engine.disconnectNodeOutput(eqNode)

    print("🔍 Connecting nodes:")
    print("  Audio format: \(format.sampleRate) Hz, channels: \(format.channelCount)")

    // Connect nodes at 44100 Hz - let AVAudioEngine handle conversion to 48000 Hz output
    engine.connect(playerNode, to: eqNode, format: format)
    engine.connect(eqNode, to: engine.mainMixerNode, format: format)
    // Mixer will automatically convert to output rate (48000 Hz)

    currentFormat = format

    try engine.start()
    print("✅ Engine started at \(format.sampleRate) Hz")
  }
}
