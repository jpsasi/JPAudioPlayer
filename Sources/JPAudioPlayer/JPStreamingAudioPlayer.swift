
//
//  JPStreamingAudioPlayer.swift
//
//
//  Created by JPS on 06/07/25.
//

import Foundation
import AudioToolbox
import AVFoundation

public protocol JPStreamingAudioPlayerDelegate: AnyObject {
  func streamingAudioPlayer(_ player: JPStreamingAudioPlayer,
                            didDecode buffer: AVAudioPCMBuffer,
                            format: AVAudioFormat)
  func streamingAudioPlayer(_ player: JPStreamingAudioPlayer,
                            didReceiveMetadata metadata: String)
  func streamingAudioPlayer(_ player: JPStreamingAudioPlayer,
                            didStopWithError error: Error?)
}

public final class JPStreamingAudioPlayer: NSObject {
  private var session: URLSession!
  private var task: URLSessionDataTask?
  private var icyMetaInt: Int?
  private var bytesUntilMeta: Int = 0
  private var audioFileStreamID: AudioFileStreamID?
  private var streamDataFormat: AudioFileTypeID
  private var audioConverter: AudioConverterRef?
  private var magicCookie: Data?
  fileprivate var audioFormat: AudioStreamBasicDescription?
  private var decodedFormat: AVAudioFormat?  // 44100 Hz decoded format
  private var outputFormat: AVAudioFormat?    // 48000 Hz output format
  private var sampleRateConverter: AVAudioConverter?  // 44100→48000 Hz converter
  fileprivate var packetDescriptionStorage: UnsafeMutablePointer<AudioStreamPacketDescription>?
  public var preferredSampleRate: Double?
  struct ConverterInput {
    var audioData: Data?
    var packetDescriptions: [AudioStreamPacketDescription]?
    var numberOfPackets: UInt32 = 0
    var packetOffset: UInt32 = 0
    var bytesPerPacket: UInt32 = 0
  }
  fileprivate var converterInput = ConverterInput()
  public weak var delegate: JPStreamingAudioPlayerDelegate?
  private let sessionQueue: OperationQueue
  fileprivate var hasLoggedFirstBuffer = false  // Track first buffer diagnostics (fileprivate for callback access)
  fileprivate let converterQueue = DispatchQueue(label: "jp.streaming.converter.queue", qos: .userInitiated)
  
  public override init() {
    sessionQueue = OperationQueue()
    streamDataFormat = kAudioFileMP3Type
    super.init()
    sessionQueue.name = "jp.streaming.session.queue"
    session = URLSession(configuration: .default, delegate: self, delegateQueue: sessionQueue)
  }
  
  public func startStreaming(url: URL) {
    print("🌐 [StreamingPlayer] Starting stream: \(url)")
    var request = URLRequest(url: url)
    request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
    self.task = session.dataTask(with: request)
    task?.resume()
    print("🌐 [StreamingPlayer] URLSessionDataTask resumed")
  }

  public func stop() {
    print("🌐 [StreamingPlayer] stop() called")
    task?.cancel()
    task = nil
    session.invalidateAndCancel()
    // CRITICAL FIX: Use sessionQueue instead of .main to match init()
    session = URLSession(configuration: .default, delegate: self, delegateQueue: sessionQueue)
    print("🌐 [StreamingPlayer] URLSession recreated with sessionQueue")
    releaeAudioConverter()
    if let streamID = audioFileStreamID {
      AudioFileStreamClose(streamID)
      audioFileStreamID = nil
    }
    audioFormat = nil
    outputFormat = nil
    // CRITICAL FIX: Reset ICY metadata state to allow reopening audio stream on restart
    icyMetaInt = nil
    bytesUntilMeta = 0
    print("🌐 [StreamingPlayer] ICY metadata state reset")
    converterQueue.sync {
      if let storage = packetDescriptionStorage {
        storage.deallocate()
        packetDescriptionStorage = nil
      }
      converterInput = ConverterInput()
    }
    print("🌐 [StreamingPlayer] All streaming state cleaned up")
  }
}

//MARK: AudioData Processing
extension JPStreamingAudioPlayer {
  
  private func openAudioFileStream() {
    guard audioFileStreamID == nil else {
      print("🌐 [StreamingPlayer] Audio file stream already open")
      return
    }
    print("🌐 [StreamingPlayer] Opening audio file stream")
    let status = AudioFileStreamOpen(
      Unmanaged.passUnretained(self).toOpaque(),
      audioPropertyListenerCallback,
      audioPacketsListener,
      streamDataFormat,
      &audioFileStreamID
    )
    if status != noErr {
      print("❌ [StreamingPlayer] AudioFileStreamOpen error: \(status)")
    } else {
      print("✅ [StreamingPlayer] Audio file stream opened successfully")
    }
  }
  
  private func processAudioData(_ data: Data) {
    if let streamID = audioFileStreamID {
      let status = AudioFileStreamParseBytes(
        streamID,
        UInt32(data.count),
        [UInt8](data),
        []
      )
      if status != noErr {
        print("Parse error: \(status)")
      }
    }
  }
  
  func parseMetadata(_ meta: Data) {
    if let string = String(data: meta, encoding: .ascii) {
      print("Meta Data \(string)")

      // Parse ICY metadata format: StreamTitle='Artist - Title';
      let cleanedMetadata = extractStreamTitle(from: string)
      delegate?.streamingAudioPlayer(self, didReceiveMetadata: cleanedMetadata)
    }
  }

  private func extractStreamTitle(from metadata: String) -> String {
    // Look for StreamTitle='...' pattern
    if let range = metadata.range(of: "StreamTitle='") {
      let startIndex = range.upperBound
      if let endRange = metadata[startIndex...].range(of: "';") {
        let title = String(metadata[startIndex..<endRange.lowerBound])
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    // Fallback to original if pattern not found
    return metadata.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  
  fileprivate func handleAudioProperty(_ inAudioFileStream: AudioFileStreamID, propertyID: AudioFileStreamPropertyID) {
    if propertyID == kAudioFileStreamProperty_DataFormat {
      var format = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      let status = AudioFileStreamGetProperty(
        inAudioFileStream,
        kAudioFileStreamProperty_DataFormat,
        &size,
        &format
      )
      if status == noErr {
        self.audioFormat = format
        createAudioConverter()
      }
    } else if propertyID == kAudioFileStreamProperty_MagicCookieData {
      // Magic cookie arrived - configure it if converter already exists
      if audioConverter != nil {
        configureMagicCookie()
      }
    }
  }
  
  fileprivate func decodePacketsCopied(audioData: Data,
                                       numberOfPackets: UInt32,
                                       packetDescriptions: [AudioStreamPacketDescription]?) {
    guard let converter = audioConverter,
          let outputFmt = outputFormat else { return }

    // Set up converter input with the copied data
    converterInput.audioData = audioData
    converterInput.packetDescriptions = packetDescriptions
    converterInput.numberOfPackets = numberOfPackets
    converterInput.packetOffset = 0
    if numberOfPackets > 0 {
      converterInput.bytesPerPacket = max(1, UInt32(audioData.count) / numberOfPackets)
    } else {
      converterInput.bytesPerPacket = UInt32(audioData.count)
    }

    let maxOutputFrames: UInt32 = 4096  // Match reference implementation's smaller chunks
    let outputChannels = Int(outputFmt.channelCount)

    // Process packets one at a time
    while converterInput.packetOffset < converterInput.numberOfPackets {
      // Allocate separate buffers for each channel (NON-INTERLEAVED - matching working implementation)
      let bytesPerChannel = Int(maxOutputFrames) * MemoryLayout<Float>.size
      var channelBuffers: [UnsafeMutableRawPointer] = []
      for _ in 0..<outputChannels {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytesPerChannel, alignment: 16)
        memset(buffer, 0, bytesPerChannel)
        channelBuffers.append(buffer)
      }
      defer {
        channelBuffers.forEach { $0.deallocate() }
      }

      // Create AudioBufferList for NON-INTERLEAVED format (matching working implementation)
      let bufferListSize = AudioBufferList.sizeInBytes(maximumBuffers: outputChannels)
      let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
      defer { bufferListPointer.deallocate() }

      let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer<AudioBufferList>(OpaquePointer(bufferListPointer)))
      bufferList.count = outputChannels
      for i in 0..<outputChannels {
        bufferList[i] = AudioBuffer(
          mNumberChannels: 1,  // NON-INTERLEAVED: 1 channel per buffer
          mDataByteSize: UInt32(bytesPerChannel),
          mData: channelBuffers[i]
        )
      }

      var ioOutputDataPacketSize: UInt32 = maxOutputFrames

      let status = AudioConverterFillComplexBuffer(
        converter,
        myAudioConverterComplexInputDataProc,
        Unmanaged.passUnretained(self).toOpaque(),
        &ioOutputDataPacketSize,
        bufferList.unsafeMutablePointer,
        nil
      )

      // Process frames even if status=-1 (means "no more input" but partial output is valid)
      if ioOutputDataPacketSize > 0 {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputFmt,
                                               frameCapacity: AVAudioFrameCount(ioOutputDataPacketSize)) else {
          break
        }

        // Direct copy: both AudioConverter and AVAudioPCMBuffer use NON-INTERLEAVED format
        if let floatChannelData = pcmBuffer.floatChannelData {
          let frameCount = Int(ioOutputDataPacketSize)
          let bytesPerChannelToCopy = frameCount * MemoryLayout<Float>.size

          // Check if buffer contains actual audio data (not all zeros)
          let ch0 = channelBuffers[0].assumingMemoryBound(to: Float.self)
          let ch1 = channelBuffers[1].assumingMemoryBound(to: Float.self)

          // Sample check: look at multiple points in the buffer
          var hasNonZeroSamples = false
          let checkPoints = min(frameCount, 100)
          for i in 0..<checkPoints {
            if abs(ch0[i]) > 0.0001 || abs(ch1[i]) > 0.0001 {
              hasNonZeroSamples = true
              break
            }
          }

          if !hasNonZeroSamples {
            // Skip silent buffer (AudioConverter priming) - don't send to delegate
          } else {
            // Copy each channel buffer directly
            for channel in 0..<outputChannels {
              memcpy(floatChannelData[channel], channelBuffers[channel], bytesPerChannelToCopy)
            }

            pcmBuffer.frameLength = AVAudioFrameCount(ioOutputDataPacketSize)
            hasLoggedFirstBuffer = true
            delegate?.streamingAudioPlayer(self, didDecode: pcmBuffer, format: outputFmt)
          }
        }

        // If status=-1 (no more input), we've processed what we got, now break
        // If status is a real error (not 0, not -1), log and break
        if status == -1 {
          break  // No more input data available, wait for next batch
        } else if status != noErr {
          print("❌ AudioConverterFillComplexBuffer failed: \(status)")
          break
        }
      } else {
        // No frames produced
        if status != noErr && status != -1 {
          print("❌ AudioConverterFillComplexBuffer failed: \(status)")
        }
        break
      }
    }

    // Reset converter input after processing
    converterInput = ConverterInput()
  }

  private func createAudioConverter() {
    guard var inputFormat = audioFormat else { return }

    // MATCH WORKING IMPLEMENTATION: Always use 44100 Hz, 2 channels
    let outputSampleRate: Double = 44100.0
    let outputChannels: UInt32 = 2

    // AudioConverter output: Standard non-interleaved format (matching working implementation)
    let processingFormat = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate,
                                         channels: AVAudioChannelCount(outputChannels))!
    let asbd = processingFormat.streamDescription.pointee

    var converterOutputDesc = asbd

    var converter: AudioConverterRef?
    let status = AudioConverterNew(&inputFormat, &converterOutputDesc, &converter)

    if status != noErr {
      print("AudioConverterNew failed: \(status)")
      return
    }

    audioConverter = converter
    outputFormat = processingFormat
    configureMagicCookie()
  }

  private func configureMagicCookie() {
    guard let audioFileStreamID = audioFileStreamID,
          let converter = audioConverter else { return }

    var cookieSize: UInt32 = 0
    let status = AudioFileStreamGetPropertyInfo(
      audioFileStreamID,
      kAudioFileStreamProperty_MagicCookieData,
      &cookieSize,
      nil
    )

    if status == noErr && cookieSize > 0 {
      var cookieData = [UInt8](repeating: 0, count: Int(cookieSize))
      let cookieStatus = AudioFileStreamGetProperty(
        audioFileStreamID,
        kAudioFileStreamProperty_MagicCookieData,
        &cookieSize,
        &cookieData
      )

      if cookieStatus == noErr {
        let cookie = Data(cookieData)
        self.magicCookie = cookie  // Store for later if needed

        // Set the cookie on the converter
        let setStatus = AudioConverterSetProperty(
          converter,
          kAudioConverterDecompressionMagicCookie,
          UInt32(cookie.count),
          (cookie as NSData).bytes
        )

        if setStatus != noErr {
          print("AudioConverterSetProperty(magic cookie) failed: \(setStatus)")
        }
      }
    }
  }
  
  private func releaeAudioConverter() {
    if let converter = self.audioConverter {
      AudioConverterReset(converter)
      AudioConverterDispose(converter)
      self.audioConverter = nil
    }
  }
  
}

fileprivate let audioPropertyListenerCallback: AudioFileStream_PropertyListenerProc = { inClientData, inAudioFileStream, inPropertyID, ioFlags in
  let player = Unmanaged<JPStreamingAudioPlayer>.fromOpaque(inClientData).takeUnretainedValue()
  player.handleAudioProperty(inAudioFileStream, propertyID: inPropertyID)
}

fileprivate let audioPacketsListener: AudioFileStream_PacketsProc = { inClientData, inNumberBytes, inNumberPackets, inInputData, inPacketDescriptions in
  let player = Unmanaged<JPStreamingAudioPlayer>.fromOpaque(inClientData).takeUnretainedValue()

  // Copy data immediately since pointers are only valid during callback
  let dataCopy = Data(bytes: inInputData, count: Int(inNumberBytes))
  var packetDescsCopy: [AudioStreamPacketDescription]?
  if let descs = inPacketDescriptions {
    packetDescsCopy = Array(UnsafeBufferPointer(start: descs, count: Int(inNumberPackets)))
  }

  // Decode asynchronously to avoid blocking the audio parsing thread
  player.converterQueue.async {
    player.decodePacketsCopied(audioData: dataCopy,
                               numberOfPackets: inNumberPackets,
                               packetDescriptions: packetDescsCopy)
  }
}

fileprivate func myAudioConverterComplexInputDataProc(
  inAudioConverter: AudioConverterRef,
  ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
  ioData: UnsafeMutablePointer<AudioBufferList>,
  outPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
  inUserData: UnsafeMutableRawPointer?
) -> OSStatus {

  guard let inUserData else {
    ioNumberDataPackets.pointee = 0
    return -1
  }

  let player = Unmanaged<JPStreamingAudioPlayer>.fromOpaque(inUserData).takeUnretainedValue()

  // No need for sync - we're already on converterQueue from the async decode call
  guard let audioData = player.converterInput.audioData else {
    ioNumberDataPackets.pointee = 0
    return -1
  }

  let packetOffset = player.converterInput.packetOffset
  let numberOfPackets = player.converterInput.numberOfPackets

  if packetOffset >= numberOfPackets {
    ioNumberDataPackets.pointee = 0
    return -1
  }

  let bytesToCopy: UInt32
  let startOffset: Int

  // Handle packet descriptions (VBR format like MP3)
  if let packetDescs = player.converterInput.packetDescriptions, Int(packetOffset) < packetDescs.count {
    let desc = packetDescs[Int(packetOffset)]
    bytesToCopy = desc.mDataByteSize
    startOffset = Int(desc.mStartOffset)

    // Allocate stable storage for packet description if needed
    if player.packetDescriptionStorage == nil {
      player.packetDescriptionStorage = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    }

    // Copy and modify packet description
    player.packetDescriptionStorage!.pointee = desc
    player.packetDescriptionStorage!.pointee.mStartOffset = 0
    outPacketDescription?.pointee = player.packetDescriptionStorage
  } else {
    // CBR format - no packet descriptions
    bytesToCopy = player.converterInput.bytesPerPacket
    startOffset = Int(player.converterInput.bytesPerPacket) * Int(packetOffset)
    outPacketDescription?.pointee = nil
  }

  // Validate bounds
  guard startOffset + Int(bytesToCopy) <= audioData.count else {
    print("ERROR: Invalid packet bounds - offset: \(startOffset), size: \(bytesToCopy), total: \(audioData.count)")
    ioNumberDataPackets.pointee = 0
    return -1
  }

  // Provide data to AudioConverter
  // Use NSData.bytes to get a stable pointer that remains valid as long as the Data is alive
  // The Data is kept alive by converterInput.audioData
  let nsData = audioData as NSData
  let baseAddress = nsData.bytes.advanced(by: startOffset)

  ioData.pointee.mNumberBuffers = 1
  ioData.pointee.mBuffers.mNumberChannels = player.audioFormat?.mChannelsPerFrame ?? 2
  ioData.pointee.mBuffers.mDataByteSize = bytesToCopy
  ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: baseAddress)

  ioNumberDataPackets.pointee = 1

  // Increment packet offset directly (already on converterQueue)
  player.converterInput.packetOffset += 1

  return noErr
}

extension JPStreamingAudioPlayer: URLSessionDataDelegate {

  public func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    print("🌐 [StreamingPlayer] Received \(data.count) bytes of data")
    if icyMetaInt == nil, let response = dataTask.response as? HTTPURLResponse {
#if os(macOS)
      if #available(macOS 10.15, *) {
        if let metaintStr = response.value(forHTTPHeaderField: "icy-metaint"),
           let metaint = Int(metaintStr) {
          icyMetaInt = metaint
          bytesUntilMeta = metaint
        }
        if let contentType = response.value(forHTTPHeaderField: "Content-Type") {
          if contentType == "audio/aacp" {
            streamDataFormat = kAudioFileAAC_ADTSType
          } else {
            streamDataFormat = kAudioFileMP3Type
          }
        }
      }
#else
      if let metaintStr = response.value(forHTTPHeaderField: "icy-metaint"),
         let metaint = Int(metaintStr) {
        icyMetaInt = metaint
        bytesUntilMeta = metaint
      }
      if let contentType = response.value(forHTTPHeaderField: "Content-Type") {
        if contentType == "audio/aacp" {
          streamDataFormat = kAudioFileAAC_ADTSType
        } else {
          streamDataFormat = kAudioFileMP3Type
        }
      }
#endif
      openAudioFileStream()
    }
    
    var buffer = data
    while !buffer.isEmpty {
      if let metaint = icyMetaInt {
        // SAFETY: Guard against negative bytesUntilMeta from race conditions
        if bytesUntilMeta < 0 {
          print("⚠️ [StreamingPlayer] WARNING: bytesUntilMeta is negative (\(bytesUntilMeta)), resetting to metaint")
          bytesUntilMeta = metaint
        }

        let toConsume = min(buffer.count, bytesUntilMeta)

        // SAFETY: Ensure toConsume is non-negative
        guard toConsume > 0 else {
          print("⚠️ [StreamingPlayer] WARNING: toConsume is \(toConsume), skipping")
          break
        }

        let audioData = buffer.prefix(toConsume)

        processAudioData(audioData)

        buffer.removeFirst(toConsume)
        bytesUntilMeta -= toConsume

        if bytesUntilMeta == 0 {
          guard !buffer.isEmpty else { break }
          let metaLengthByte = buffer.first!
          let metaLength = Int(metaLengthByte) * 16
          buffer.removeFirst(1)
          
          if metaLength > 0 && buffer.count >= metaLength {
            let metaDataBlock = buffer.prefix(metaLength)
            parseMetadata(metaDataBlock)
            buffer.removeFirst(metaLength)
          }
          bytesUntilMeta = metaint
        }
      } else {
        processAudioData(buffer)
        buffer.removeAll()
      }
    }
  }
  
  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    if let error = error {
      print("🌐 [StreamingPlayer] URLSession task completed with error: \(error)")
    } else {
      print("🌐 [StreamingPlayer] URLSession task completed successfully")
    }
    delegate?.streamingAudioPlayer(self, didStopWithError: error)
  }
}
//public final class JPStreamingAudioPlayer: NSObject, ObservableObject {
//
//  private var session: URLSession!
//  private var task: URLSessionDataTask?
//  private var magicCookie: Data?
//
//  private var icyMetaInt: Int?
//  private var bytesUntilMeta: Int = 0
//  var sessionController: JPAudioSessionController?
//  private var audioFileStreamID: AudioFileStreamID?
//  private let audioEngine = AVAudioEngine()
//  let playerNode = AVAudioPlayerNode()
//  let eqNode = AVAudioUnitEQ(numberOfBands: 5)
//  private var audioConverter: AudioConverterRef?
//  fileprivate var audioFormat: AudioStreamBasicDescription?
//  private var inputPacketDescriptions = [AudioStreamPacketDescription]()
//
//  fileprivate var audioPacketDataQueue = [Data]()
//
//  // these handlers are injected for testability
//  public var metadataHandler: ((String) -> Void)?
//  public var audioChunkHandler: ((Data) -> Void)?
//
//  public override init() {
//    super.init()
//    let config = URLSessionConfiguration.default
//    self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
//  }
//
//  public func startStream(url: URL) {
//    sessionController = JPAudioSessionController()
//#if os(iOS)
//    do {
//      print("configuring session control")
//      try sessionController?.configure()
//    } catch {
//      print("session controller configure exception")
//    }
//#endif
//    let status = AudioFileStreamOpen(
//      Unmanaged.passUnretained(self).toOpaque(),
//      audioPropertyListener,
//      audioPacketsListener,
//      kAudioFileMP3Type, // you can change to AAC type if needed
//      &audioFileStreamID
//    )
//
//    if status != noErr {
//      print("AudioFileStreamOpen error: \(status)")
//    }
//
//    setupAudioEngine()
//
//    var request = URLRequest(url: url)
//    request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
//    self.task = session.dataTask(with: request)
//    task?.resume()
//
//  }
//
//  public func stopStream() {
//    task?.cancel()
//  }
//
//  private func processAudioData(_ data: Data) {
//    // no longer write to file
//    if let streamID = audioFileStreamID {
//      let status = AudioFileStreamParseBytes(
//        streamID,
//        UInt32(data.count),
//        [UInt8](data),
//        []
//      )
//      if status != noErr {
//        print("Parse error: \(status)")
//      }
//    }
//  }
//
//  func setupAudioEngine() {
//    let eq = AVAudioUnitEQ(numberOfBands: 5)
//    // you can configure EQ bands here
//    for band in eq.bands {
//      band.filterType = .parametric
//      band.frequency = 1000
//      band.bandwidth = 1.0
//      band.gain = 5.0
//      band.bypass = false
//    }
//
//    audioEngine.attach(playerNode)
//    audioEngine.attach(eq)
//
//    audioEngine.connect(playerNode, to: eq, format: nil)
//    audioEngine.connect(eq, to: audioEngine.mainMixerNode, format: nil)
//
//    do {
//      try audioEngine.start()
//      playerNode.play()
//      print("AVAudioEngine started")
//    } catch {
//      print("Error starting audio engine: \(error)")
//    }
//  }
//
//  func parseMetadata(_ meta: Data) {
//    if let string = String(data: meta, encoding: .ascii) {
//      metadataHandler?(string)
//    }
//  }
//
//  func schedulePCMBuffer(_ data: Data) {
//    guard let format = AVAudioFormat(
//      commonFormat: .pcmFormatInt16,
//      sampleRate: 44100,
//      channels: 2,
//      interleaved: true
//    ) else { return }
//
//    let frameCapacity = UInt32(data.count) / 4  // 2 channels * 2 bytes
//    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return }
//    buffer.frameLength = frameCapacity
//
//    if let channelPtr = buffer.int16ChannelData?[0] {
//      let rawPtr = UnsafeMutableRawPointer(channelPtr)
//      data.copyBytes(to: rawPtr.assumingMemoryBound(to: UInt8.self), count: data.count)
//    }
//
//    playerNode.scheduleBuffer(buffer, completionHandler: nil)
//  }
//
//  private func handleAudioPackets(inNumberBytes: UInt32,
//                                  inNumberPackets: UInt32,
//                                  inInputData: UnsafeRawPointer,
//                                  inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
//
//    guard let inPacketDescriptions else { return }
//
//    for i in 0..<Int(inNumberPackets) {
//      let desc = inPacketDescriptions[i]
//      let start = Int(desc.mStartOffset)
//      let size = Int(desc.mDataByteSize)
//
//      let packetData = Data(
//        bytes: inInputData.advanced(by: start),
//        count: size
//      )
//
//      // this is PCM frames
//      schedulePCMBuffer(packetData)
//    }
//  }
//  private let audioPropertyListener = JPStreamingAudioPlayer.audioPropertyListenerCallback
//
//  private static let audioPropertyListenerCallback: AudioFileStream_PropertyListenerProc = { inClientData, inAudioFileStream, inPropertyID, ioFlags in
//    let player = Unmanaged<JPStreamingAudioPlayer>.fromOpaque(inClientData).takeUnretainedValue()
//    player.handleAudioProperty(inAudioFileStream, propertyID: inPropertyID)
//  }
//
//  private func handleAudioProperty(_ inAudioFileStream: AudioFileStreamID, propertyID: AudioFileStreamPropertyID) {
//    if propertyID == kAudioFileStreamProperty_DataFormat {
//      var format = AudioStreamBasicDescription()
//      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
//      let status = AudioFileStreamGetProperty(
//        inAudioFileStream,
//        kAudioFileStreamProperty_DataFormat,
//        &size,
//        &format
//      )
//      if status == noErr {
//        self.audioFormat = format
//        print("Parsed stream format: \(format)")
//        createAudioConverter()
//      }
//    }
//    else if propertyID == kAudioFileStreamProperty_MagicCookieData {
//      var cookieSize: UInt32 = 0
//      let status = AudioFileStreamGetPropertyInfo(
//        inAudioFileStream,
//        kAudioFileStreamProperty_MagicCookieData,
//        &cookieSize,
//        nil
//      )
//      if status == noErr && cookieSize > 0 {
//        var cookieData = [UInt8](repeating: 0, count: Int(cookieSize))
//        let cookieStatus = AudioFileStreamGetProperty(
//          inAudioFileStream,
//          kAudioFileStreamProperty_MagicCookieData,
//          &cookieSize,
//          &cookieData
//        )
//        if cookieStatus == noErr {
//          self.magicCookie = Data(cookieData)
//          print("Magic cookie extracted of size \(cookieSize)")
//        }
//      }
//    }
//  }
//
//  private let audioPacketsListener: AudioFileStream_PacketsProc = { inClientData, inNumberBytes, inNumberPackets, inInputData, inPacketDescriptions in
//    let player = Unmanaged<JPStreamingAudioPlayer>.fromOpaque(inClientData).takeUnretainedValue()
//
//    guard let packetDescs = inPacketDescriptions else { return }
//
//    for i in 0..<Int(inNumberPackets) {
//      let desc = packetDescs[i]
//      let packetData = Data(
//        bytes: inInputData.advanced(by: Int(desc.mStartOffset)),
//        count: Int(desc.mDataByteSize)
//      )
//      player.audioPacketDataQueue.append(packetData)
//      player.inputPacketDescriptions.append(desc)
//    }
//
//    // you can immediately trigger decode
//    player.decodePackets()
//  }
//
//  private func decodePackets() {
//    guard let converter = audioConverter else { return }
//
//    while !audioPacketDataQueue.isEmpty {
//      let compressedPacket = audioPacketDataQueue.removeFirst()
//
//      // pointer to the data
//      compressedPacket.withUnsafeBytes { rawBufferPointer in
//
//        // use a single input buffer
//        var inputBuffer = AudioBufferList(
//          mNumberBuffers: 1,
//          mBuffers: AudioBuffer(
//            mNumberChannels: audioFormat?.mChannelsPerFrame ?? 2,
//            mDataByteSize: UInt32(compressedPacket.count),
//            mData: UnsafeMutableRawPointer(mutating: rawBufferPointer.baseAddress)
//          )
//        )
//
//        // allocate PCM output
//        let maxFrames: UInt32 = 1024
//        var outputBufferList = AudioBufferList(
//          mNumberBuffers: 1,
//          mBuffers: AudioBuffer(
//            mNumberChannels: 2,
//            mDataByteSize: maxFrames * 2 * 2,
//            mData: malloc(Int(maxFrames * 2 * 2))
//          )
//        )
//        var ioOutputDataPacketSize: UInt32 = maxFrames
//
//        let status = AudioConverterFillComplexBuffer(
//          converter,
//          myAudioConverterComplexInputDataProc,
//          Unmanaged.passUnretained(self).toOpaque(),
//          &ioOutputDataPacketSize,
//          &outputBufferList,
//          nil
//        )
//
//        if status != noErr {
//          print("AudioConverter failed: \(status)")
//        } else {
//          if let pcmDataPtr = outputBufferList.mBuffers.mData {
//            let pcmData = Data(bytes: pcmDataPtr, count: Int(outputBufferList.mBuffers.mDataByteSize))
//            schedulePCMBuffer(pcmData)
//          }
//        }
//
//        free(outputBufferList.mBuffers.mData)
//      }
//    }
//  }
//
//  private func createAudioConverter() {
//    guard var inputFormat = audioFormat else { return }
//
//    // tell AudioConverter you want PCM output
//    var outputFormat = AudioStreamBasicDescription(
//      mSampleRate: inputFormat.mSampleRate,
//      mFormatID: kAudioFormatLinearPCM,
//      mFormatFlags: kAudioFormatFlagIsPacked | kAudioFormatFlagIsSignedInteger,
//      mBytesPerPacket: 2 * inputFormat.mChannelsPerFrame,
//      mFramesPerPacket: 1,
//      mBytesPerFrame: 2 * inputFormat.mChannelsPerFrame,
//      mChannelsPerFrame: inputFormat.mChannelsPerFrame,
//      mBitsPerChannel: 16,
//      mReserved: 0
//    )
//
//    var converter: AudioConverterRef?
//    let status = AudioConverterNew(&inputFormat, &outputFormat, &converter)
//
//    if status != noErr {
//      print("AudioConverterNew failed: \(status)")
//    } else {
//      audioConverter = converter
//      print("AudioConverter created")
//      // set cookie if available
//      if let cookieData = magicCookie {
//        let cookieStatus = AudioConverterSetProperty(
//          converter!,
//          kAudioConverterDecompressionMagicCookie,
//          UInt32(cookieData.count),
//          (cookieData as NSData).bytes
//        )
//        if cookieStatus != noErr {
//          print("AudioConverterSetProperty(magic cookie) failed: \(cookieStatus)")
//        } else {
//          print("Magic cookie set on AudioConverter")
//        }
//      }
//    }
//  }
//
//}
//
//fileprivate func myAudioConverterComplexInputDataProc(
//  inAudioConverter: AudioConverterRef,
//  ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
//  ioData: UnsafeMutablePointer<AudioBufferList>,
//  outPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
//  inUserData: UnsafeMutableRawPointer?
//) -> OSStatus
//{
//  guard let inUserData else {
//    ioNumberDataPackets.pointee = 0
//    return -1
//  }
//
//  let player = Unmanaged<JPStreamingAudioPlayer>.fromOpaque(inUserData).takeUnretainedValue()
//
//  guard !player.audioPacketDataQueue.isEmpty else {
//    ioNumberDataPackets.pointee = 0
//    return -1
//  }
//
//  let packet = player.audioPacketDataQueue.removeFirst()
//
//  packet.withUnsafeBytes { rawBuffer in
//    ioData.pointee.mNumberBuffers = 1
//    ioData.pointee.mBuffers.mNumberChannels = player.audioFormat?.mChannelsPerFrame ?? 2
//    ioData.pointee.mBuffers.mDataByteSize = UInt32(packet.count)
//    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: rawBuffer.baseAddress)
//  }
//
//  ioNumberDataPackets.pointee = 1
//
//  return noErr
//}
//
//// MARK: - URLSessionDataDelegate
//extension JPStreamingAudioPlayer: URLSessionDataDelegate {
//  public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
//                         didReceive data: Data) {
//    if icyMetaInt == nil, let response = dataTask.response as? HTTPURLResponse {
//      if let metaintStr = response.value(forHTTPHeaderField: "icy-metaint"),
//         let metaint = Int(metaintStr) {
//        icyMetaInt = metaint
//        bytesUntilMeta = metaint
//      }
//    }
//
//    var buffer = data
//
//    while !buffer.isEmpty {
//      if let metaint = icyMetaInt {
//        let toConsume = min(buffer.count, bytesUntilMeta)
//        let audioData = buffer.prefix(toConsume)
//
//        processAudioData(audioData)
//
//        buffer.removeFirst(toConsume)
//        bytesUntilMeta -= toConsume
//
//        if bytesUntilMeta == 0 {
//          guard !buffer.isEmpty else { break }
//          let metaLengthByte = buffer.first!
//          let metaLength = Int(metaLengthByte) * 16
//          buffer.removeFirst(1)
//
//          if metaLength > 0 && buffer.count >= metaLength {
//            let metaDataBlock = buffer.prefix(metaLength)
//            parseMetadata(metaDataBlock)
//            buffer.removeFirst(metaLength)
//          }
//          bytesUntilMeta = metaint
//        }
//      } else {
//        processAudioData(buffer)
//        buffer.removeAll()
//      }
//    }
//  }
//
//}
