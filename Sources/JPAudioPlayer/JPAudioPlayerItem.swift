//
//  JPAudioPlayerItem.swift
//  
//
//  Created by Sasikumar JP on 26/07/23.
//

import Foundation

public enum JPAudioPlayerItemType {
  case stream(url: URL)
  
  public var streamURL: URL? {
    if case let .stream(url) = self {
      return url
    }
    return nil
  }
}

public class JPAudioPlayerItem {
  let playerItemType: JPAudioPlayerItemType
  
  public init(playerItemType: JPAudioPlayerItemType) {
    self.playerItemType = playerItemType
  }
}
