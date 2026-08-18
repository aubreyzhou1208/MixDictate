import AVFoundation
import Foundation

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

    /// 人声门限（0…1）。低于它的声音一律写成静音，不进入转写。设成 0 关闭。
    ///
    /// 这是回声消除之外的第二道闸。回声消除减掉的是「电脑正在往扬声器送的
    /// 那一路信号」，减不干净，而且它完全不做人声分离 —— 从扬声器漏回麦克风
    /// 的说话声，在模型眼里跟你说话没有任何区别。但两者有个很稳定的差别：
    /// 你的嘴离麦克风二三十厘米，视频的声音要绕一圈才回来，通常弱一个数量级。
    /// 按响度切一刀，就能把绝大部分漏音挡在外面。
    var voiceThreshold: Float = 0.05

    /// 送给模型之前，把内部静音压到最长这么久（秒）。0 = 不压。
    ///
    /// 这是"我一停顿它就给我加个句号"的解法。模型判断句子有没有说完，
    /// 最主要的依据就是停顿有多长 —— 而"想下一句怎么说"和"这句说完了"
    /// 在音频里是同一件事：一段安静。从声音里根本分不开，之前试过用
    /// 停顿时长猜，猜错的比猜对的多。
    ///
    /// 与其猜，不如把线索本身削掉：把 1.5 秒的思考停顿压成 0.35 秒，
    /// 模型看到的就只是一个正常的字间空隙，不再有理由断句。顺带音频
    /// 也变短了，推理更快。
    ///
    /// 注意它依赖人声门限 —— 门限把停顿写成真正的静音，这里才认得出来。
    var maxPauseSeconds: Double = 0.35

    /// 门限打开后的剩余保持字节数
    private var holdRemaining = 0
    /// 压在手里还没写出去的那一块，以及当时的判断。见 appendGated 里的前瞻。
    private var heldChunk: Data?
    private var heldOpen = false
    private var heldLoud = false

    /// 本次录音听到过的最大响度。跟 peak 不同，它不会被读取清零 ——
    /// 「什么都没识别出来」到底是没声音还是全被门限挡掉了，全靠它区分。
    private var loudest: Float = 0
    /// 被门限写成静音的字节数
    private var gatedBytes = 0

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private(set) var isRecording = false

    /// 语音处理单元只需要开一次。反复切换要重建音频图，没必要。
    private var voiceProcessingEnabled = false

    /// 这次会话里不再打开回声消除。见 disableEchoCancellation()。
    private var voiceProcessingBlocked = false

    /// 回声消除当前是否真的开着
    var echoCancellationActive: Bool { voiceProcessingEnabled }

    /// 最近一次采集的输入格式。排错时这是关键的一行 ——
    /// 声道数是几，直接决定了转换会不会静默地吐出全零。
    private(set) var inputFormatDescription = ""

    /// 关掉回声消除，并且这次会话里不再打开。
    ///
    /// macOS 的语音处理单元会把输入格式从单声道换成多声道（常见是 5 声道），
    /// 而 AVAudioConverter 在声道数不匹配又没有声道映射时**不会报错，
    /// 它会安静地输出全零** —— 麦克风"一切正常"却一个字都收不到。
    ///
    /// 下面已经显式设了声道映射，但不同机型和系统版本的表现不一样，
    /// 所以还要留一条自愈的路：真的录到全静音时，宁可不要回声消除，
    /// 也不能让听写整个哑掉。回声消除是锦上添花，能听见才是底线。
    func disableEchoCancellation() {
        guard !isRecording else { return }
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        voiceProcessingEnabled = false
        voiceProcessingBlocked = true
    }

    /// - Parameter cancelEcho: 打开系统的语音处理单元做回声消除。
    ///   它知道系统正在往扬声器送什么，就从麦克风信号里把那部分减掉 ——
    ///   否则你在放视频时听写，视频里的人声会被一起录进去当成你说的话。
    ///   顺带还有降噪和自动增益。
    func start(cancelEcho: Bool) throws {
        guard !isRecording else { return }

        // 必须在引擎启动前设置，而且只需要设一次
        if cancelEcho, !voiceProcessingEnabled, !voiceProcessingBlocked {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                voiceProcessingEnabled = true
            } catch {
                // 有些音频设备不支持。不该因此录不了音，退回普通采集。
                NSLog("MixDictate: 回声消除不可用，改用普通采集：%@",
                      error.localizedDescription)
            }
        }

        pcmLock.lock()
        pcm.removeAll(keepingCapacity: true)
        peak = 0
        sawSound = false
        committedOffset = 0
        lastLoudByte = 0
        holdRemaining = 0
        heldChunk = nil
        heldOpen = false
        heldLoud = false
        loudest = 0
        gatedBytes = 0
        pcmLock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw RecorderError.noInputDevice }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        // 声道数不匹配时必须显式给映射，否则 AVAudioConverter 会安静地
        // 输出全零。语音处理单元开着的时候输入常常是 5 声道，正好踩中。
        // 取前几路 —— 第 0 路就是处理过的人声。
        if inputFormat.channelCount > targetFormat.channelCount {
            converter?.channelMap = (0..<Int(targetFormat.channelCount))
                .map { NSNumber(value: $0) }
        }

        inputFormatDescription =
            "\(Int(inputFormat.sampleRate))Hz \(inputFormat.channelCount)ch"
        NSLog("MixDictate: 输入格式 %@，回声消除 %@",
              inputFormatDescription, voiceProcessingEnabled ? "开" : "关")

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        try engine.start()
        startedAt = Date()
        isRecording = true
    }

    /// 返回完整的 WAV 数据；录音太短或没声音时返回 nil。
    /// 停止录音。
    ///
    /// 返回两份：完整音频和还没定稿的尾巴。
    ///
    /// 需要完整音频，是因为分段转写为了速度牺牲了准确率 —— 每段只能看到
    /// 自己那两三秒，丢掉了上下文。所以短录音在松手时会拿完整音频重转
    /// 一遍，让最终结果享受完整上下文。分段只服务于说话过程中的实时预览。
    func stop(minimumDuration: Double) -> (full: Data, tail: Data)? {
        guard isRecording else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil

        pcmLock.lock()
        flushHeld()
        let captured = pcm
        pcmLock.unlock()

        guard duration >= minimumDuration, !captured.isEmpty else { return nil }

        // 只返回还没定稿的尾巴。前面的段落早就转过了，再转一遍纯属浪费 ——
        // "松手之后要等很久"正是这么来的。
        let tailPCM = captured.subdata(
            in: min(committedOffset, captured.count)..<captured.count
        )

        // 尾巴的空 Data 和整体的 nil 是两回事：nil = 录音太短没内容，
        // 空 Data = 录到了但全部已经定稿，尾巴没东西要转。
        let tail = tailPCM.isEmpty
            ? Data()
            : Self.makeWAV(pcm: shortenPauses(tailPCM), sampleRate: 16_000, channels: 1)

        return (
            full: Self.makeWAV(pcm: shortenPauses(captured), sampleRate: 16_000, channels: 1),
            tail: tail
        )
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

    /// 本次录音听到的最大响度（0…1）。跟人声门限一比就知道
    /// 「没识别出内容」是真没声音，还是声音全在门限以下被挡掉了。
    var loudestLevel: Float {
        pcmLock.lock()
        defer { pcmLock.unlock() }
        return loudest
    }

    /// 被人声门限写成静音的时长（秒）
    var gatedSeconds: Double {
        pcmLock.lock()
        defer { pcmLock.unlock() }
        return Double(gatedBytes) / 2.0 / 16_000.0
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
        // 这一段里一次都没越过人声门限 = 这段时间没人在说话
        let silentThroughout = lastLoudByte <= committedOffset
        if silentThroughout, pending.count >= Self.minSegmentBytes {
            // 直接定稿掉。纯静音送进模型不是没输出就是幻听，而不定稿的话
            // 未转写的部分会一直涨，后面每次刷新都越来越慢。
            committedOffset = endOffset
        }
        pcmLock.unlock()

        // 太短的片段模型只会输出噪音，不如不发
        guard pending.count >= 16_000 else { return nil }  // 约 0.5 秒
        guard !silentThroughout else { return nil }

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
            Self.makeWAV(pcm: shortenPauses(pending), sampleRate: 16_000, channels: 1),
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

    /// 判断「麦克风到底有没有在工作」的下限。跟人声门限是两回事：
    /// 这个只回答有没有信号，那个回答这信号是不是你在说话。
    private static let noiseFloor: Float = 0.01
    /// 门限开了之后至少保持 0.4 秒。说话本身字与字之间就有停顿，
    /// 只按瞬时响度开合会把句子剁碎，听上去像在吞字。
    private static let gateHoldBytes = Int(0.4 * 16_000) * 2

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
        // 用 magnitude 而不是 abs：Int16.min 没有对应的正数，abs 会直接 trap，
        // 而满量程的负样本在录音里是真会出现的。
        var framePeak: UInt16 = 0
        for index in 0..<frames {
            let sample = channel[0][index].magnitude
            if sample > framePeak { framePeak = sample }
        }

        let byteCount = frames * MemoryLayout<Int16>.size
        let chunk = channel[0].withMemoryRebound(to: UInt8.self, capacity: byteCount) {
            Data(bytes: $0, count: byteCount)
        }
        let level = min(1, Float(framePeak) / Float(Int16.max))

        pcmLock.lock()
        peak = max(peak, level)
        loudest = max(loudest, level)
        if level > Self.noiseFloor { sawSound = true }
        appendGated(chunk, level: level)
        pcmLock.unlock()
    }

    // MARK: - 人声门限

    /// 把一块音频写进缓冲区，低于人声门限的部分换成静音。
    ///
    /// 门限带保持时间，还带一块的前瞻：只按瞬时响度开合，词头的起音和
    /// 词尾的余音都会被削掉。前瞻的做法是每块都先压在手里，等下一块到了
    /// 再决定放不放行 —— 下一块开门就说明起音落在了这一块的末尾。
    /// 代价是恒定延后一块（约 0.1 秒），松手时 flushHeld() 补上。
    ///
    /// 必须持有 pcmLock。
    private func appendGated(_ chunk: Data, level: Float) {
        guard voiceThreshold > 0 else {
            write(chunk, open: true, loud: level > Self.noiseFloor)
            return
        }

        let loud = level >= voiceThreshold
        if loud {
            holdRemaining = Self.gateHoldBytes
        } else {
            holdRemaining = max(0, holdRemaining - chunk.count)
        }
        let openNow = loud || holdRemaining > 0

        if let held = heldChunk {
            write(held, open: heldOpen || loud, loud: heldLoud)
        }
        heldChunk = chunk
        heldOpen = openNow
        heldLoud = loud
    }

    /// 必须持有 pcmLock。
    private func write(_ chunk: Data, open: Bool, loud: Bool) {
        if open {
            pcm.append(chunk)
        } else {
            pcm.append(Data(count: chunk.count))
            gatedBytes += chunk.count
        }
        if loud { lastLoudByte = pcm.count }
    }

    /// 把还压在手里的那一块写出去。停止录音时必须调用，
    /// 否则最后约 0.1 秒会丢 —— 正好是最后一个字的尾音。
    ///
    /// 必须持有 pcmLock。
    private func flushHeld() {
        guard let held = heldChunk else { return }
        heldChunk = nil
        write(held, open: heldOpen, loud: heldLoud)
    }

    // MARK: - 压短停顿

    /// 把超过 maxPauseSeconds 的静音游程截短到 maxPauseSeconds。
    ///
    /// 只动送给模型的那份，不动缓冲区本身 —— committedOffset / lastLoudByte
    /// 都是按未压缩的偏移算的，动了缓冲区那套坐标全废。
    private func shortenPauses(_ pcm: Data) -> Data {
        let maxRunBytes = Int(maxPauseSeconds * 16_000) * 2
        guard maxRunBytes > 0 else { return pcm }
        return Self.compressSilence(pcm, maxRunBytes: maxRunBytes)
    }

    /// 低于这个幅度就算静音。对应 noiseFloor（0.01）。
    /// 门限开着时停顿是精确的零，这个阈值顺带也能认出没开门限时的安静环境。
    private static let silenceCeiling = UInt16(Float(Int16.max) * noiseFloor)

    private static func compressSilence(_ pcm: Data, maxRunBytes: Int) -> Data {
        let maxRunSamples = maxRunBytes / 2
        let total = pcm.count / 2
        guard maxRunSamples > 0, total > maxRunSamples else { return pcm }

        var out = Data(capacity: pcm.count)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            guard let base = samples.baseAddress else { return }

            // 按"静音/有声"分游程，静音游程超长就只写前 maxRunSamples 个。
            func emit(from start: Int, to end: Int, silent: Bool) {
                let count = silent ? min(end - start, maxRunSamples) : end - start
                guard count > 0 else { return }
                out.append(UnsafeBufferPointer(start: base + start, count: count))
            }

            var runStart = 0
            var runIsSilent = samples[0].magnitude <= silenceCeiling
            var index = 1
            while index < total {
                let silent = samples[index].magnitude <= silenceCeiling
                if silent != runIsSilent {
                    emit(from: runStart, to: index, silent: runIsSilent)
                    runStart = index
                    runIsSilent = silent
                }
                index += 1
            }
            emit(from: runStart, to: total, silent: runIsSilent)
        }
        return out
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
