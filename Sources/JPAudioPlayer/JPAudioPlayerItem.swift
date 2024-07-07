//
//  JPAudioPlayerItem.swift
//  
//
//  Created by Sasikumar JP on 26/07/23.
//

import Foundation

public enum JPAudioPlayerItemType {
  case stream(title: String, url: URL, thumbnailImageUrl: URL?)
  
  public var streamURL: URL? {
    if case let .stream(_, url, _) = self {
      return url
    }
    return nil
  }
  
  public var title: String? {
    if case let .stream(title, _, _) = self {
      return title
    }
    return nil
  }
  
  public var thumbnailUrl: URL? {
    if case let .stream(_, _, thumbnailImageUrl) = self {
      return thumbnailImageUrl
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
