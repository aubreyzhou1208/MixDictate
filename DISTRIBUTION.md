# 从"自己能跑"到"别人能装"

这份文档回答一个问题：现在的 MixDictate 离**发给别人用**还差什么。

结论先放：**签名不是主要障碍，Python 依赖才是。** 签名那部分是流程，花钱花时间
就能办完；Python 那部分是要改架构的。

---

## 先纠正两件事

### 1. 自签名证书 ≠ Developer ID

`./scripts/signing.sh setup` 建的是**自签名证书**。它解决的是"重编译不掉权限"，
只在你自己这台机器上有效。别人下载到你的 App，Gatekeeper 会直接拦下来。

Developer ID 是 Apple 签发的，要加入 Apple Developer Program（**$99/年**）。
两者不是一回事，也不能互相替代。

| | 自签名 | 免费 Apple ID | Developer ID |
|---|---|---|---|
| 花钱 | 不 | 不 | $99/年 |
| 自己机器上开发 | ✅ | ✅ | ✅ |
| 发给别人装 | ❌ | ❌ | ✅ |
| 上架 App Store | ❌ | ❌ | 需另外的 Distribution 证书 |

### 2. App Store 这条路基本走不通

Mac App Store **强制 sandbox**，而 sandbox 里拿不到辅助功能 API。这个 App 的
两个核心能力都建立在辅助功能上：

- **全局快捷键** —— 全局按键监听需要辅助功能权限
- **把文字写进任意 App 的输入框** —— 靠 `AXUIElementSetAttributeValue`

同类产品全都在 App Store 之外：MacWhisper 直接把 `com.apple.security.app-sandbox`
设成了 `false`。这不是他们偷懒，是 sandbox 里做不到。

**所以路线是 Developer ID + 公证，做成 .dmg 直接下载。** 这也正好是免费分发。

---

## 真正的缺口，按大小排

### 1. Python 依赖（最大的一块）

现在 `install.sh` 干的事：建 venv → pip 装 `mlx-qwen3-asr` → 编译 Swift。
它假设用户机器上有 Python 3.10+ 和 Xcode 命令行工具。

**普通用户下载一个 .app 双击，这些一个都没有。** 而且 pip 装依赖要几分钟、
要联网、会失败 —— 这些都不能出现在"双击就能用"的体验里。

两条路：

**A. 把 Python 运行时打进 .app**
用 [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
的可重定位 Python，连同预装好的 wheel 一起放进 `Contents/Resources`。
- 好处：服务端代码一行不用改
- 代价：.app 大几百 MB；所有 `.so` 都要一起签名；要处理 `@rpath`

**B. 去掉 Python，改用 mlx-swift**
用 [mlx-swift](https://github.com/ml-explore/mlx-swift) 在 Swift 里直接跑模型。
- 好处：单个二进制，没有子进程，没有 HTTP，启动快，签名简单
- 代价：Qwen3-ASR 的前后处理要用 Swift 重写一遍；后处理那套中文规则也要搬过去
  （或者保留一个纯 Python 的后处理，但那又把 Python 请回来了）

**建议 B，但不是现在。** 开源版留着 Python 反而好 —— 改后处理规则不用重编译，
调试链路是敞开的。等要发给别人时再做 B，那时规则也稳定了。

### 2. 模型怎么给到用户

0.6B 的权重约 1.2 GB。现在是首次转写时由 `mlx-qwen3-asr` 静默从 Hugging Face 拉，
**失败了也不会告诉用户**，表现就是"一直是沙漏图标"。

要做的：首次启动引导页 + 下载进度 + 失败重试 + 断网时说人话。
不建议内嵌进 .app（下载 1.5 GB 的 dmg 劝退，而且更新模型要重发整个 App）。

### 3. Hardened Runtime 和 entitlements

公证要求开 hardened runtime，而 hardened runtime 默认禁止加载没签名的动态库 ——
MLX 和 Python 会加载一大堆 `.so`。需要的 entitlements：

```xml
<key>com.apple.security.cs.disable-library-validation</key> <true/>
<key>com.apple.security.device.audio-input</key>            <true/>
```

走 mlx-swift 那条路的话，第一条就不需要了 —— 又一个选 B 的理由。

### 4. 公证和打包

流程本身不难，是一次性的：

```
codesign --deep --force --options runtime --sign "Developer ID Application: ..." MixDictate.app
xcrun notarytool submit MixDictate.dmg --keychain-profile "..." --wait
xcrun stapler staple MixDictate.dmg
```

要注意 `--options runtime`（hardened runtime）和**内层所有二进制都要签**，
包括 Python 那一堆 `.so`。

### 5. 自动更新

现在是 `git ls-remote` + `git pull` + 重新编译 —— 这套只对"仓库在本地"的人有效。
用户版要换成 [Sparkle](https://sparkle-project.org/)：托管一个 appcast.xml，
用 EdDSA 密钥签名更新包。

### 6. 只能跑在 Apple Silicon 上

MLX 依赖 Metal，Intel Mac 跑不了。现在的处理是 `install.sh` 里 `uname -m` 判断
然后报错 —— 但用户版是双击 .app，得在 App 里检查并弹一个说人话的窗，
而不是让它崩掉。

---

## 还差的产品件

- **App 图标** —— 现在菜单栏用的是 SF Symbol，`.app` 本身没有图标
- **首次启动引导** —— 权限、模型下载、快捷键说明，串成一条线
- **出错时用户看得见** —— 现在很多信息只在 `logs/server.log` 里
- **隐私说明** —— "音频不出这台电脑"是这个 App 最大的卖点，得有个页面写清楚

---

## 建议的顺序

1. **先把开源版磨到自己天天用得顺手** ← 现在在这一步
2. 规则稳定后，做 mlx-swift 那次重写（去掉 Python）
3. 加首次启动引导和模型下载进度
4. 买 Developer Program，签名 + 公证 + 打 dmg
5. 接 Sparkle 做自动更新

第 1 步没走完就去做第 4 步，等于把还在变的东西提前冻住。
