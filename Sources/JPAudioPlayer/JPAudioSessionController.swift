//
//  JPAudioSessionHandler.swift
//  
//
//  Created by Sasikumar JP on 23/07/23.
//

import Foundation
import AVFoundation

public class JPAudioSessionController: NSObject {
  
  public func configure() throws {
#if os(iOS)
      let session = AVAudioSession.sharedInstance()
      session.setCategory(.playback)
      session.setMode(.spokenAudio)
#endif
  }
}
