//
//  JPAudioEffectsPlayer.swift
//  
//
//  Created by Sasikumar JP on 29/07/23.
//

import Foundation
import AVFoundation
import AudioToolbox

public class JPAudioEffectsPlayer {
  
  private let playerNode = AVAudioPlayerNode()
  private let engine = AVAudioEngine()
  private let equalizer = AVAudioUnitEQ(numberOfBands: 10)
  
  init() {
    setupAudioEngine()
  }
  
  private func setupAudioEngine() {
    setupEqualizer()
    engine.attach(equalizer)
    let playerOutput = AVPlayerItemOutput()
    engine.connect(playerOutput, to: equalizer, format: nil)
    engine.connect(equalizer, to: engine.mainMixerNode, format: nil)
  }
  
  private func setupEqualizer() {
    let bands = equalizer.bands
    updateEqualiser(param: bands[0], filterType: .parametric, bandwidth: 2.0, frequency: 32.0, gain: 0, byPass: false)
    updateEqualiser(param: bands[1], filterType: .parametric, bandwidth: 2.0, frequency: 64.0, gain: 0, byPass: false)
    updateEqualiser(param: bands[2], filterType: .parametric, bandwidth: 2.0, frequency: 125.0, gain: 0, byPass: false)
    updateEqualiser(param: bands[3], filterType: .parametric, bandwidth: 2.0, frequency: 250.0, gain: 0, byPass: false)
    updateEqualiser(param: bands[4], filterType: .parametric, bandwidth: 2.0, frequency: 500.0, gain: 0, byPass: false)
    updateEqualiser(param: bands[5], filterType: .parametric, bandwidth: 2.0, frequency: 1000.0, gain: 0, byPass: false)
    updateEqualiser(param: bands[6], filterType: .parametric, bandwidth: 2.0, frequency: 2000.0, gain: 0, byPass: false)
    updateEqualiser(param: bands[7], filterType: .parametric, bandwidth: 2.0, frequency: 4000.0, gain: 0, byPass: false)
    updateEqualiser(param: bands[8], filterType: .parametric, bandwidth: 2.0, frequency: 8000.0, gain: 0, byPass: false)
    updateEqualiser(param: bands[9], filterType: .parametric, bandwidth: 2.0, frequency: 16000.0, gain: 0, byPass: false)
  }
  
  private func updateEqualiser(param: AVAudioUnitEQFilterParameters,
                               filterType: AVAudioUnitEQFilterType,
                               bandwidth: Float,
                               frequency: Float,
                               gain: Float,
                               byPass: Bool) {
    param.filterType = filterType
    param.bandwidth = bandwidth
    param.frequency = frequency
    param.gain = gain
    param.bypass = byPass
  }
}
