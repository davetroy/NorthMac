import Foundation
import AVFoundation

/// Audio system for the NorthStar Advantage emulator.
///
/// The Advantage speaker is driven by software toggling I/O control register bit 6
/// at controlled rates — the toggle frequency determines the tone pitch. Port 0x83 IN
/// triggers a fixed beep via the boot ROM's beep routine.
///
/// Implementation uses AVAudioSourceNode for real-time audio generation driven by
/// speaker state, producing authentic square-wave tones at whatever frequency the
/// Z80 software programs.
final class AudioSystem {
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private let sampleRate: Double = 44100.0

    // Speaker state — written from emulator thread, read from audio render thread
    private var speakerState: Bool = false

    // Beep state: when > 0, a fixed-frequency beep is playing
    private var beepSamplesRemaining: Int = 0
    private var beepPhase: Double = 0.0
    private let beepFrequency: Double = 1920.0  // NorthStar boot beep ~1920Hz

    // Speaker toggle tracking for frequency-derived tone generation
    private var lastToggleSample: Int = 0
    private var currentSample: Int = 0
    private var speakerToggleActive: Bool = false
    private var toggleHalfPeriodSamples: Int = 0

    // Decay: stop producing tone after ~50ms of no toggles
    private var samplesSinceLastToggle: Int = 0
    private let decayThreshold: Int = 2205  // ~50ms at 44100Hz

    // Lock for thread-safe state access
    private let lock = NSLock()

    // Engine pause/resume for silence detection
    private var engineRunning = true
    private var silentFrames: Int = 0
    private let silencePauseThreshold: Int = 44100  // ~1 second of silence before pausing

    init() {
        setupAudioEngine()
    }

    private func setupAudioEngine() {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            self.lock.lock()
            let beepRemaining = self.beepSamplesRemaining
            var beepPhase = self.beepPhase
            let toggleActive = self.speakerToggleActive
            let halfPeriod = self.toggleHalfPeriodSamples
            var samplesSinceToggle = self.samplesSinceLastToggle
            let speakerHigh = self.speakerState
            self.lock.unlock()

            let beepOmega = 2.0 * Double.pi * self.beepFrequency / self.sampleRate

            for buffer in ablPointer {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                var beepLeft = beepRemaining

                for frame in 0..<frames {
                    var sample: Float = 0.0

                    // Fixed-frequency beep (port 0x83 IN)
                    if beepLeft > 0 {
                        let raw = sin(beepPhase) > 0 ? Float(0.35) : Float(-0.35)
                        // Envelope: fade in/out over 100 samples
                        let env: Float
                        let totalBeep = Int(self.sampleRate * 0.15)
                        let pos = totalBeep - beepLeft
                        if pos < 100 {
                            env = Float(pos) / 100.0
                        } else if beepLeft < 100 {
                            env = Float(beepLeft) / 100.0
                        } else {
                            env = 1.0
                        }
                        sample += raw * env
                        beepPhase += beepOmega
                        beepLeft -= 1
                    }

                    // Programmable speaker tone (I/O control register bit 6 toggling)
                    if toggleActive && halfPeriod > 0 && samplesSinceToggle < self.decayThreshold {
                        // Reconstruct square wave from toggle half-period
                        let amplitude: Float = speakerHigh ? 0.30 : -0.30
                        sample += amplitude
                    }

                    samplesSinceToggle += 1
                    data[frame] = sample
                }
            }

            self.lock.lock()
            self.beepSamplesRemaining = max(0, beepRemaining - frames)
            self.beepPhase = beepPhase
            self.samplesSinceLastToggle = samplesSinceToggle
            self.lock.unlock()

            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.3

        do {
            try engine.start()
            self.audioEngine = engine
            self.sourceNode = source
        } catch {
            NSLog("AudioSystem: failed to start audio engine: %@", error.localizedDescription)
        }
    }

    /// Generate a standard beep (called on port 0x83 IN from boot ROM)
    func beep() {
        ensureEngineRunning()
        lock.lock()
        beepSamplesRemaining = Int(sampleRate * 0.15)  // 150ms beep
        beepPhase = 0.0
        lock.unlock()
    }

    /// Handle speaker data toggle from I/O control register bit 6.
    /// Called from the emulator thread every time port 0xF8 is written.
    /// The Z80 software controls tone frequency by varying the toggle rate.
    func speakerToggle(high: Bool) {
        lock.lock()
        let wasHigh = speakerState
        speakerState = high

        if wasHigh != high {
            // Measure half-period in audio samples
            let now = currentSample
            if lastToggleSample > 0 {
                toggleHalfPeriodSamples = now - lastToggleSample
            }
            lastToggleSample = now
            samplesSinceLastToggle = 0
            speakerToggleActive = true

            // Resume engine if it was paused for silence
            if !engineRunning {
                lock.unlock()
                ensureEngineRunning()
                return
            }
        }

        currentSample += 1
        lock.unlock()
    }

    /// Resume the audio engine if it was paused
    private func ensureEngineRunning() {
        guard !engineRunning, let engine = audioEngine else { return }
        do {
            try engine.start()
            engineRunning = true
        } catch {
            NSLog("AudioSystem: failed to resume: %@", error.localizedDescription)
        }
    }

    /// Called periodically from the emulator to pause engine during sustained silence
    func checkSilence() {
        lock.lock()
        let isSilent = beepSamplesRemaining <= 0 &&
                        samplesSinceLastToggle > decayThreshold
        lock.unlock()

        if isSilent && engineRunning {
            silentFrames += 1
            if silentFrames > 60 {  // ~1 second at 60fps
                audioEngine?.pause()
                engineRunning = false
                silentFrames = 0
            }
        } else {
            silentFrames = 0
        }
    }

    /// Called periodically from emulator to sync sample counter with real time
    func syncSampleCounter(cpuCycles: UInt) {
        lock.lock()
        // 4MHz CPU / 44100Hz audio ≈ 90.7 cycles per audio sample
        currentSample = Int(cpuCycles / 91)
        lock.unlock()
    }

    func shutdown() {
        sourceNode = nil
        audioEngine?.stop()
        audioEngine = nil
    }
}
