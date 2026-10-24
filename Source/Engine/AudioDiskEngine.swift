//
//  AudioDiskEngine.swift
//  SwiftAudioPlayer
//
//  Created by Tanha Kabir on 2019-01-29.
//  Copyright © 2019 Tanha Kabir, Jon Mercer
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation
import AVFoundation

class AudioDiskEngine: AudioEngine {
    private var bufferedOutput: BufferedAudioOutput?
    private var routeObserver: NSObjectProtocol?

    override var usesBufferedOutput: Bool { bufferedOutput != nil }
    override var volume: Float {
        get { bufferedOutput?.volume ?? super.volume }
        set {
            if let output = bufferedOutput {
                output.volume = newValue
            } else {
                super.volume = newValue
            }
        }
    }

    var audioFormat: AVAudioFormat?
    var audioSampleRate: Float = 0
    var audioLengthSamples: AVAudioFramePosition = 0
    var seekFrame: AVAudioFramePosition = 0
    var currentPosition: AVAudioFramePosition = 0
    
    var audioFile: AVAudioFile?
    
    var currentFrame: AVAudioFramePosition {
        guard let lastRenderTime = playerNode.lastRenderTime,
            let playerTime = playerNode.playerTime(forNodeTime: lastRenderTime) else {
                return 0
        }
        
        return playerTime.sampleTime
    }
    
    var audioLengthSeconds: Float = 0
    
    init(withSavedUrl url: AudioURL, delegate:AudioEngineDelegate?) {
        Log.info(url.key)
        
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            Log.monitor(error.localizedDescription)
        }
        
        super.init(url: url, delegate: delegate, engineAudioFormat: audioFile?.processingFormat ?? AudioEngine.defaultEngineAudioFormat)
        
        if let file = audioFile {
            Log.debug("Audio file exists")
            audioLengthSamples = file.length
            audioFormat = file.processingFormat
            audioSampleRate = Float(audioFormat?.sampleRate ?? 44100)
            audioLengthSeconds = Float(audioLengthSamples) / audioSampleRate
            duration = Duration(audioLengthSeconds)
            bufferedSeconds = SAAudioAvailabilityRange(startingNeedle: 0, durationLoadedByNetwork: duration, predictedDurationToLoad: duration, isPlayable: true)
        } else {
            Log.monitor("Could not load downloaded file with url: \(url)")
        }
        
        doRepeatedly(timeInterval: 0.2) { [weak self] in
            guard let self = self else { return }
            
            self.updateIsPlaying()
            self.updateNeedle()
        }
        
        scheduleAudioFile()
        configureOutput()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                self.pause()
            }
            self.configureOutput()
        }
    }

    deinit {
        if let observer = routeObserver { NotificationCenter.default.removeObserver(observer) }
        bufferedOutput?.invalidate()
        engine.stop()
    }

    private func configureOutput() {
        guard #available(iOS 11.0, tvOS 11.0, *) else { return }
        let useAirPlay = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        guard useAirPlay != usesBufferedOutput else { return }

        let position = bufferedOutput?.currentTime ?? max(0, needle)
        let wasPlaying = state == .resumed
        let volume = self.volume
        bufferedOutput?.invalidate()
        bufferedOutput = nil
        playerNode.stop()
        engine.stop()
        engine.disableManualRenderingMode()

        if useAirPlay {
            do {
                let output = try AirPlayAudioOutput(engine: engine)
                output.volume = volume
                output.onFlush = { [weak self] in
                    guard let self = self, let output = self.bufferedOutput else { return }
                    self.seek(toNeedle: output.currentTime)
                }
                output.onError = { [weak self] error in self?.handleOutputError(error) }
                bufferedOutput = output
                // Volume belongs to the renderer; baking it into queued PCM delays fades.
                playerNode.volume = 1
                prepareBufferedAudio(at: position, playing: wasPlaying)
            } catch {
                handleOutputError(error)
            }
        } else {
            playerNode.volume = volume
            seek(toNeedle: position)
            if wasPlaying { super.play() }
        }
    }

    private func prepareBufferedAudio(at seconds: Double, playing: Bool) {
        guard let output = bufferedOutput, let file = audioFile else { return }
        output.invalidatePendingAudio()
        playerNode.stop()
        engine.stop()
        engine.reset()
        seekFrame = min(file.length, max(0, AVAudioFramePosition(seconds * file.processingFormat.sampleRate)))
        currentPosition = seekFrame
        let position = Double(seekFrame) / file.processingFormat.sampleRate
        let rate = sourcePlaybackRate
        output.resetTimeline(at: position, duration: duration, sourceRate: rate)
        needle = position
        state = playing ? .resumed : .suspended
        guard seekFrame < file.length else { return }

        playerNode.scheduleSegment(file, startingFrame: seekFrame, frameCount: AVAudioFrameCount(file.length - seekFrame), at: nil)
        do {
            try engine.start()
            playerNode.play()
            output.requestAudio()
            output.rate = playing ? 1 : 0
        } catch {
            handleOutputError(error)
        }
    }

    private func handleOutputError(_ error: Error) {
        Log.monitor("AirPlay output failed: \(error.localizedDescription)")
        bufferedOutput?.invalidatePendingAudio()
        state = .suspended
        playingStatus = .paused
        delegate?.didError()
    }

    override func play() {
        configureOutput()
        guard let output = bufferedOutput else {
            super.play()
            return
        }
        output.rate = 1
        state = .resumed
        updateIsPlaying()
    }

    override func pause() {
        guard let output = bufferedOutput else {
            super.pause()
            return
        }
        output.rate = 0
        needle = output.currentTime
        state = .suspended
        updateIsPlaying()
    }

    override func updateIsPlaying() {
        guard usesBufferedOutput else {
            super.updateIsPlaying()
            return
        }
        if playingStatus != .ended {
            playingStatus = state == .resumed ? .playing : .paused
        }
    }

    private var sourcePlaybackRate: Double {
        SAPlayer.shared.audioModifiers.reduce(1.0) { rate, node in
            if let node = node as? AVAudioUnitTimePitch { return rate * Double(node.rate) }
            if let node = node as? AVAudioUnitVarispeed { return rate * Double(node.rate) }
            return rate
        }
    }

    override func audioModifiersDidChange() {
        guard let output = bufferedOutput else { return }
        if state == .suspended {
            prepareBufferedAudio(at: output.currentTime, playing: false)
        } else {
            output.updateSourceRate(sourcePlaybackRate)
        }
    }
    
    private func scheduleAudioFile() {
        guard let audioFile = audioFile else { return }
        
        playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
    }
    
    private func updateNeedle() {
        if let output = bufferedOutput {
            guard state == .resumed else { return }
            needle = output.currentTime
            if needle >= duration {
                output.rate = 0
                state = .suspended
                playingStatus = .ended
            }
            return
        }
        guard engine.isRunning else { return }
        
        currentPosition = currentFrame + seekFrame
        currentPosition = max(currentPosition, 0)
        currentPosition = min(currentPosition, audioLengthSamples)
        
        if currentPosition >= audioLengthSamples {
            playerNode.stop()
            if state == .resumed {
                state = .suspended
            }
            playingStatus = .ended
        }
        
        guard audioSampleRate != 0 else {
            Log.error("Missing audio sample rate in update needle timer function!")
            return
        }
        
        needle = Double(Float(currentPosition)/audioSampleRate)
    }
    
    override func seek(toNeedle needle: Needle) {
        if usesBufferedOutput {
            prepareBufferedAudio(at: min(duration, max(0, needle)), playing: state == .resumed)
            playingStatus = state == .resumed ? .playing : .paused
            return
        }
        guard let audioFile = audioFile else {
            Log.error("did not have audio file when trying to seek")
            return
        }
        
        let playing = playerNode.isPlaying
        let seekToNeedle = needle > Needle(duration) ? Needle(duration) : needle
        
        self.needle = seekToNeedle // to tick while paused
        
        seekFrame = AVAudioFramePosition(Float(seekToNeedle) * audioSampleRate)
        seekFrame = max(seekFrame, 0)
        seekFrame = min(seekFrame, audioLengthSamples)
        currentPosition = seekFrame
        
        playerNode.stop()
        
        if currentPosition < audioLengthSamples {
            playerNode.scheduleSegment(audioFile, startingFrame: seekFrame, frameCount: AVAudioFrameCount(audioLengthSamples - seekFrame), at: nil, completionHandler: nil)
            
            if playing {
                playerNode.play()
            }
        }
    }
    
    override func invalidate() {
        if let observer = routeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeObserver = nil
        }
        bufferedOutput?.invalidate()
        bufferedOutput = nil
        super.invalidate()
    }
}

// Keep the existing iOS 10 playback path without exposing newer AVFoundation types to it.
private protocol BufferedAudioOutput: AnyObject {
    var currentTime: Double { get }
    var rate: Float { get set }
    var volume: Float { get set }
    func resetTimeline(at seconds: Double, duration: Double, sourceRate: Double)
    func updateSourceRate(_ sourceRate: Double)
    func requestAudio()
    func invalidatePendingAudio()
    func invalidate()
}

/// An output for the existing effect graph, not a second player or audio engine.
@available(iOS 11.0, tvOS 11.0, *)
private final class AirPlayAudioOutput: BufferedAudioOutput {
    private let engine: AVAudioEngine
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let buffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let outputConverter: AVAudioConverter
    private struct TimelineSegment {
        let outputTime: Double
        let sourceTime: Double
        let rate: Double

        func sourcePosition(at outputTime: Double) -> Double {
            sourceTime + max(0, outputTime - self.outputTime) * rate
        }
    }

    // Speed changes apply at the next rendered buffer, after audio already queued.
    private var timeline = [TimelineSegment(outputTime: 0, sourceTime: 0, rate: 1)]
    private let maximumBufferedSeconds = 4.0
    private var duration: Double = 0
    private var renderedFrames: Int64 = 0
    private var requestingAudio = false
    private var continuation: DispatchWorkItem?
    private var flushObserver: NSObjectProtocol?
    var onFlush: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(engine: AVAudioEngine) throws {
        self.engine = engine
        let format = AudioEngine.defaultEngineAudioFormat
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: format.channelCount, interleaved: true)!
        outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: buffer.frameCapacity)!
        outputConverter = AVAudioConverter(from: format, to: outputFormat)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: buffer.frameCapacity)
        synchronizer.addRenderer(renderer)
        flushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer, queue: .main
        ) { [weak self] _ in self?.onFlush?() }
    }

    deinit { invalidate() }

    var currentTime: Double {
        let time = CMTimebaseGetTime(synchronizer.timebase).seconds
        while timeline.count > 1 && timeline[1].outputTime <= time {
            timeline.removeFirst()
        }
        return min(duration, timeline[0].sourcePosition(at: time))
    }

    var rate: Float {
        get { synchronizer.rate }
        set { synchronizer.rate = newValue }
    }

    var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    func resetTimeline(at seconds: Double, duration: Double, sourceRate: Double) {
        self.duration = duration
        timeline = [TimelineSegment(outputTime: 0, sourceTime: seconds, rate: sourceRate)]
        renderedFrames = 0
        synchronizer.setRate(0, time: .zero)
        if #available(iOS 14.5, tvOS 14.5, *) {
            synchronizer.delaysRateChangeUntilHasSufficientMediaData = true
        }
    }

    func updateSourceRate(_ sourceRate: Double) {
        let previous = timeline[timeline.count - 1]
        guard sourceRate != previous.rate else { return }
        let time = Double(renderedFrames) / buffer.format.sampleRate
        let position = previous.sourcePosition(at: time)
        if previous.outputTime == time { timeline.removeLast() }
        timeline.append(TimelineSegment(outputTime: time, sourceTime: position, rate: sourceRate))
    }

    func requestAudio() {
        requestingAudio = true
        enqueueAudio()
    }

    func invalidatePendingAudio() {
        requestingAudio = false
        continuation?.cancel()
        continuation = nil
        synchronizer.rate = 0
        renderer.flush()
    }

    func invalidate() {
        if let observer = flushObserver {
            NotificationCenter.default.removeObserver(observer)
            flushObserver = nil
        }
        onFlush = nil
        onError = nil
        invalidatePendingAudio()
    }

    private func enqueueAudio() {
        guard requestingAudio, continuation == nil else { return }
        do {
            if let error = renderer.error { throw error }
            // Yield after a short batch so filling an AirPlay buffer cannot block controls.
            for _ in 0..<4 {
                let outputTime = Double(renderedFrames) / buffer.format.sampleRate
                let segment = timeline[timeline.count - 1]
                let remaining = (duration - segment.sourcePosition(at: outputTime)) / segment.rate
                guard remaining > 0 else {
                    requestingAudio = false
                    if #available(iOS 14.5, tvOS 14.5, *) {
                        // Short tracks can end before reaching AirPlay's preroll threshold.
                        let requestedRate = synchronizer.rate
                        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
                        synchronizer.rate = requestedRate
                    }
                    return
                }
                guard renderer.isReadyForMoreMediaData else { break }
                let clock = CMTimebaseGetTime(synchronizer.timebase).seconds
                var available = maximumBufferedSeconds - (outputTime - clock)
                if #available(iOS 14.5, tvOS 14.5, *),
                   synchronizer.rate > 0 && CMTimebaseGetRate(synchronizer.timebase) == 0 &&
                   !renderer.hasSufficientMediaDataForReliablePlaybackStart {
                    // Let the receiver request enough startup audio, even beyond the live-effects limit.
                    available = remaining
                }
                guard available > 1 / buffer.format.sampleRate else { break }
                let frames = AVAudioFrameCount(min(Double(buffer.frameCapacity), ceil(min(remaining, available) * buffer.format.sampleRate)))
                let status = try engine.renderOffline(frames, to: buffer)
                switch status {
                case .success, .insufficientDataFromInputNode:
                    if buffer.frameLength > 0 {
                        renderer.enqueue(try makeSampleBuffer())
                        renderedFrames += Int64(buffer.frameLength)
                    }
                case .cannotDoInCurrentContext:
                    break
                case .error:
                    throw NSError(domain: "SwiftAudioPlayer.AirPlay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render audio effects."])
                @unknown default:
                    throw NSError(domain: "SwiftAudioPlayer.AirPlay", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown audio rendering status."])
                }
            }
            let work = DispatchWorkItem { [weak self] in
                self?.continuation = nil
                self?.enqueueAudio()
            }
            continuation = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        } catch {
            invalidatePendingAudio()
            onError?(error)
        }
    }

    private func makeSampleBuffer() throws -> CMSampleBuffer {
        // Keep each stereo frame contiguous so the output can split buffers into packets.
        try outputConverter.convert(to: outputBuffer, from: buffer)
        let buffer = outputBuffer
        var sampleSize = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: CMTime(value: renderedFrames, timescale: CMTimeScale(buffer.format.sampleRate)),
            decodeTimeStamp: .invalid
        )
        var status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let result = sample else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        // Copy the PCM data before reusing the engine's render buffer.
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            result, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList
        )
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        status = CMSampleBufferSetDataReady(result)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return result
    }
}
