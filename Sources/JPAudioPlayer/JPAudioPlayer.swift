//
//  JPAudioPlayer.swift
//  JPAudioApps
//
//  Created by Sasikumar JP on 23/07/23.

import Foundation
import AVFoundation

enum JPAudioPlayerStatus {
  case notInitialized
  case buffering
  case playing
  case stopped
  case paused
  case failed
  case unknown
}

public class JPAudioPlayer: NSObject {
  let player: AVPlayer
  let sessionController: JPAudioSessionController
  var playerStatus: JPAudioPlayerStatus = .notInitialized
  private static var playerItemContext = 0
  
  public init(url: URL) {
    let urlAsset = AVURLAsset(url: url)
    let playerItem = AVPlayerItem(asset: urlAsset)
    player = AVPlayer(playerItem: playerItem)
    sessionController = JPAudioSessionController()
    super.init()
    
    playerItem.addObserver(self, forKeyPath: "status", options: .new, context: &JPAudioPlayer.playerItemContext)
    
    let metaData = AVPlayerItemMetadataOutput(identifiers: nil)
    metaData.setDelegate(self, queue: .main)
    playerItem.add(metaData)
  }
  
  deinit {
  }
  
  func play() {
#if os(iOS)
    sessionController.configure()
#endif
    player.play()
  }
  
  func pause() {
    player.pause()
  }
  
  func stop() {
    player.pause()
  }
  
  func resume() {
    player.play()
  }
  
  public override func observeValue(forKeyPath keyPath: String?,
                                    of object: Any?,
                                    change: [NSKeyValueChangeKey : Any]?,
                                    context: UnsafeMutableRawPointer?) {
    if let context, context == &JPAudioPlayer.playerItemContext {
      if let statusCode = (change?[NSKeyValueChangeKey.newKey] as? NSNumber)?.intValue,
         let playerStatus = AVPlayer.Status(rawValue: statusCode) {
        if playerStatus == .readyToPlay {
          self.playerStatus = .playing
          player.play()
        } else if playerStatus == .failed {
          self.playerStatus = .failed
        } else if playerStatus == .unknown {
          self.playerStatus = .unknown
        } else {
          print("Player status \(playerStatus)")
        }
      }
    } else {
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
            print("meta Data \(title)")
          }
        }
      }
    }
  }
}
