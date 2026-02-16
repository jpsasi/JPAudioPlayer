//
//  JPAudioSessionHandler.swift
//
//
//  Created by Sasikumar JP on 23/07/23.
//

import Foundation
#if os(iOS)
import AVFoundation
#endif

public protocol JPSessionControllerDelegate: AnyObject {
  func sessionControllerDidBeginInterruption()
  func sessionControllerDidEndInterruption(canResume: Bool)
  func sessionControllerRouteChangeOldDeviceNotAvailable()
  func sessionControllerRouteChangeNewDeviceAvailable()
}

#if os(iOS)
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
    try session.setActive(true)
    setupAudioSessionObservers()
#endif
  }
  
  public func setupAudioSessionObservers() {
#if os(iOS)
    let session = AVAudioSession.sharedInstance()
    let notificationCenter = NotificationCenter.default
    
    notificationCenter.addObserver(forName: AVAudioSession.interruptionNotification,
                                   object: session, queue: .main) { [weak self] notification in
      if let self {
        self.handleInterruption(notification: notification)
      }
    }
    
    notificationCenter.addObserver(forName: AVAudioSession.routeChangeNotification,
                                   object: session,
                                   queue: .main) { [weak self] notification in
      if let self {
        self.handleRouteChanges(notification: notification)
      }
    }
    
    notificationCenter.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification,
                                   object: session, queue: .main) { [weak self] notification in
      self?.sessionDelegate?.sessionControllerDidBeginInterruption()
    }

    // Observe when other apps start/stop audio (like YouTube)
    notificationCenter.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification,
                                   object: session, queue: .main) { [weak self] notification in
      if let self {
        self.handleSilenceSecondaryAudioHint(notification: notification)
      }
    }
#endif
  }
  
  private func handleInterruption(notification: Notification) {
    if let userInfo = notification.userInfo,
        let type = userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber {
      if let interruptionType = AVAudioSession.InterruptionType(rawValue: UInt(type.intValue)) {
        switch interruptionType {
          case .began:
            sessionDelegate?.sessionControllerDidBeginInterruption()
          case .ended:
            if let canResume = userInfo[AVAudioSessionInterruptionOptionKey] as? NSNumber {
              sessionDelegate?.sessionControllerDidEndInterruption(canResume: canResume.boolValue)
            } else {
              sessionDelegate?.sessionControllerDidEndInterruption(canResume: false)
            }
          @unknown default:
            fatalError()
        }
      }
    }
  }
  
  private func handleRouteChanges(notification: Notification) {
    if let userInfo = notification.userInfo,
       let reason = userInfo[AVAudioSessionRouteChangeReasonKey] as? NSNumber,
        let changeReason = AVAudioSession.RouteChangeReason(rawValue: reason.uintValue) {
      switch changeReason {
        case .newDeviceAvailable:
          self.sessionDelegate?.sessionControllerRouteChangeNewDeviceAvailable()
        case .oldDeviceUnavailable:
          self.sessionDelegate?.sessionControllerRouteChangeOldDeviceNotAvailable()
        default:
          break
      }
    }
  }

  private func handleSilenceSecondaryAudioHint(notification: Notification) {
    if let userInfo = notification.userInfo,
       let hintType = userInfo[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? NSNumber {
      let hintValue = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: hintType.uintValue)
      switch hintValue {
        case .begin:
          sessionDelegate?.sessionControllerDidBeginInterruption()
        case .end:
          sessionDelegate?.sessionControllerDidEndInterruption(canResume: true)
        default:
          break
      }
    }
  }
}
#else
public class JPAudioSessionController: NSObject {
  public weak var sessionDelegate: JPSessionControllerDelegate?
  
  init(sessionDelegate: JPSessionControllerDelegate? = nil) {
    self.sessionDelegate = sessionDelegate
  }
  
  public func configure() throws {
    // macOS does not expose AVAudioSession; nothing to configure.
  }
  
  public func setupAudioSessionObservers() {}
}
#endif
