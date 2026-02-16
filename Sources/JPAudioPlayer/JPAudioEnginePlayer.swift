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
    guard let url = playerItem.playerItemType.streamURL else { return }
    streamingPlayer.preferredSampleRate = pipeline.outputSampleRate()
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
    stop()  // Stop network stream to prevent accumulating stale audio data
  }

  public func sessionControllerDidEndInterruption(canResume: Bool) {
    if canResume {
      play()  // Reconnect and resume from current live position
    }
  }

  public func sessionControllerRouteChangeOldDeviceNotAvailable() {
    stop()  // Stop when audio device disconnected (e.g., headphones unplugged)
  }

  public func sessionControllerRouteChangeNewDeviceAvailable() {
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
          self.hasStartedPlaying = true
          self.playerNode.play()
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
      // Reset accumulation buffer
      accumulationBuffer = nil
      accumulationOffset = 0
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

    // Get the hardware output rate
    let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate

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

    try engine.start()
  }
}
