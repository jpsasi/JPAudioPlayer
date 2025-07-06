
//
//  JPStreamingAudioPlayer.swift
//
//
//  Created by JPS on 06/07/25.
//

import Foundation
import AudioToolbox
import AVFoundation

public final class JPStreamingAudioPlayer: NSObject {
  
  private var session: URLSession!
  private var task: URLSessionDataTask?
  
  private var icyMetaInt: Int?
  private var bytesUntilMeta: Int = 0
  
  private var audioFileHandle: FileHandle?
  private var audioDumpURL: URL
  private var audioFileStreamID: AudioFileStreamID?
  private let audioEngine = AVAudioEngine()
  let playerNode = AVAudioPlayerNode()
  let eqNode = AVAudioUnitEQ(numberOfBands: 5)
  private var audioConverter: AudioConverterRef?
  fileprivate var audioFormat: AudioStreamBasicDescription?
  private var inputPacketDescriptions = [AudioStreamPacketDescription]()
  
  fileprivate var audioPacketDataQueue = [Data]()

  // these handlers are injected for testability
  public var metadataHandler: ((String) -> Void)?
  public var audioChunkHandler: ((Data) -> Void)?
  
  public override init() {
    let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("stream_audio.mp3")
    self.audioDumpURL = tmpURL
    super.init()
    let config = URLSessionConfiguration.default
    self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }
  
  public func startStream(url: URL) {
    // cleanup
    try? FileManager.default.removeItem(at: audioDumpURL)
    FileManager.default.createFile(atPath: audioDumpURL.path, contents: nil)
    audioFileHandle = try? FileHandle(forWritingTo: audioDumpURL)
    
    let status = AudioFileStreamOpen(
      Unmanaged.passUnretained(self).toOpaque(),
      audioPropertyListener,
      audioPacketsListener,
      kAudioFileMP3Type, // you can change to AAC type if needed
      &audioFileStreamID
    )
    
    if status != noErr {
      print("AudioFileStreamOpen error: \(status)")
    }
    
    setupAudioEngine()
    
    var request = URLRequest(url: url)
    request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
    self.task = session.dataTask(with: request)
    task?.resume()
    
  }
  
  public func stopStream() {
    task?.cancel()
    audioFileHandle?.closeFile()
  }
  
  private func processAudioData(_ data: Data) {
    // no longer write to file
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
  
  func setupAudioEngine() {
    let eq = AVAudioUnitEQ(numberOfBands: 5)
    // you can configure EQ bands here
    for band in eq.bands {
      band.filterType = .parametric
      band.frequency = 1000
      band.bandwidth = 1.0
      band.gain = 5.0
      band.bypass = false
    }
    
    audioEngine.attach(playerNode)
    audioEngine.attach(eq)
    
    audioEngine.connect(playerNode, to: eq, format: nil)
    audioEngine.connect(eq, to: audioEngine.mainMixerNode, format: nil)
    
    do {
      try audioEngine.start()
      playerNode.play()
      print("AVAudioEngine started")
    } catch {
      print("Error starting audio engine: \(error)")
    }
  }
  
  func parseMetadata(_ meta: Data) {
    if let string = String(data: meta, encoding: .ascii) {
      metadataHandler?(string)
    }
  }
  
  public func getAudioDumpURL() -> URL {
    return audioDumpURL
  }
  
  func schedulePCMBuffer(_ data: Data) {
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 44100,
      channels: 2,
      interleaved: true
    ) else { return }
    
    let frameCapacity = UInt32(data.count) / 4  // 2 channels * 2 bytes
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return }
    buffer.frameLength = frameCapacity
    
    if let channelPtr = buffer.int16ChannelData?[0] {
      let rawPtr = UnsafeMutableRawPointer(channelPtr)
      data.copyBytes(to: rawPtr.assumingMemoryBound(to: UInt8.self), count: data.count)
    }
    
    playerNode.scheduleBuffer(buffer, completionHandler: nil)
  }

  private func handleAudioPackets(inNumberBytes: UInt32,
                                  inNumberPackets: UInt32,
                                  inInputData: UnsafeRawPointer,
                                  inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
    
    guard let inPacketDescriptions else { return }
    
    for i in 0..<Int(inNumberPackets) {
      let desc = inPacketDescriptions[i]
      let start = Int(desc.mStartOffset)
      let size = Int(desc.mDataByteSize)
      
      let packetData = Data(
        bytes: inInputData.advanced(by: start),
        count: size
      )
      
      // this is PCM frames
      schedulePCMBuffer(packetData)
    }
  }
  
  private let audioPropertyListener: AudioFileStream_PropertyListenerProc = { inClientData, inAudioFileStream, inPropertyID, ioFlags in
    let player = Unmanaged<JPStreamingAudioPlayer>.fromOpaque(inClientData).takeUnretainedValue()
    
    if inPropertyID == kAudioFileStreamProperty_DataFormat {
      var format = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout.size(ofValue: format))
      
      let status = AudioFileStreamGetProperty(
        inAudioFileStream,
        kAudioFileStreamProperty_DataFormat,
        &size,
        &format
      )
      
      if status == noErr {
        player.audioFormat = format
        print("Parsed stream format: \(format)")
        player.createAudioConverter()
      }
    }
  }
  
  private let audioPacketsListener: AudioFileStream_PacketsProc = { inClientData, inNumberBytes, inNumberPackets, inInputData, inPacketDescriptions in
    let player = Unmanaged<JPStreamingAudioPlayer>.fromOpaque(inClientData).takeUnretainedValue()
    
    guard let packetDescs = inPacketDescriptions else { return }
    
    for i in 0..<Int(inNumberPackets) {
      let desc = packetDescs[i]
      let packetData = Data(
        bytes: inInputData.advanced(by: Int(desc.mStartOffset)),
        count: Int(desc.mDataByteSize)
      )
      player.audioPacketDataQueue.append(packetData)
      player.inputPacketDescriptions.append(desc)
    }
    
    // you can immediately trigger decode
    player.decodePackets()
  }
  
  private func decodePackets() {
    guard let converter = audioConverter else { return }
    
    while !audioPacketDataQueue.isEmpty {
      let compressedPacket = audioPacketDataQueue.removeFirst()
      
      // pointer to the data
      compressedPacket.withUnsafeBytes { rawBufferPointer in
        
        // use a single input buffer
        var inputBuffer = AudioBufferList(
          mNumberBuffers: 1,
          mBuffers: AudioBuffer(
            mNumberChannels: audioFormat?.mChannelsPerFrame ?? 2,
            mDataByteSize: UInt32(compressedPacket.count),
            mData: UnsafeMutableRawPointer(mutating: rawBufferPointer.baseAddress)
          )
        )
        
        // allocate PCM output
        let maxFrames: UInt32 = 1024
        var outputBufferList = AudioBufferList(
          mNumberBuffers: 1,
          mBuffers: AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: maxFrames * 2 * 2,
            mData: malloc(Int(maxFrames * 2 * 2))
          )
        )
        var ioOutputDataPacketSize: UInt32 = maxFrames
        
        let status = AudioConverterFillComplexBuffer(
          converter,
          myAudioConverterComplexInputDataProc,
          UnsafeMutableRawPointer(mutating: rawBufferPointer.baseAddress),
          &ioOutputDataPacketSize,
          &outputBufferList,
          nil
        )
        
        if status != noErr {
          print("AudioConverter failed: \(status)")
        } else {
          if let pcmDataPtr = outputBufferList.mBuffers.mData {
            let pcmData = Data(bytes: pcmDataPtr, count: Int(outputBufferList.mBuffers.mDataByteSize))
            schedulePCMBuffer(pcmData)
          }
        }
        
        free(outputBufferList.mBuffers.mData)
      }
    }
  }
  
  private func createAudioConverter() {
    guard var inputFormat = audioFormat else { return }
    
    // tell AudioConverter you want PCM output
    var outputFormat = AudioStreamBasicDescription(
      mSampleRate: inputFormat.mSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsPacked | kAudioFormatFlagIsSignedInteger,
      mBytesPerPacket: 2 * inputFormat.mChannelsPerFrame,
      mFramesPerPacket: 1,
      mBytesPerFrame: 2 * inputFormat.mChannelsPerFrame,
      mChannelsPerFrame: inputFormat.mChannelsPerFrame,
      mBitsPerChannel: 16,
      mReserved: 0
    )
    
    var converter: AudioConverterRef?
    let status = AudioConverterNew(&inputFormat, &outputFormat, &converter)
    
    if status != noErr {
      print("AudioConverterNew failed: \(status)")
    } else {
      audioConverter = converter
      print("AudioConverter created")
    }
  }
  
}

fileprivate func myAudioConverterComplexInputDataProc(
  inAudioConverter: AudioConverterRef,
  ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
  ioData: UnsafeMutablePointer<AudioBufferList>,
  outPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
  inUserData: UnsafeMutableRawPointer?
) -> OSStatus
{
  guard let inUserData else {
    ioNumberDataPackets.pointee = 0
    return -1
  }
  
  let player = Unmanaged<JPStreamingAudioPlayer>.fromOpaque(inUserData).takeUnretainedValue()
  
  guard !player.audioPacketDataQueue.isEmpty else {
    ioNumberDataPackets.pointee = 0
    return -1
  }
  
  let packet = player.audioPacketDataQueue.removeFirst()
  
  packet.withUnsafeBytes { rawBuffer in
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = player.audioFormat?.mChannelsPerFrame ?? 2
    ioData.pointee.mBuffers.mDataByteSize = UInt32(packet.count)
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: rawBuffer.baseAddress)
  }
  
  ioNumberDataPackets.pointee = 1
  
  return noErr
}

// MARK: - URLSessionDataDelegate
extension JPStreamingAudioPlayer: URLSessionDataDelegate {
  public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                         didReceive data: Data) {
    if icyMetaInt == nil, let response = dataTask.response as? HTTPURLResponse {
      if let metaintStr = response.value(forHTTPHeaderField: "icy-metaint"),
         let metaint = Int(metaintStr) {
        icyMetaInt = metaint
        bytesUntilMeta = metaint
      }
    }
    
    var buffer = data
    
    while !buffer.isEmpty {
      if let metaint = icyMetaInt {
        let toConsume = min(buffer.count, bytesUntilMeta)
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
  
}
