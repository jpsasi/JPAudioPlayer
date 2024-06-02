//
//  JPAudioPlayer.swift
//  JPAudioApps
//
//  Created by Sasikumar JP on 23/07/23.

import Foundation
import AVFoundation
import MediaPlayer

public enum JPAudioPlayerStatus {
  case notInitialized
  case buffering
  case playing
  case stopped
  case paused
  case failed
  case unknown
}

public class JPAudioPlayer: NSObject, ObservableObject {
  let playerItem: JPAudioPlayerItem
  var player: AVPlayer?
  var sessionController: JPAudioSessionController?
  let remoteCommandCenter: MPRemoteCommandCenter = MPRemoteCommandCenter.shared()
  var metaDataStreamContinuation: AsyncStream<String>.Continuation?
  public lazy var metaDataStream: AsyncStream<String> = {
    AsyncStream { (continuation: AsyncStream<String>.Continuation) -> Void in
      self.metaDataStreamContinuation = continuation
    }
  }()
  
  #if os(iOS)
  var nowPlayingSession: MPNowPlayingSession?
  #endif
  @Published public var playerStatus: JPAudioPlayerStatus = .notInitialized
  public var statusString: String {
    switch playerStatus {
      case .notInitialized:
        return "Not Initialized"
      case .buffering:
        return "Buffering"
      case .playing:
        return "Playing"
      case .stopped:
        return "Stopped"
      case .paused:
        return "Paused"
      case .failed:
        return "Failed"
      case .unknown:
        return "Unknown"
    }
  }
  @Published var title: String = ""
  private static var playerItemContext = 0
  
  public var isPlaying: Bool {
    return playerStatus == .buffering || playerStatus == .playing
  }
  
  public init(playerItem: JPAudioPlayerItem) {
    self.playerItem = playerItem
  }
  
  deinit {
  }
  
  public func startPlayer() {
    if let streamURL = playerItem.playerItemType.streamURL {
      startStreamAudio(url: streamURL)
    }
  }
  
  public func startStreamAudio(url: URL) {
    let urlAsset = AVURLAsset(url: url)
    let playerItem = AVPlayerItem(asset: urlAsset)
    player = AVPlayer(playerItem: playerItem)
    sessionController = JPAudioSessionController()
    sessionController?.sessionDelegate = self
    setupAudioSession()
    playerItem.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
    player?.addObserver(self, forKeyPath: "rate", options: [.new, .initial], context: nil)
    
    let metaData = AVPlayerItemMetadataOutput(identifiers: nil)
    metaData.setDelegate(self, queue: .main)
    playerItem.add(metaData)
    playerStatus = .buffering
    updateNowPlayingInfo()
    activateRemoteControl()
    self.nowPlayingSession = MPNowPlayingSession(players: [player!])
    self.nowPlayingSession?.delegate = self
  }
  
  private func setupAudioSession() {
#if os(iOS)
    do {
      print("configuring session control")
      try sessionController?.configure()
    } catch {
      print("session controller configure exception")
    }
#endif
  }
  
  private func updateNowPlayingInfo(title: String = "") {
    let nowPlayingInfo: [String:Any] = [
      MPNowPlayingInfoPropertyIsLiveStream: true,
      MPMediaItemPropertyAlbumTitle: "London Telugu Radio",
      MPMediaItemPropertyTitle: title
    ]
    if let player, let playerItem = player.currentItem {
      playerItem.nowPlayingInfo = nowPlayingInfo
      
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
  }
  
  private func activateRemoteControl() {
    remoteCommandCenter.playCommand.addTarget { _ in
      self.play()
      return .success
    }
    
    remoteCommandCenter.stopCommand.addTarget { _ in
      self.stop()
      return .success
    }
    
    remoteCommandCenter.pauseCommand.addTarget { _ in
      self.pause()
      return .success
    }

  }
  
  public func play() {
    player?.play()
  }
  
  public func pause() {
    player?.pause()
    playerStatus = .paused
  }
  
  public func stop() {
    player?.pause()
    playerStatus = .stopped
  }
  
  public func resume() {
    player?.play()
  }
  
  public override func observeValue(forKeyPath keyPath: String?,
                                    of object: Any?,
                                    change: [NSKeyValueChangeKey : Any]?,
                                    context: UnsafeMutableRawPointer?) {
    if let keyPath, keyPath == "status" {
      if let statusCode = (change?[NSKeyValueChangeKey.newKey] as? NSNumber)?.intValue,
         let playerStatus = AVPlayer.Status(rawValue: statusCode) {
        if playerStatus == .readyToPlay {
          self.playerStatus = .playing
          player?.play()
        } else if playerStatus == .failed {
          self.playerStatus = .failed
        } else {
          self.playerStatus = .unknown
        }
      }
    } else if let keyPath, keyPath == "rate" {
      if let rateValue = (change?[NSKeyValueChangeKey.newKey] as? NSNumber)?.intValue {
        print("rate \(rateValue)")
        if rateValue > 0 {
          playerStatus = .playing
        }
      }
    }
    else {
      super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
    }
  }
}

extension JPAudioPlayer: AVPlayerItemMetadataOutputPushDelegate {
  
  public func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                             didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                             from track: AVPlayerItemTrack?) {
    for group in groups {
      for item in group.items {
        if item.value is String {
          if let title = item.value as? String {
            print("meta data \(title)")
            updateNowPlayingInfo(title: title)
            self.metaDataStreamContinuation?.yield(title)
          }
        }
      }
    }
  }
}

@available(iOS 16.0, *)
extension JPAudioPlayer: MPNowPlayingSessionDelegate {

  public func nowPlayingSessionDidChangeActive(_ nowPlayingSession: MPNowPlayingSession) {
    print("DidChange Active")
  }
  
  public func nowPlayingSessionDidChangeCanBecomeActive(_ nowPlayingSession: MPNowPlayingSession) {
    print("Can Become Active")
  }
}

extension JPAudioPlayer: JPSessionControllerDelegate {
  
  public func sessionControllerDidBeginInterruption() {
    stop()
  }
  
  public func sessionControllerDidEndInterruption(canResume: Bool) {
    if canResume {
      play()
    } else {
      stop()
    }
  }
  
  public func sessionControllerRouteChangeNewDeviceAvailable() {
    play()
  }
  
  public func sessionControllerRouteChangeOldDeviceNotAvailable() {
    stop()
  }
}
