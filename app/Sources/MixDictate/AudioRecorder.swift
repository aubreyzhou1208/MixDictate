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

    /// 最后一次**越过人声门限**的位置。用来找停顿：这个位置到缓冲区末尾
    /// 的距离就是当前的静音时长，够长就说明可以在这里切一刀。
    private var lastLoudByte = 0

    /// 最后一次**听到任何声音**的位置（只要高过噪声底）。
    ///
    /// 必须跟 lastLoudByte 分开记。判断"这一段要不要送去转写"如果用
    /// lastLoudByte，那么"你说话太轻没越过门限"和"这段真的没人说话"
    /// 就变成了同一件事 —— 于是你小声说的那一整段会被直接跳过，
    /// 连转写请求都不发，字就这么没了。
    private var lastSoundByte = 0

    /// 人声门限（0…1）。低于它的声音一律写成静音，不进入转写。设成 0 关闭。
    ///
    /// 这是回声消除之外的第二道闸。回声消除减掉的是「电脑正在往扬声器送的
    /// 那一路信号」，减不干净，而且它完全不做人声分离 —— 从扬声器漏回麦克风
    /// 的说话声，在模型眼里跟你说话没有任何区别。但两者有个很稳定的差别：
    /// 你的嘴离麦克风二三十厘米，视频的声音要绕一圈才回来，通常弱一个数量级。
    /// 按响度切一刀，就能把绝大部分漏音挡在外面。
    ///
    /// **默认值必须定在"绝不吃字"那一侧。** 正常说话峰值大约 0.2–0.6，
    /// 而轻声字、词尾、一个词的第二个音节常常只有 0.02–0.06 ——
    /// 门限设 0.05 会正好切在字的中间，把字吃掉。
    /// 挡不住外放只是没帮上忙，吃掉字是把事情弄坏了，两者代价不对等。
    var voiceThreshold: Float = 0.02

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
    /// 压在手里还没写出去的那几块。见 appendGated 里的前瞻。
    private struct HeldChunk {
        var data: Data
        var open: Bool
        var loud: Bool
        var level: Float
    }
    private var held: [HeldChunk] = []

    /// "门限挡掉了有声音的内容"这条只提醒一次。每块都打的话，
    /// 一秒钟十几行，真正有用的日志会被淹掉。
    private var warnedAboutGating = false

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
    /// 提前把输入设备打开好。**不开始录音，不亮麦克风指示灯。**
    ///
    /// 第一次访问 engine.inputNode 会去打开 HAL 输入设备，那是启动里最慢的
    /// 一步。放在 App 启动时做掉，按下说话键之后就只剩装 tap 和 start()。
    ///
    /// 针对的是"刚按下就说话，前面几个字没录到" —— 那几十毫秒里声音是
    /// 真的没进来，事后没有任何办法补回来。
    func prewarm() {
        guard !isRecording else { return }
        _ = engine.inputNode.outputFormat(forBus: 0)
        engine.prepare()
    }

    func start(cancelEcho: Bool) throws {
        guard !isRecording else { return }
        let began = Date()

        // 必须在引擎启动前设置
        let wantsEcho = cancelEcho && !voiceProcessingBlocked
        if wantsEcho, !voiceProcessingEnabled {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                voiceProcessingEnabled = true
            } catch {
                // 有些音频设备不支持。不该因此录不了音，退回普通采集。
                NSLog("MixDictate: 回声消除不可用，改用普通采集：%@",
                      error.localizedDescription)
            }
        } else if !wantsEcho, voiceProcessingEnabled {
            // 关掉必须是主动的，不能只是"下次不再打开"。
            // 语音处理单元只要还活着，macOS 就一直把系统里其他声音压低
            // （跟通话中一样）—— 用户会发现"整台电脑的音量都变小了"，
            // 而且根本想不到是听写工具干的。
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            voiceProcessingEnabled = false
            NSLog("MixDictate: 已关闭回声消除，系统音量压低随之解除")
        }

        pcmLock.lock()
        pcm.removeAll(keepingCapacity: true)
        peak = 0
        sawSound = false
        committedOffset = 0
        lastLoudByte = 0
        lastSoundByte = 0
        holdRemaining = 0
        held.removeAll(keepingCapacity: true)
        warnedAboutGating = false
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

        // 这段时间里的声音是真的没被录到。量出来才知道"前面的字没了"
        // 是引擎慢，还是别的原因 —— 猜是没用的。
        let elapsed = Date().timeIntervalSince(began) * 1000
        if elapsed > 60 {
            NSLog("MixDictate: 录音启动花了 %.0f 毫秒 —— 这期间说的话录不到", elapsed)
        } else {
            NSLog("MixDictate: 录音启动 %.0f 毫秒", elapsed)
        }
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
        // 判据是"有没有听到声音"，不是"有没有越过门限"。
        // 用门限判的话，说得轻的那一整段会被当成没人说话直接跳过 ——
        // 那不是省了一次推理，那是把字丢了。
        let silentThroughout = lastSoundByte <= committedOffset
        if silentThroughout, pending.count >= Self.minSegmentBytes {
            // 直接定稿掉。纯静音送进模型不是没输出就是幻听，而不定稿的话
            // 未转写的部分会一直涨，后面每次刷新都越来越慢。
            committedOffset = endOffset
        }
        // 前瞻还压在手里、没写进 pcm 的那几块。它们是**最新**的音频，
        // 也就是你刚说出口的那个字。见下面为什么只在没有边界时才带上。
        let heldTail = held.reduce(into: Data()) { $0.append($1.data) }
        pcmLock.unlock()

        // 太短的片段模型只会输出噪音，不如不发
        guard pending.count >= Self.minPartialBytes else { return nil }
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

        // 只在**没有边界**、也就是纯预览的时候，把前瞻压着的那几块也带上。
        //
        // 为什么要带：那几块是你刚说出口的音频，还没写进 pcm。不带的话
        // 实时显示永远落后一个前瞻的长度 —— 表现就是"最后一个字要等松手
        // 才出现"。前瞻加长到三块之后这个滞后被放大了三倍。
        //
        // 为什么有边界时不带：带了的话，转写覆盖的范围比 endOffset 更远，
        // 而定稿只定到 endOffset —— 多出来那截会在下一段里被再转一次，
        // 于是重复出字。预览不定稿，所以没有这个问题。
        let audio = boundary == nil ? pending + heldTail : pending

        return (
            Self.makeWAV(pcm: shortenPauses(audio), sampleRate: 16_000, channels: 1),
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
    /// 中间结果最少要有 0.25 秒才发。
    ///
    /// 原来是 0.5 秒，意味着**最新的半秒钟永远不参与实时显示** ——
    /// 正好是你刚说完的那个字。短片段模型确实容易输出噪音，但预览的噪音
    /// 下一轮就被改掉了，而"最后一个字迟迟不出现"是每一句都能看见的。
    private static let minPartialBytes = Int(0.25 * 16_000) * 2
    /// 段落至少要有 1.5 秒，否则切得太碎反而拖慢
    private static let minSegmentBytes = Int(1.5 * 16_000) * 2
    /// 段落上限 8 秒。到了就强制切，保证单次推理耗时有天花板。
    private static let maxSegmentBytes = Int(8.0 * 16_000) * 2

    /// 判断「麦克风到底有没有在工作」的下限。跟人声门限是两回事：
    /// 这个只回答有没有信号，那个回答这信号是不是你在说话。
    private static let noiseFloor: Float = 0.01
    /// 门限开了之后至少保持 0.8 秒。
    ///
    /// 原来是 0.4 秒，不够 —— 说话时词与词之间 0.2–0.6 秒的停顿很常见，
    /// 停顿一超过保持时间，下一个词的起音就只剩前瞻那点保护了。
    private static let gateHoldBytes = Int(0.8 * 16_000) * 2

    /// 关门的阈值是开门阈值的这个比例。**回滞**：越过门限才开门，
    /// 但要掉到远低于门限才关门。
    ///
    /// 开关用同一个阈值是这个门限第一版最大的毛病：语音的响度一直在起伏，
    /// 一个字的尾音掉到门限以下再回来，中间那截就被写成静音了 ——
    /// 表现成"句子中间少了一两个字"。
    private static let closeRatio: Float = 0.35

    /// 前瞻多少块。起音是渐强的，只前瞻一块（约 85 毫秒）挡不住 ——
    /// 一个字的起音爬升常常比这长。
    private static let lookaheadBlocks = 3

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
            write(chunk, open: true, loud: level > Self.noiseFloor, level: level)
            return
        }

        // 回滞：越过门限才开门，但要掉到远低于门限才关门。
        // 语音的响度一直在起伏，开关用同一个阈值的话，一个字的尾音
        // 掉下去再回来，中间那截就被写成静音了。
        let loud = level >= voiceThreshold
        let stillSpeaking = level >= voiceThreshold * Self.closeRatio

        if loud {
            holdRemaining = Self.gateHoldBytes
        } else if !stillSpeaking {
            holdRemaining = max(0, holdRemaining - chunk.count)
        }
        // 落在回滞区间里（比关门线高、比开门线低）时保持不变 ——
        // 那多半是一个字还没说完，不该开始倒计时关门。
        let openNow = stillSpeaking && holdRemaining > 0 || loud

        held.append(HeldChunk(data: chunk, open: openNow, loud: loud, level: level))

        // 前瞻：攒够几块再把最老的那块写出去。后面只要有一块开门，
        // 前面这几块就一起放行 —— 起音是渐强的，最先那一点最容易被削掉。
        guard held.count > Self.lookaheadBlocks else { return }
        let oldest = held.removeFirst()
        let laterOpens = held.contains { $0.open }
        write(
            oldest.data,
            open: oldest.open || laterOpens,
            loud: oldest.loud,
            level: oldest.level
        )
    }

    /// 必须持有 pcmLock。
    private func write(_ chunk: Data, open: Bool, loud: Bool, level: Float) {
        let audible = level > Self.noiseFloor

        if open {
            pcm.append(chunk)
        } else {
            pcm.append(Data(count: chunk.count))
            gatedBytes += chunk.count
            // 挡掉有声音的内容就说明门限设高了。以前这件事完全看不见，
            // 表现只是"句子里少了几个字" —— 最难查的那一类。
            if audible, !warnedAboutGating {
                warnedAboutGating = true
                NSLog("MixDictate: 门限挡掉了有声音的音频（峰值 %.3f，门限 %.3f）——"
                      + " 说得轻的字可能会丢，考虑调低 voiceThreshold",
                      level, voiceThreshold)
            }
        }

        if loud { lastLoudByte = pcm.count }
        if audible { lastSoundByte = pcm.count }
    }

    /// 把还压在手里的那几块写出去。停止录音时必须调用，
    /// 否则最后几百毫秒会丢 —— 正好是最后一个字的尾音。
    ///
    /// 必须持有 pcmLock。
    private func flushHeld() {
        guard !held.isEmpty else { return }
        let pending = held
        held.removeAll(keepingCapacity: true)
        // 尾部这几块里只要有一块开着门，就整段放行。宁可多留一点环境音，
        // 也不能把最后一个字削掉。
        let anyOpen = pending.contains { $0.open }
        for chunk in pending {
            write(
                chunk.data,
                open: chunk.open || anyOpen,
                loud: chunk.loud,
                level: chunk.level
            )
        }
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
