//
//  JPAudioSessionHandler.swift
//  
//
//  Created by Sasikumar JP on 23/07/23.
//

import Foundation
import AVFoundation
 
public protocol JPSessionControllerDelegate: AnyObject {
  func sessionControllerDidBeginInterruption()
  func sessionControllerDidEndInterruption(canResume: Bool)
}

public class JPAudioSessionController: NSObject {
  public weak var sessionDelegate: JPSessionControllerDelegate?
  
  init(sessionDelegate: JPSessionControllerDelegate? = nil) {
    self.sessionDelegate = sessionDelegate
  }
  
  public func configure() throws {
#if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback)
      try session.setMode(.spokenAudio)
    setupAudioSessionObservers()
#endif
  }
  
  public func setupAudioSessionObservers() {
#if os(iOS)
    let session = AVAudioSession.sharedInstance()
    let notificationCenter = NotificationCenter.default
    
    notificationCenter.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
      print("interruption notification")
      if let self, let userInfo = notification.userInfo, let type = userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber {
        if let interruptionType = AVAudioSession.InterruptionType(rawValue: UInt(type.intValue)) {
          switch interruptionType {
            case .began:
              self.sessionDelegate?.sessionControllerDidBeginInterruption()
            case .ended:
              if let canResume = userInfo[AVAudioSessionInterruptionOptionKey] as? NSNumber {
                self.sessionDelegate?.sessionControllerDidEndInterruption(canResume: canResume.boolValue)
              }
            @unknown default:
              fatalError()
          }
        }
      }
    }
    
    notificationCenter.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { notification in
      print("route change notification")
    }
    
    notificationCenter.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: session, queue: .main) { notification in
      
    }
#endif

  }
}
