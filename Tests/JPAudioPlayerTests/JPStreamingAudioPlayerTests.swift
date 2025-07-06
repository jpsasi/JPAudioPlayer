
//
//  JPStreamingAudioPlayerTests.swift
//
//
//  Created by JPS on 06/07/25.
//

import XCTest
import AVFoundation
@testable import JPAudioPlayer

final class JPStreamingAudioPlayerTests: XCTestCase {
  
  func testStreamPlayerParsesMetadataAndAudio() throws {
    let expectation = self.expectation(description: "Should receive metadata and audio chunks")
    
    let streamURL = URL(string: "https://a9radio1-a9media.radioca.st/stream")! // you can change to your stream
    let player = JPStreamingAudioPlayer()
    
    var metadataReceived = false
    var audioReceived = false
    
    player.metadataHandler = { meta in
      print("METADATA: \(meta)")
      metadataReceived = true
    }
    
    player.audioChunkHandler = { data in
      print("Audio chunk size: \(data.count)")
      if data.count > 1024 {
        audioReceived = true
      }
      if metadataReceived && audioReceived {
        expectation.fulfill()
        player.stopStream()
      }
    }
    
    player.startStream(url: streamURL)
    
    wait(for: [expectation], timeout: 15.0)
    
    // verify dumped file exists
    let dumpURL = player.getAudioDumpURL()
    XCTAssertTrue(FileManager.default.fileExists(atPath: dumpURL.path))
    
    // optionally you can try to load it with AVAudioPlayer
    
    do {
      let avPlayer = try AVAudioPlayer(contentsOf: dumpURL)
      avPlayer.play()
      sleep(5) // let it play
    } catch {
      XCTFail("Failed to play dumped audio: \(error)")
    }
  }
  
  func testMetadataParsing() {
    let player = JPStreamingAudioPlayer()
    let metaData = "StreamTitle='Test Artist - Test Title';"
    let data = metaData.data(using: .ascii)!
    
    var captured = ""
    player.metadataHandler = { text in
      captured = text
    }
    
    player.parseMetadata(data)
    
    XCTAssertTrue(captured.contains("Test Artist"))
  }

  func testPCMBufferScheduling() throws {
    let player = JPStreamingAudioPlayer()
    
    // create a fake PCM block: 44100Hz, 2 channels, 16-bit
    let sampleRate: Double = 44100
    let channels: AVAudioChannelCount = 2
    let numFrames: UInt32 = 1024
    let numBytes = Int(numFrames * 2 * 2) // 2 bytes per sample * 2 channels
    
    // fill with zeros for silence
    let silentPCM = Data(repeating: 0, count: numBytes)
    
    // setup engine
    player.setupAudioEngine()
    
    // schedule the PCM buffer
    player.schedulePCMBuffer(silentPCM)
    
    // Check the EQ bands
    XCTAssertEqual(player.eqNode.bands.count, 5)
    XCTAssertEqual(player.eqNode.bands[0].gain, 5.0) // as you set up
    XCTAssertFalse(player.eqNode.bands[0].bypass)
    
    // let the buffer schedule
    let expectation = expectation(description: "PCM scheduled")
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      XCTAssertTrue(player.playerNode.isPlaying)
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 3.0)
  }
}
