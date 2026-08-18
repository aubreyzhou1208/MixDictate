import AppKit

/// 把实时结果直接写进当前输入框，不经过浮层。
///
/// 难点在于中间结果会被模型改写 —— 说到后面它会回头修正前面听错的词。
/// 所以不能一味往后追加，那样会写出一堆半成品的堆叠。做法是跟上一次
/// 写进去的内容比对：公共前缀留着不动，只把不同的尾巴退删掉重打。
/// 这样屏幕上看到的就是"文字自己在修正"，而且改动量最小。
@MainActor
final class LiveInserter {
    /// 已经写进输入框的内容
    private(set) var inserted = ""

    /// 一次最多退删多少字符。
    ///
    /// 用户完全可能在听写过程中自己动光标、改字、切换窗口 —— 那之后我们
    /// 对"已写入内容"的记忆就是错的，照着删会把他自己的东西删掉。
    /// 上限保证最坏情况也只波及一小段。
    private let maxDeletions = 200

    func reset() {
        inserted = ""
    }

    /// 把输入框里的内容从 `inserted` 改写成 `text`
    func update(to text: String) {
        guard text != inserted else { return }

        let old = Array(inserted)
        let new = Array(text)

        var shared = 0
        while shared < old.count, shared < new.count, old[shared] == new[shared] {
            shared += 1
        }

        let deletions = min(old.count - shared, maxDeletions)
        if deletions > 0 {
            TextInjector.sendBackspaces(deletions)
        }

        if shared < new.count {
            TextInjector.typeText(String(new[shared...]))
        }

        inserted = text
    }
}
