import AVFoundation

enum RecorderError: Error {
    case noInputDevice
}

/// 录麦克风，重采样到 16 kHz 单声道，停止时吐出一段 WAV。
///
/// Qwen3-ASR 内部就是按 16 kHz 单声道处理的，在客户端先转好可以少一次
/// 服务端重采样，也让上传的数据小很多。
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pcm = Data()
    private var startedAt: Date?

    /// tap 回调跑在实时音频线程上，stop() 在主线程读同一个缓冲区 ——
    /// 没有锁就是数据竞争，表现为偶发的截断或崩溃。
    private let pcmLock = NSLock()

    /// 上次读取以来的最大音量。用来回答一个很基础但很关键的问题：
    /// 麦克风到底有没有在给我们声音？没权限时 macOS 不会报错，
    /// 只会安静地送来一串零 —— 不显式检查就完全看不出区别。
    private var peak: Float = 0

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private(set) var isRecording = false

    func start() throws {
        guard !isRecording else { return }

        pcmLock.lock()
        pcm.removeAll(keepingCapacity: true)
        peak = 0
        pcmLock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw RecorderError.noInputDevice }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        try engine.start()
        startedAt = Date()
        isRecording = true
    }

    /// 返回完整的 WAV 数据；录音太短或没声音时返回 nil。
    func stop(minimumDuration: Double) -> Data? {
        guard isRecording else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil

        pcmLock.lock()
        let captured = pcm
        pcmLock.unlock()

        guard duration >= minimumDuration, !captured.isEmpty else { return nil }
        return Self.makeWAV(pcm: captured, sampleRate: 16_000, channels: 1)
    }

    /// 读取并清零峰值音量（0…1）。持续为 0 就说明麦克风没在工作。
    func consumePeakLevel() -> Float {
        pcmLock.lock()
        let value = peak
        peak = 0
        pcmLock.unlock()
        return value
    }

    /// 录音进行中取一份当前音频的快照，用来做实时转写。
    /// 不停止录音、不清空缓冲 —— 每次快照都是"从开始到现在"的完整音频。
    func snapshotWAV() -> Data? {
        pcmLock.lock()
        let captured = pcm
        pcmLock.unlock()

        // 太短的片段模型只会输出噪音，不如不发
        guard captured.count >= 16_000 else { return nil }  // 约 0.5 秒
        return Self.makeWAV(pcm: captured, sampleRate: 16_000, channels: 1)
    }

    // MARK: - 重采样

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        // 输入块只能供一次数据，第二次要报 .noDataNow，否则 convert 会一直等
        var delivered = false
        var conversionError: NSError?
        _ = converter.convert(to: out, error: &conversionError) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              out.frameLength > 0,
              let channel = out.int16ChannelData
        else { return }

        let frames = Int(out.frameLength)
        var framePeak: Int16 = 0
        for index in 0..<frames {
            let sample = abs(channel[0][index])
            if sample > framePeak { framePeak = sample }
        }

        let byteCount = frames * MemoryLayout<Int16>.size
        pcmLock.lock()
        channel[0].withMemoryRebound(to: UInt8.self, capacity: byteCount) { bytes in
            pcm.append(bytes, count: byteCount)
        }
        peak = max(peak, Float(framePeak) / Float(Int16.max))
        pcmLock.unlock()
    }

    // MARK: - WAV 封装

    private static func makeWAV(pcm: Data, sampleRate: Int, channels: Int) -> Data {
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var header = Data()
        func ascii(_ s: String) { header.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { header.append(contentsOf: $0) } }

        ascii("RIFF")
        u32(36 + pcm.count)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)              // PCM 子块大小
        u16(1)               // 格式 = PCM
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        ascii("data")
        u32(pcm.count)

        return header + pcm
    }
}
