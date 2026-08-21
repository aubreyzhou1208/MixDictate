import AppKit

/// 把实时结果直接写进当前输入框，不经过浮层。
///
/// ## 这个模式为什么问题最多
///
/// 它是整个 App 里**唯一持有"输入框现在是什么样"这份记忆、并且照着这份
/// 记忆做破坏性操作（退格）的地方**。而这份记忆是**猜的** —— 它按我们
/// 发出去的按键事件推算，从来没跟真实的输入框核对过。
///
/// 能让这份记忆失准的事情很多，而且都不受我们控制：
///
/// · 合成按键事件被目标 App 的事件队列丢掉
/// · 用户自己动了光标、改了字、选中了一段
/// · 输入法在组字，App 在自动补全、自动缩进、自动纠错
/// · 焦点跑到别的输入框甚至别的 App 去了
///
/// **只要偏了一个字符，之后每次改写都在错误的基础上退删，而且会累积。**
/// 非实时模式没有这个问题：它只在最后插入一次，不持有任何状态、不做退格。
/// 这就是为什么那边"好用很多"。
///
/// ## 所以现在退格之前要核对
///
/// 删之前把光标前面那几个字读回来，跟我们以为写进去的比一比。对不上就
/// **什么都不做** —— 不删也不打，标记成不可信，交给上层去兜底。
/// 读不回来（有些控件不支持按范围读）时只允许小改动，把最坏情况圈住。
@MainActor
final class LiveInserter {
    /// 已经写进输入框的内容（我们的记忆，不保证等于现实）
    private(set) var inserted = ""

    /// 这份记忆还可不可信。一旦核对失败就永久变成 false，
    /// 直到下一次听写重置 —— 在错误基础上继续退删只会越改越歪。
    private(set) var trusted = true

    /// 记忆失准时通知上层。上层要停掉实时写入并给用户兜底（复制到剪贴板）。
    var onUntrusted: (() -> Void)?

    /// 一次最多退删多少字符
    private let maxDeletions = 200

    /// 核对不了的时候（控件不支持按范围读）最多允许删多少。
    ///
    /// 一次正常的改写只动最后几个字；要删几十上百个字符还核对不了的，
    /// 多半是记忆已经错了 —— 那种时候宁可不改，也不能去删用户的东西。
    private let unverifiableDeletionLimit = 20

    func reset() {
        inserted = ""
        trusted = true
    }

    /// 把输入框里的内容从 `inserted` 改写成 `text`
    func update(to text: String) {
        guard trusted, text != inserted else { return }

        let old = Array(inserted)
        let new = Array(text)

        var shared = 0
        while shared < old.count, shared < new.count, old[shared] == new[shared] {
            shared += 1
        }

        let deletions = old.count - shared

        // 要删的比一次能安全删的还多。
        //
        // 原来这里是 `min(needed, maxDeletions)` —— 截断着删，然后照样
        // 把记忆记成"已经改完了"。那正是这个类要防的事：输入框里还留着
        // 没删掉的一截，而我们以为它跟 text 一模一样，之后每一次改写都
        // 建立在这份错的记忆上，越改越歪。**宁可停手，也不能记错。**
        if deletions > maxDeletions {
            trusted = false
            onUntrusted?()
            return
        }

        if deletions > 0, !canSafelyDelete(deletions, expecting: old) {
            trusted = false
            onUntrusted?()
            return
        }

        // 退格和补字必须是一次调用。分开发的话两次改写之间可能交错，
        // 退格就删到另一次刚打进去的字上了。
        TextInjector.replaceTail(
            deleting: deletions,
            with: shared < new.count ? String(new[shared...]) : ""
        )

        inserted = text
    }

    /// 要删的这一段，确实是我们自己写进去的吗？
    private func canSafelyDelete(_ count: Int, expecting old: [Character]) -> Bool {
        let expected = String(old[(old.count - count)...])

        guard let actual = TextInjector.textBeforeCaret(count) else {
            // 读不回来 = 没法确认。**没法确认不等于确认通过** ——
            // 只放行小改动，把最坏情况圈在几个字以内。
            return count <= unverifiableDeletionLimit
        }
        return actual == expected
    }
}
