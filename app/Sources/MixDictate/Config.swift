import Foundation

/// 运行时配置。存在 ~/.config/mixdictate/config.json，设置界面直接改这个文件。
struct Config {
    /// 按住不放的说话键。61 = 右 Option。
    /// 右 Command(54) 也常见，但它跟很多 App 的快捷键冲突，所以默认用右 Option。
    var pushToTalkKeyCode: UInt16 = 61
    var serverURL: String = "http://127.0.0.1:8765"

    /// 去掉"嗯""呃"这类口语填充词
    var stripFillers: Bool = true

    /// 中文标点转全角。写代码时可能更想要半角，所以留成开关。
    var fullwidthPunctuation: Bool = true

    /// 用系统的语音处理单元做回声消除。**默认关闭。**
    ///
    /// 打开后电脑自己放出来的声音不会被当成你说的话，但它在 macOS 上有
    /// 两个躲不开的代价：
    ///
    /// 1. **整台电脑的音量会被压低** —— 语音处理单元是给 VoIP 用的，
    ///    一初始化 macOS 就把其他所有音频压低（跟通话中一样）。控制这个
    ///    行为的那个属性只有 iOS 有而且已废弃，macOS 上关不掉。
    /// 2. **它会把输入换成多声道格式**，转换那一步一旦对不上，采集就
    ///    整个变成全零 —— 曾经让麦克风彻底哑掉。
    ///
    /// 挡外放靠 voiceThreshold 就够了，代价小得多。真要完全隔绝请戴耳机。
    var echoCancellation: Bool = false

    /// 人声门限（0…1）：低于它的声音一律当环境音丢掉，不进入转写。
    ///
    /// 回声消除只能减掉电脑自己正在播的那一路信号，减不干净，而且它
    /// 不做人声分离 —— 扬声器漏回麦克风的说话声，模型听起来跟你说话
    /// 一模一样。挡住它靠的是距离带来的响度差：你的嘴离麦克风很近，
    /// 视频的声音绕了一圈才回来。
    ///
    /// 调大 = 更能挡住外放；调小 = 小声说话也收得到。0 = 关掉。
    /// 想彻底隔绝还是戴耳机 —— 声音根本不进麦克风，才是真的隔绝。
    ///
    /// **默认值定在"绝不吃字"那一侧。** 正常说话峰值 0.2–0.6，而轻声字、
    /// 词尾、一个词的第二个音节常常只有 0.02–0.06 —— 设 0.05 会正好切在
    /// 字的中间。挡不住外放只是没帮上忙，吃掉字是把事情弄坏了。
    var voiceThreshold: Double = 0.02

    /// 送给模型之前把内部静音压到最长这么久（秒）。0 = 不压。
    ///
    /// 解的是「我一停顿它就自己加个句号」。模型判断句子说完没有，最主要
    /// 的依据就是停顿有多长 —— 而「在想下一句」和「这句说完了」在音频里
    /// 是同一件事：一段安静，分不开。之前试过按停顿时长猜，猜错的比对的多。
    ///
    /// 所以不猜，直接把线索削掉：1.5 秒的思考停顿压成 0.35 秒，模型看到的
    /// 就只是个正常的字间空隙，没理由断句了。顺带音频变短，推理也更快。
    ///
    /// 调大 = 更尊重你的停顿（该断的地方还是会断）；调小 = 更不容易乱加句号。
    var maxPauseSeconds: Double = 0.35

    /// 只要模型原文，不做任何加工。
    ///
    /// 打开这个等于把下面所有开关一次性关掉：去语气词、去重复、
    /// 数字转换、符号转换、标点全角。用来判断"奇怪的输出"到底是模型
    /// 听错了还是后处理改坏了 —— 这两件事的解法完全不同。
    var rawOutput: Bool = false

    /// 合并卡壳时的重复。**默认关闭** —— 「超级超级好」是刻意的强调，
    /// 不是卡壳，而删错的代价比留着重复大得多。
    var collapseRepeats: Bool = false

    /// 把思考停顿处误加的句号降级成逗号。
    ///
    /// 压短停顿是从**声音**那一侧削掉线索，这个是从**文字**那一侧补救 ——
    /// 模型在停顿处断了句，但后面跟着「然后」「但是」「所以」，说明这句
    /// 根本没说完。声音里分不开的东西，文字里常常分得开。
    ///
    /// 只降级标点，绝不删字：删掉的内容你根本不知道它曾经存在过，
    /// 多余的标点你一眼就能看见并改掉。
    var mergePausePeriods: Bool = true

    /// 学习你对刚插入的文字做的修改。**默认关闭。**
    ///
    /// 转写记录里挖词只能看到"这个词你说得多"，看不到"这个词它一直听错"。
    /// 而真正该进热词表的恰恰是后者 —— 你每次都要手动改的那个词。
    /// 你改了什么，是唯一能区分这两件事的信号。
    ///
    /// 代价是它要回头看一眼输入框。所以口子开得尽量小：**只按范围读
    /// 我们自己写进去的那一段**（kAXStringForRange），控件不支持按范围读
    /// 就放弃这次学习，绝不退回去读全文。学到的只存本机，不联网。
    ///
    /// 同一个纠正攒够 3 次才写进词表 —— 一次是手滑，两次可能是巧合。
    var learnCorrections: Bool = false

    /// 长句里的接续词前面补逗号。
    ///
    /// 跟 mergePausePeriods 正好是一对：那个管"停顿处多出来的句号"，
    /// 这个管"说得顺的时候一个逗号都没有"。两者同源 —— 模型下标点主要
    /// 靠停顿，而说得顺时分句处根本不停，没有停顿就没有逗号。
    ///
    /// 只加逗号，不动任何字。
    var splitClauses: Bool = true

    /// 口语数字还原成阿拉伯数字：「三点一四」→「3.14」
    var spokenNumbers: Bool = true

    /// 口语符号还原成符号：「艾特 gmail 点 com」→「@gmail.com」
    var spokenSymbols: Bool = true

    /// 短于这个时长的录音直接丢弃 —— 多半是误触
    var minimumDurationSeconds: Double = 0.3

    /// 录音时在屏幕上显示实时转写结果
    var showLiveOverlay: Bool = true

    /// 浮层的不透明度（0…1）。默认半透 —— 它固定在屏幕上一块地方，
    /// 底下正好是你在看的东西。它是个提示，不该是块挡板。
    var overlayOpacity: Double = 0.75

    /// 浮层被拖到过的位置（屏幕坐标）。nil = 用默认位置（底部靠上一点）。
    ///
    /// 按住说话键时没法用同一只手挪窗口，所以位置必须记住 ——
    /// 挪一次要管以后所有次。
    var overlayX: Double?
    var overlayY: Double?

    /// 松手后用完整音频重转一遍的时长上限（秒）。
    ///
    /// 分段是为实时预览提速的，代价是每段只看得到自己那两三秒 ——
    /// 上下文没了，识别变差、段落边界的标点只能靠猜。短录音在松手时
    /// 重转一次就把这两样补回来；超过这个长度就不重转，那笔开销正是
    /// 当初做分段要解决的问题。设成 0 可以完全关掉。
    var fullPassMaxSeconds: Double = 45

    /// 实时结果的刷新间隔下限。段落长度已经封顶，单次推理耗时有天花板，
    /// 所以可以刷得比以前勤。
    var partialIntervalSeconds: Double = 0.8

    /// 边说边把文字直接写进输入框，不用浮层也不用等松手。
    /// 代价见设置界面里的说明 —— 默认关闭。
    var liveInsertion: Bool = false

    /// 文字送进输入框的方式。粘贴最快，逐字输入兼容性更好。
    /// 安全输入模式下两者都会被系统拦截，那时会自动改走辅助功能接口。
    var insertionMethod: String = InsertionMethod.paste.rawValue

    /// 改这个要重启转写服务才生效
    var model: String = "Qwen/Qwen3-ASR-0.6B"

    static let path = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mixdictate/config.json")

    /// 配置文件的修改时间。App 靠它发现外部改动 —— 菜单栏图标常常
    /// 找不到，命令行改配置必须能立刻生效。
    static func modificationDate() -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: path.path)[.modificationDate] as? Date
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: path) else { return Config() }
        return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
    }

    func save() throws {
        try FileManager.default.createDirectory(
            at: Self.path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.path, options: .atomic)
    }

    /// serverURL 写坏了不该让整个 App 崩掉，退回默认地址
    private var baseURL: URL {
        URL(string: serverURL) ?? URL(string: "http://127.0.0.1:8765")!
    }

    /// 配置里写了个不认识的值时退回默认，不要让听写整个失效
    var resolvedInsertionMethod: InsertionMethod {
        InsertionMethod(rawValue: insertionMethod) ?? .paste
    }

    var transcribeURL: URL { baseURL.appendingPathComponent("transcribe") }
    var healthURL: URL { baseURL.appendingPathComponent("health") }
    var warmupURL: URL { baseURL.appendingPathComponent("warmup") }
}

// 手写解码而不是用合成的：合成的 init(from:) 要求 JSON 里每个键都存在，
// 只写了一个 pushToTalkKeyCode 的配置文件会整份解码失败，然后被 try? 吞掉 ——
// 表现就是"我明明改了配置却完全没生效"。decodeIfPresent 才是想要的语义。
// 这条在加字段之后更重要：老配置文件不能因为缺新字段就整份失效。
extension Config: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Config()
        pushToTalkKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .pushToTalkKeyCode)
            ?? fallback.pushToTalkKeyCode
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL)
            ?? fallback.serverURL
        stripFillers = try c.decodeIfPresent(Bool.self, forKey: .stripFillers)
            ?? fallback.stripFillers
        fullwidthPunctuation = try c.decodeIfPresent(Bool.self, forKey: .fullwidthPunctuation)
            ?? fallback.fullwidthPunctuation
        echoCancellation = try c.decodeIfPresent(Bool.self, forKey: .echoCancellation)
            ?? fallback.echoCancellation
        voiceThreshold = try c.decodeIfPresent(Double.self, forKey: .voiceThreshold)
            ?? fallback.voiceThreshold
        maxPauseSeconds = try c.decodeIfPresent(Double.self, forKey: .maxPauseSeconds)
            ?? fallback.maxPauseSeconds
        rawOutput = try c.decodeIfPresent(Bool.self, forKey: .rawOutput)
            ?? fallback.rawOutput
        collapseRepeats = try c.decodeIfPresent(Bool.self, forKey: .collapseRepeats)
            ?? fallback.collapseRepeats
        spokenNumbers = try c.decodeIfPresent(Bool.self, forKey: .spokenNumbers)
            ?? fallback.spokenNumbers
        spokenSymbols = try c.decodeIfPresent(Bool.self, forKey: .spokenSymbols)
            ?? fallback.spokenSymbols
        mergePausePeriods = try c.decodeIfPresent(Bool.self, forKey: .mergePausePeriods)
            ?? fallback.mergePausePeriods
        splitClauses = try c.decodeIfPresent(Bool.self, forKey: .splitClauses)
            ?? fallback.splitClauses
        learnCorrections = try c.decodeIfPresent(Bool.self, forKey: .learnCorrections)
            ?? fallback.learnCorrections
        minimumDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .minimumDurationSeconds)
            ?? fallback.minimumDurationSeconds
        showLiveOverlay = try c.decodeIfPresent(Bool.self, forKey: .showLiveOverlay)
            ?? fallback.showLiveOverlay
        overlayOpacity = try c.decodeIfPresent(Double.self, forKey: .overlayOpacity)
            ?? fallback.overlayOpacity
        overlayX = try c.decodeIfPresent(Double.self, forKey: .overlayX)
        overlayY = try c.decodeIfPresent(Double.self, forKey: .overlayY)
        partialIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .partialIntervalSeconds)
            ?? fallback.partialIntervalSeconds
        fullPassMaxSeconds = try c.decodeIfPresent(Double.self, forKey: .fullPassMaxSeconds)
            ?? fallback.fullPassMaxSeconds
        liveInsertion = try c.decodeIfPresent(Bool.self, forKey: .liveInsertion)
            ?? fallback.liveInsertion
        insertionMethod = try c.decodeIfPresent(String.self, forKey: .insertionMethod)
            ?? fallback.insertionMethod
        model = try c.decodeIfPresent(String.self, forKey: .model)
            ?? fallback.model
    }
}

/// 可选的模型。0.6B 够日常用，1.7B 更准但更吃内存和时间。
enum ASRModel: String, CaseIterable {
    case small = "Qwen/Qwen3-ASR-0.6B"
    case large = "Qwen/Qwen3-ASR-1.7B"

    var label: String {
        switch self {
        case .small: return "0.6B — 快（推荐）"
        case .large: return "1.7B — 更准，慢一些"
        }
    }
}
