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

    /// 本次录音有没有收到过非静音的样本。跟 peak 不同，这个不会被读取清零。
    /// 放在录音器里而不是界面层：原来它是在浮层的定时器里维护的，
    /// 一旦用户关掉浮层，这个标志永远是 false，会误报「没有听到声音」。
    private var sawSound = false

    /// 已定稿音频的结束位置。这之前的部分转写过一次就不再碰。
    ///
    /// 没有它的话，每次刷新都要重转"从开头到现在"的整段 —— 说 30 秒时
    /// 每次刷新转 30 秒，松手后再转一遍 30 秒，开销随时长平方级恶化。
    private var committedOffset = 0

    /// 最后一次检测到人声的位置。用来找停顿：这个位置到缓冲区末尾的距离
    /// 就是当前的静音时长，够长就说明可以在这里切一刀。
    private var lastLoudByte = 0

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
        sawSound = false
        committedOffset = 0
        lastLoudByte = 0
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

        // 只返回还没定稿的尾巴。前面的段落早就转过了，再转一遍纯属浪费 ——
        // "松手之后要等很久"正是这么来的。
        let tail = captured.subdata(in: min(committedOffset, captured.count)..<captured.count)

        // 空 Data 和 nil 是两回事：nil = 录音太短没内容，
        // 空 Data = 录到了但全部已经定稿，尾巴没东西要转。
        guard !tail.isEmpty else { return Data() }
        return Self.makeWAV(pcm: tail, sampleRate: 16_000, channels: 1)
    }

    /// 未定稿那一段的时长（秒）。刷新间隔按它算，而不是按总时长 ——
    /// 单次推理的开销只跟这一段有关。
    var pendingSeconds: Double {
        pcmLock.lock()
        defer { pcmLock.unlock() }
        return Double(pcm.count - committedOffset) / 2.0 / 16_000.0
    }

    /// 目前已录到的字节数。用来判断转写完成后音频有没有继续增长。
    var capturedBytes: Int {
        pcmLock.lock()
        defer { pcmLock.unlock() }
        return pcm.count
    }

    /// 目前已录到的时长（秒）。
    var capturedSeconds: Double {
        pcmLock.lock()
        defer { pcmLock.unlock() }
        return Double(pcm.count) / 2.0 / 16_000.0
    }

    /// 本次录音是否听到过真实声音。全程为 false 基本就是麦克风没工作。
    var heardSound: Bool {
        pcmLock.lock()
        defer { pcmLock.unlock() }
        return sawSound
    }

    /// 读取并清零峰值音量（0…1）。给浮层做实时提示用。
    func consumePeakLevel() -> Float {
        pcmLock.lock()
        let value = peak
        peak = 0
        pcmLock.unlock()
        return value
    }

    /// 未定稿那一段的快照：只包含上次定稿之后录到的音频。
    ///
    /// 返回的 endOffset 要原样传回 commit(upTo:)。不能事后用"当前长度"
    /// 代替 —— 转写要花时间，那期间用户还在说，长度早变了，
    /// 用新长度定稿会把没转过的音频一起标记成已完成，直接丢字。
    enum Boundary {
        /// 说话人停顿了。带上停顿时长 —— 停多久很关键：
        /// 停一秒多可能只是在想词，停两秒多才多半是真说完了一句。
        case pause(seconds: Double)
        /// 一直不停顿，按长度硬切。**一定切在句子中间。**
        case lengthCap
    }

    func pendingSnapshot() -> (wav: Data, endOffset: Int, boundary: Boundary?)? {
        pcmLock.lock()
        let pending = pcm.subdata(in: committedOffset..<pcm.count)
        let endOffset = pcm.count
        let silenceBytes = pcm.count - lastLoudByte
        pcmLock.unlock()

        // 太短的片段模型只会输出噪音，不如不发
        guard pending.count >= 16_000 else { return nil }  // 约 0.5 秒

        // 末尾静音够长 = 说话人停顿了，可以在这里切一刀。
        // 切在停顿处而不是随便切，是为了不把一个词劈成两半。
        // 一直不停顿的话段落会越长越慢，所以也按长度强制切一刀。
        // 但要把两种切法区分开：按停顿切的地方多半是句子结束，按长度硬切的
        // 一定在句子中间 —— 后者不能保留模型补出来的句号。
        let boundary: Boundary?
        if silenceBytes >= Self.pauseBytes && pending.count >= Self.minSegmentBytes {
            boundary = .pause(seconds: Double(silenceBytes) / 2.0 / 16_000.0)
        } else if pending.count >= Self.maxSegmentBytes {
            boundary = .lengthCap
        } else {
            boundary = nil
        }

        return (
            Self.makeWAV(pcm: pending, sampleRate: 16_000, channels: 1),
            endOffset,
            boundary
        )
    }

    /// 把 endOffset 之前的音频标记为已定稿，以后不再转写。
    func commit(upTo endOffset: Int) {
        pcmLock.lock()
        committedOffset = max(committedOffset, min(endOffset, pcm.count))
        pcmLock.unlock()
    }

    /// 1 秒静音才算一次停顿。
    ///
    /// 原来是 0.6 秒，太敏感了：说话时想下一句该怎么讲，很容易停顿半秒多，
    /// 那不是句子结束。切在那里模型会补一个句号，句子就被硬生生断开了。
    private static let pauseBytes = Int(1.0 * 16_000) * 2
    /// 段落至少要有 1.5 秒，否则切得太碎反而拖慢
    private static let minSegmentBytes = Int(1.5 * 16_000) * 2
    /// 段落上限 8 秒。到了就强制切，保证单次推理耗时有天花板。
    private static let maxSegmentBytes = Int(8.0 * 16_000) * 2

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
        let level = Float(framePeak) / Float(Int16.max)
        peak = max(peak, level)
        if level > 0.01 {
            sawSound = true
            lastLoudByte = pcm.count
        }
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
