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
    /// NS-WSG slot card (experimental) — mixed into the render callback.
    let wsg = WSGDevice()

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
    private var lastToggleTime: UInt64 = 0
    private var lastToggleCycles: UInt64 = 0
    private var lpState: Float = 0.0
    private var speakerToggleActive: Bool = false
    private var toggleHalfPeriodSamples: Int = 0
    private var toggleHalfPeriodF: Double = 0.0
    private var sqPhaseF: Double = 0.0
    private var timebaseNumer: UInt64 = 1
    private var timebaseDenom: UInt64 = 1

    // Square-wave synthesis state (render thread only)
    private var sqPhase: Int = 0
    private var sqPolarity: Float = 1.0

    // Decay: stop producing tone after ~50ms of no toggles
    private var samplesSinceLastToggle: Int = 0
    private let decayThreshold: Int = 700  // ~16ms: sustains tones, trims tails

    // Lock for thread-safe state access
    private let lock = NSLock()

    // Engine pause/resume for silence detection
    private var engineRunning = true
    private var lastAudioActivity: UInt64 = mach_absolute_time()

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebaseNumer = UInt64(info.numer)
        timebaseDenom = UInt64(info.denom)
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
            let halfPeriodF = self.toggleHalfPeriodF
            var samplesSinceToggle = self.samplesSinceLastToggle
            self.lock.unlock()

            let beepOmega = 2.0 * Double.pi * self.beepFrequency / self.sampleRate

            for buffer in ablPointer {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                var beepLeft = beepRemaining

                for frame in 0..<frames {
                    var sample: Float = 0.0

                    // Fixed-frequency beep (port 0x83 IN)
                    if beepLeft > 0 {
                        let raw = sin(beepPhase) > 0 ? Float(0.6) : Float(-0.6)
                        // Envelope: fade in/out over 100 samples
                        let env: Float
                        let totalBeep = Int(self.sampleRate * 0.25)
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

                    // Programmable speaker tone (I/O control register bit 6 toggling):
                    // synthesize a square wave at the measured toggle rate.
                    if toggleActive && halfPeriod > 0 && samplesSinceToggle < self.decayThreshold {
                        sample += 0.30 * self.sqPolarity
                        self.sqPhaseF += 1.0
                        if self.sqPhaseF >= halfPeriodF {
                            self.sqPhaseF -= halfPeriodF   // fractional carry: exact pitch
                            if self.sqPhaseF >= halfPeriodF {
                                self.sqPhaseF = 0          // period just shrank (sweep):
                            }                              // resync instead of thrashing
                            self.sqPolarity = -self.sqPolarity
                        }
                    }

                    samplesSinceToggle += 1
                    // one-pole lowpass ~ speaker-cone warmth
                    self.lpState += 0.45 * (sample - self.lpState)
                    data[frame] = self.lpState
                }

                // NS-WSG voices mix in unfiltered (the card has its own DAC
                // path on real hardware, not the speaker cone)
                self.wsg.renderAdd(into: data, frames: frames, sampleRate: self.sampleRate)
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
        engine.mainMixerNode.outputVolume = 0.7

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
        if ProcessInfo.processInfo.environment["NORTHMAC_NO_AUDIO"] != nil { return }
        ensureEngineRunning()
        lock.lock()
        beepSamplesRemaining = Int(sampleRate * 0.25)  // 250ms beep
        beepPhase = 0.0
        lastAudioActivity = mach_absolute_time()
        lock.unlock()
    }

    /// Register write reaching the NS-WSG card: keep the engine awake.
    func wsgActivity() {
        if ProcessInfo.processInfo.environment["NORTHMAC_NO_AUDIO"] != nil { return }
        ensureEngineRunning()
        lock.lock()
        lastAudioActivity = mach_absolute_time()
        lock.unlock()
    }

    /// Handle speaker data toggle from I/O control register bit 6.
    /// Called from the emulator thread every time port 0xF8 is written.
    /// The Z80 software controls tone frequency by varying the toggle rate.
    func speakerToggle(high: Bool, cycles: UInt64 = 0) {
        if ProcessInfo.processInfo.environment["NORTHMAC_NO_AUDIO"] != nil { return }
        lock.lock()
        let wasHigh = speakerState
        speakerState = high

        if wasHigh != high {
            // Measure the CPU cycles between toggles and convert to audio
            // samples (4 MHz / 44100 Hz = 90.7 cycles per sample) — exact,
            // jitter-free pitch regardless of host thread scheduling.
            if cycles > lastToggleCycles && lastToggleCycles > 0 {
                let dc = cycles - lastToggleCycles
                let hpF = Double(dc) * (sampleRate / 4_000_000.0)
                if hpF >= 1.5 && hpF <= 4000.0 {
                    toggleHalfPeriodSamples = Int(hpF)
                    toggleHalfPeriodF = hpF
                }
            }
            lastToggleCycles = cycles
            samplesSinceLastToggle = 0
            speakerToggleActive = true
            lastAudioActivity = mach_absolute_time()

            // Resume engine if it was paused for silence
            if !engineRunning {
                lock.unlock()
                ensureEngineRunning()
                return
            }
        }

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

    /// Called periodically from the emulator to pause engine during sustained silence.
    /// Uses wall-clock time (not frame count) so turbo mode doesn't cause premature pausing.
    func checkSilence() {
        lock.lock()
        let isSilent = beepSamplesRemaining <= 0 &&
                        samplesSinceLastToggle > decayThreshold &&
                        !wsg.active
        let lastActivity = lastAudioActivity
        lock.unlock()

        if isSilent && engineRunning {
            // Check wall-clock time since last audio activity
            let now = mach_absolute_time()
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            let elapsedNs = Double(now - lastActivity) * Double(info.numer) / Double(info.denom)
            if elapsedNs > 2_000_000_000 {  // 2 seconds of real silence
                audioEngine?.pause()
                engineRunning = false
            }
        }
    }

    /// Half-period is now measured from wall-clock toggle spacing; the old
    /// cycle-derived sample counter is gone. Kept as a no-op for callers.
    func syncSampleCounter(cpuCycles: UInt) {
    }

    func shutdown() {
        sourceNode = nil
        audioEngine?.stop()
        audioEngine = nil
    }
}
