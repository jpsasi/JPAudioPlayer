import Foundation
import AVFoundation

@Observable
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
    print("🎵 [JPAudioEnginePlayer] play() called - Current status: \(playerStatus)")
    guard let url = playerItem.playerItemType.streamURL else {
      print("❌ [JPAudioEnginePlayer] No stream URL available")
      return
    }

    streamingPlayer.preferredSampleRate = pipeline.outputSampleRate()
    print("🎵 [JPAudioEnginePlayer] Output sample rate: \(pipeline.outputSampleRate())")

    if !isSessionConfigured {
      print("🎵 [JPAudioEnginePlayer] Configuring audio session...")
      do {
        try sessionController.configure()
        isSessionConfigured = true
        print("✅ [JPAudioEnginePlayer] Audio session configured successfully")
      } catch {
        print("❌ [JPAudioEnginePlayer] Failed to configure audio session: \(error)")
      }
    } else {
      print("ℹ️ [JPAudioEnginePlayer] Audio session already configured")
    }

    playerStatus = .buffering
    print("🎵 [JPAudioEnginePlayer] Status changed to: buffering")
    print("🎵 [JPAudioEnginePlayer] Starting stream: \(url)")
    streamingPlayer.startStreaming(url: url)
  }

  public func pause() {
    print("⏸️ [JPAudioEnginePlayer] pause() called")
    pipeline.pause()
    playerStatus = .paused
    print("⏸️ [JPAudioEnginePlayer] Status changed to: paused")
  }

  public func stop() {
    print("⏹️ [JPAudioEnginePlayer] stop() called - Current status: \(playerStatus)")
    streamingPlayer.stop()
    pipeline.stop()
    playerStatus = .stopped
    print("⏹️ [JPAudioEnginePlayer] Status changed to: stopped")
  }
}

extension JPAudioEnginePlayer: JPStreamingAudioPlayerDelegate {
  public func streamingAudioPlayer(_ player: JPStreamingAudioPlayer,
                                   didDecode buffer: AVAudioPCMBuffer,
                                   format: AVAudioFormat) {
    print("🔊 [JPAudioEnginePlayer] Received decoded buffer: \(buffer.frameLength) frames")
    pipeline.enqueue(buffer: buffer)
    if playerStatus != .playing {
      playerStatus = .playing
      print("▶️ [JPAudioEnginePlayer] Status changed to: playing")
    }
  }

  public func streamingAudioPlayer(_ player: JPStreamingAudioPlayer,
                                   didReceiveMetadata metadata: String) {
    print("📝 [JPAudioEnginePlayer] Metadata received: \(metadata)")
    metadataHandler?(metadata)
  }

  public func streamingAudioPlayer(_ player: JPStreamingAudioPlayer,
                                   didStopWithError error: Error?) {
    if let error = error {
      print("❌ [JPAudioEnginePlayer] Streaming stopped with error: \(error)")
    } else {
      print("⏹️ [JPAudioEnginePlayer] Streaming stopped normally")
    }
    pipeline.stop()
    playerStatus = error == nil ? .stopped : .failed
    print("⏹️ [JPAudioEnginePlayer] Status changed to: \(playerStatus)")
  }
}

extension JPAudioEnginePlayer: JPSessionControllerDelegate {
  public func sessionControllerDidBeginInterruption() {
    print("🔴 [INTERRUPTION] Interruption began - Stopping playback")
    stop()  // Stop network stream to prevent accumulating stale audio data
  }

  public func sessionControllerDidEndInterruption(canResume: Bool) {
    print("🟢 [INTERRUPTION] Interruption ended - canResume: \(canResume)")
    if canResume {
      print("🟢 [INTERRUPTION] Attempting to reactivate audio session and resume playback")
      // Reactivate audio session after interruption
      do {
        try sessionController.configure()
        print("✅ [INTERRUPTION] Audio session reactivated successfully")
      } catch {
        print("❌ [INTERRUPTION] Failed to reactivate audio session: \(error)")
      }
      play()  // Reconnect and resume from current live position
    } else {
      print("⏹️ [INTERRUPTION] System says cannot resume - stopping")
      stop()  // System indicates playback can't resume
    }
  }

  public func sessionControllerRouteChangeOldDeviceNotAvailable() {
    print("🔌 [ROUTE CHANGE] Old device unavailable - Stopping playback")
    stop()  // Stop when audio device disconnected (e.g., headphones unplugged)
  }

  public func sessionControllerRouteChangeNewDeviceAvailable() {
    print("🔌 [ROUTE CHANGE] New device available - Resuming playback")
    play()  // Resume when new audio device connected
  }
}

final class JPAudioEnginePipeline {
  private let engine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private let eqNode = AVAudioUnitEQ(numberOfBands: 10)
  private var currentFormat: AVAudioFormat?
  private let queue = DispatchQueue(label: "jp.audio.engine.pipeline")
  var equalizerNode: AVAudioUnitEQ { eqNode }

  // Accumulation buffer (like ring buffer pattern from reference implementation)
  private var accumulationBuffer: AVAudioPCMBuffer?
  private var accumulationOffset: AVAudioFrameCount = 0
  private let accumulationThreshold: AVAudioFrameCount = 44100  // ~1 second buffer at 44.1kHz

  func outputSampleRate() -> Double {
    engine.outputNode.outputFormat(forBus: 0).sampleRate
  }

  // Buffering state
  private var scheduledBufferCount: Int = 0
  private let minBuffersBeforePlay: Int = 3  // Reduced since we're using larger accumulated buffers
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
    // Use async with serial queue: maintains order while not blocking the decoder
    queue.async { [weak self] in
      guard let self = self else { return }
      do {
        print("🔧 [Pipeline] Enqueuing buffer with \(buffer.frameLength) frames")
        try self.prepareEngineIfNeeded(format: buffer.format)

        // ACCUMULATION PATTERN (like reference implementation):
        // Accumulate small decoded chunks into large buffers before scheduling

        // Create accumulation buffer if needed
        if self.accumulationBuffer == nil {
          self.accumulationBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                                      frameCapacity: self.accumulationThreshold * 2)
          self.accumulationOffset = 0
        }

        guard let inputChannelData = buffer.floatChannelData else {
          return
        }

        // Copy incoming buffer into accumulation buffer at current offset
        var sourceOffset: AVAudioFrameCount = 0
        var remainingFrames = buffer.frameLength

        while remainingFrames > 0 {
          guard let accumBuffer = self.accumulationBuffer,
                let accumChannelData = accumBuffer.floatChannelData else {
            return
          }

          // Check if we should schedule BEFORE copying (like reference implementation)
          // Schedule when remaining space < incoming chunk size
          let spaceLeft = self.accumulationThreshold - self.accumulationOffset
          if spaceLeft < remainingFrames && self.accumulationOffset > 0 {
            // Schedule current buffer before it overflows
            accumBuffer.frameLength = self.accumulationOffset

            self.scheduledBufferCount += 1
            self.totalBuffersScheduled += 1

            self.playerNode.scheduleBuffer(accumBuffer, completionCallbackType: .dataPlayedBack) { [weak self] callbackType in
              self?.queue.async {
                guard let self = self else { return }
                self.scheduledBufferCount -= 1
                self.totalBuffersConsumed += 1

                if self.hasStartedPlaying && self.scheduledBufferCount < 2 {
                  print("⚠️ Warning: Buffer underrun, only \(self.scheduledBufferCount) buffers remaining")
                }
              }
            }

            // Create new accumulation buffer
            self.accumulationBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                                        frameCapacity: self.accumulationThreshold * 2)
            self.accumulationOffset = 0
            continue  // Retry with new buffer
          }

          // Copy frames to accumulation buffer
          let framesToCopy = min(remainingFrames, self.accumulationThreshold - self.accumulationOffset)

          if framesToCopy > 0 {
            for channel in 0..<Int(buffer.format.channelCount) {
              let sourcePtr = inputChannelData[channel].advanced(by: Int(sourceOffset))
              let destPtr = accumChannelData[channel].advanced(by: Int(self.accumulationOffset))
              memcpy(destPtr, sourcePtr, Int(framesToCopy) * MemoryLayout<Float>.size)
            }
            self.accumulationOffset += framesToCopy
            sourceOffset += framesToCopy
            remainingFrames -= framesToCopy
          }

          // If we've reached exactly the threshold, schedule now
          if self.accumulationOffset >= self.accumulationThreshold {
            accumBuffer.frameLength = self.accumulationOffset

            // Schedule the accumulated buffer
            self.scheduledBufferCount += 1
            self.totalBuffersScheduled += 1

            // Use .dataPlayedBack to get callback when audio is ACTUALLY played
            self.playerNode.scheduleBuffer(accumBuffer, completionCallbackType: .dataPlayedBack) { [weak self] callbackType in
              self?.queue.async {
                guard let self = self else { return }
                self.scheduledBufferCount -= 1
                self.totalBuffersConsumed += 1

                // If we're running low on buffers, log it
                if self.hasStartedPlaying && self.scheduledBufferCount < 2 {
                  print("⚠️ Warning: Buffer underrun, only \(self.scheduledBufferCount) buffers remaining")
                }
              }
            }

            // Create new accumulation buffer for remaining data
            self.accumulationBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                                        frameCapacity: self.accumulationThreshold * 2)
            self.accumulationOffset = 0
          }
        }

        // Start playback only after we have enough buffers queued
        if !self.hasStartedPlaying && self.scheduledBufferCount >= self.minBuffersBeforePlay {
          print("▶️ [Pipeline] Starting playback - \(self.scheduledBufferCount) buffers queued")
          self.hasStartedPlaying = true
          self.playerNode.play()
          print("✅ [Pipeline] PlayerNode.play() called successfully")
        }
      } catch {
        print("Failed to enqueue buffer: \(error)")
      }
    }
  }
  
  func pause() {
    print("⏸️ [Pipeline] Pausing playback")
    queue.sync {
      playerNode.pause()
      print("⏸️ [Pipeline] PlayerNode paused")
    }
  }

  func stop() {
    print("⏹️ [Pipeline] Stopping playback")
    queue.sync {
      playerNode.stop()
      print("⏹️ [Pipeline] PlayerNode stopped")
      if engine.isRunning {
        print("⏹️ [Pipeline] Stopping audio engine")
        engine.stop()
      }
      engine.reset()
      currentFormat = nil
      // Reset buffering state
      scheduledBufferCount = 0
      hasStartedPlaying = false
      totalBuffersScheduled = 0
      totalBuffersConsumed = 0
      // Reset accumulation buffer
      accumulationBuffer = nil
      accumulationOffset = 0
      print("⏹️ [Pipeline] All state reset - hasStartedPlaying: false, buffers: 0")
    }
  }
  
  private func prepareEngineIfNeeded(format: AVAudioFormat) throws {
    if currentFormat == nil ||
        currentFormat?.channelCount != format.channelCount ||
        currentFormat?.sampleRate != format.sampleRate {
      print("🔧 [Pipeline] Format changed or not set - reconnecting audio graph")
      try reconnectGraph(format: format)
    } else if !engine.isRunning {
      print("🔧 [Pipeline] Engine not running - starting it")
      try engine.start()
      print("✅ [Pipeline] Audio engine started successfully")
    } else {
      print("✅ [Pipeline] Engine already running with correct format")
    }
  }

  private func reconnectGraph(format: AVAudioFormat) throws {
    print("🔧 [Pipeline] Reconnecting audio graph with format: \(format.sampleRate)Hz, \(format.channelCount) channels")
    if engine.isRunning {
      print("🔧 [Pipeline] Stopping existing engine")
      engine.stop()
    }
    engine.reset()
    engine.disconnectNodeOutput(playerNode)
    engine.disconnectNodeOutput(eqNode)

    // Get the hardware output rate
    let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    print("🔧 [Pipeline] Hardware output rate: \(outputRate)Hz")

    // Connect player → EQ at input format (44100 Hz)
    engine.connect(playerNode, to: eqNode, format: format)

    // Connect EQ → Mixer at input format (44100 Hz)
    engine.connect(eqNode, to: engine.mainMixerNode, format: format)

    // CRITICAL: Explicitly connect Mixer → Output with proper sample rate conversion format
    // This ensures AVAudioEngine's sample rate converter is properly configured
    let mixerOutputFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate,
                                          channels: format.channelCount)!
    engine.connect(engine.mainMixerNode, to: engine.outputNode, format: mixerOutputFormat)

    currentFormat = format

    print("🔧 [Pipeline] Starting audio engine")
    try engine.start()
    print("✅ [Pipeline] Audio engine started successfully")
  }
}
