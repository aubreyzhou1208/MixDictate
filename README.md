# MixDictate

macOS 菜单栏语音输入。按住一个键说话，松开后文字直接落在当前光标处 —— 任何 App 的任何输入框都行。

跟同类工具的区别在于**专门为中英混说做了优化**。说"这个 pipeline 的 latency 有点高"这种话时，现有工具基本都只做到"能认"，标点、空格、术语大小写全是乱的。

```
Qwen3-ASR 原始输出   嗯,这个pipeline的latency有点高,我们要不要换个schema?
MixDictate 输出      这个 pipeline 的 latency 有点高，我们要不要换个 schema？
```

100% 本地运行，音频不出这台电脑。

---

## 安装

一条命令：

```bash
./install.sh
```

它会建好 Python 环境、装依赖、编译 App、装进「应用程序」文件夹。因为要下载
mlx-qwen3-asr 和相关依赖，第一次跑要几分钟。

装完之后**就是个正常的 macOS App** —— 在启动台或「应用程序」里双击就能用，
转写服务由 App 自己拉起来和关掉，不用再开终端。

### 环境要求

- Apple Silicon Mac（M1/M2/M3/M4）—— MLX 依赖 Metal，Intel Mac 跑不了
- macOS 13+
- Python 3.10+、Xcode 命令行工具（`xcode-select --install`）

### 首次启动

两件一次性的事：

**授权**

| 权限 | 怎么给 |
|---|---|
| 麦克风 | 自动弹窗，点「允许」 |
| 辅助功能 | 手动：系统设置 › 隐私与安全性 › 辅助功能 → `+` → 选「应用程序」里的 MixDictate → 打开开关 |

没有辅助功能权限的话，转写能跑，但文字插不进输入框。

**等模型下载** —— 菜单栏图标是沙漏时说明还在启动，首次要从 Hugging Face 拉模型，
几分钟正常。变成麦克风图标就能用了。

### 开机自启

```bash
./scripts/autostart.sh install     # 装
./scripts/autostart.sh status      # 查
./scripts/autostart.sh uninstall   # 卸
```

## 用法

**按住右 Option 说话，松开。** 文字出现在光标处。

说话过程中屏幕下方会有一个浮层显示**实时转写结果** —— 边说边出字，
而且会随着你继续说而自我修正（模型拿到更多上下文后会改前面听错的词）。
松手时浮层显示最终版，同时文字插入到光标处。

浮层不会抢焦点，所以你正在打字的那个输入框始终保持活跃。
不想要的话在设置里关掉。

## 菜单栏图标

MixDictate 不进 Dock、不出现在 Cmd+Tab，只在系统状态栏（时钟、电量那一排）挂一个图标。

| 图标 | 状态 |
|---|---|
| 沙漏 | 正在启动转写服务 |
| 麦克风（跟随明暗自动反色） | 待命 |
| 红色实心麦克风 | 正在录音 |
| 波形 | 正在转写 |
| 橙色警告三角 | 出错了，点开菜单看原因 |

点图标弹菜单：设置、编辑热词表、检查服务状态、重启转写服务、查看服务日志、查看转写记录、退出。

用的是 SF Symbols 模板图像，浅色模式下是黑的、深色模式下是白的，跟旁边的系统图标一致。

## 热词表

菜单里点「编辑热词表…」，或直接编辑
`~/Library/Application Support/MixDictate/hotwords.txt`。
**保存即生效，不用重启。**

```
Kubernetes            # 普通热词：解码时偏置 + 输出时统一大小写
Supabase

k8s => Kubernetes     # 别名：听错的写法强制改回来
拍森 => Python
```

这是提升准确率**性价比最高**的一环。把你常说的人名、项目名、技术术语加进去，
效果比换更大的模型还明显。

两层机制互补：`context` 偏置是软的（让模型更容易听出这些词），别名替换是硬的
（模型仍然听错时按规则改回来）。

## 架构

```
右 Option 按下
   ↓
AudioRecorder      AVAudioEngine 录音 → 重采样 16kHz 单声道 → WAV
   ↓                 录音期间每 1.2 秒取一次快照 → partial 请求 → 浮层
   ↓  POST 127.0.0.1:8765
mixdictate_server  Qwen3-ASR (MLX, Metal GPU) + 热词 context 偏置
   ↓
hotwords.apply()   别名替换、术语大小写归一
postprocess()      去填充词 → 中英加空格 → 标点全角化
   ↓
TextInjector       写剪贴板 → 合成 Cmd+V → 还原剪贴板
```

拆成两个进程是因为模型在 Python/MLX 里，而全局快捷键和文字注入必须用原生
macOS API。HTTP 只走 127.0.0.1。

App 启动时先探一次 `/health`：已经有服务在跑就直接接管，否则自己拉起一个，
退出时只关自己启的那个。

**实时结果**是靠定期重转整段音频实现的，不是流式解码 —— Qwen3-ASR 是整段
推理的模型，没有流式接口。每次都从头转而不是增量拼接，因为分段拼接会在切口
处丢字，中英混说时尤其明显。代价是同一段音频会被转很多遍，所以：模型推理
串行加锁，同时最多只有一个中间请求在飞，松手后的最终请求不会排在一堆中间
请求后面。中间结果不写转写记录。

### 后处理为什么这么写

中英混说有几个规则不能想当然：

- **标点按整句语言判定，不是紧邻字符。** 中文句子经常以英文词结尾（"换个 schema?"），
  按紧邻字符判断会漏掉这些，而它们恰恰最需要转全角。
- **两侧紧贴 ASCII 字母数字时不转。** 保住 `3:30`、`a,b` 这类。
- **句点规则更严**（前面不是数字、后面是空格或结尾），保住 `3.14` 和 `config.json`。
- **叠词白名单。** "就是就是"是卡壳要压缩，"谢谢""看看"是正常中文不能动。

每条都有对应的测试锁着，见 `server/tests/test_postprocess.py`。

## 文件都在哪

```
~/Library/Application Support/MixDictate/
├── venv/            App 用的 Python 环境
├── hotwords.txt     你的热词表
└── logs/
    ├── server.log        转写服务日志（排错用）
    ├── transcripts.log   每次转写的原始输出 + 处理后结果（调准确率用）
    └── last_request.wav  最近一次录音（只留最新一份，反复覆盖）

~/.config/mixdictate/config.json   可选配置（见下）
/Applications/MixDictate.app       App 本体
```

装完之后 App 不再依赖源码目录 —— 仓库可以挪走甚至删掉。

## 设置

菜单栏图标 → **设置…**（或 `Cmd+,`）：

- **说话键** —— 点按钮，然后按一下你想用的修饰键。保存后立刻生效。
  可选：右/左 Option、右 Command、右/左 Control、右 Shift。
  只能用修饰键 —— 普通字母键在按住说话期间会一直重复输入到输入框里。
- **去掉口语词** —— "嗯""呃"这类
- **中文标点转全角** —— 关掉后保持半角，写代码时更顺手
- **实时结果浮层** —— 录音时在屏幕下方显示边说边出的文字
- **识别模型** —— 0.6B（快）/ 1.7B（更准）。换模型会自动重启服务。

顶部还会显示**辅助功能权限状态** —— 没授权的话文字插不进输入框，
这里能一键跳到设置页。

设置存在 `~/.config/mixdictate/config.json`，也可以直接编辑：

```json
{
  "pushToTalkKeyCode": 61,
  "stripFillers": true,
  "fullwidthPunctuation": true,
  "model": "Qwen/Qwen3-ASR-0.6B",
  "showLiveOverlay": true,
  "partialIntervalSeconds": 1.2,
  "minimumDurationSeconds": 0.3,
  "serverURL": "http://127.0.0.1:8765"
}
```

只写想改的字段即可，缺的用默认值。

## 测试准确率

每次转写都会记到 `~/Library/Application Support/MixDictate/logs/transcripts.log`，
**原始输出和处理后结果并排**：

```
2026-08-18 03:12:44  [0.83s]
  原始: 把它部署到kubernetes上面,用github actions跑CI
  输出: 把它部署到 Kubernetes 上面，用 GitHub actions 跑 CI
```

菜单里点「查看转写记录…」直接打开。

两个都记是有意的：只看最终结果分不清**是模型听错了，还是后处理改坏了**。
这两种问题的解法完全不同 —— 前者加热词，后者要改代码。

### 建议的测试流程

1. 找个文本编辑器，连续说 20-30 句你**平时真会说的话**（带上你常用的术语、人名、项目名）
2. 打开转写记录，逐条看
3. 分类：
   - **原始就错**（比如 `kubernetes` 听成 `库伯内特斯`）→ 加进热词表，或加别名 `库伯内特斯 => Kubernetes`
   - **原始对但输出错**（后处理把对的改坏了）→ 把这条贴出来，是代码 bug
4. 改完热词表保存，重测那几句

热词表的效果通常比换更大的模型明显 —— 先把热词调好再考虑上 1.7B。

### 目前没有的

- **情绪 / 语气识别**（"这句话是疑问还是感叹"之外的情感标签）—— Qwen3-ASR 不输出
  情绪标签。需要的话得换 SenseVoice，那是另一个模型，另说。
- 标点本身是有的：模型自己会输出，我们再做全角化和规则修正。

## 排错

**先跑诊断**，一条命令收集所有信息：

```bash
./scripts/doctor.sh
```

---

**按住说话键完全没反应（浮层都不出现）** —— 几乎一定是缺辅助功能权限。

macOS 的全局按键监听**本身就需要这个权限**，没有它 App 收不到任何按键 ——
所以表现不是"转写失败"，而是整个流程压根不启动。

去 系统设置 › 隐私与安全性 › 辅助功能 打开 MixDictate。**不用重启 App**，
它每 2 秒自己检查一次，权限一生效会弹窗告诉你。

**列表里找不到 MixDictate，或者开关打开了也不管用？**

权限是按代码签名记的，而每次 `./install.sh` 都会重新 ad-hoc 签名 ——
重装过几次之后，旧的权限记录会跟新签名对不上，表现就是列表里没有它，
或者有但勾了没用。清空重来：

```bash
tccutil reset Accessibility dev.mixdictate.app
pkill -x MixDictate
open -a MixDictate
```

重启后系统会重新弹授权对话框。也可以用菜单里的「重新申请辅助功能权限」。


**菜单栏图标一直是沙漏** —— 在下模型。菜单里「查看服务日志…」能看到进度。

**图标是橙色三角** —— 点开菜单，第一行就是错误原因。

**浮层显示「没识别出内容」** —— 音频进来了但模型没输出。菜单里点
「播放最近一次录音…」听一下：

- 能听清自己说话 → 录音链路没问题，问题在模型或热词偏置。服务日志里会写明
  是不是热词造成的（服务端在结果为空时会自动去掉热词重试一次）。
- 听不清 / 是静音 → 问题在录音链路，检查麦克风权限和系统的输入设备选择。

设成 `MIXDICTATE_SAVE_AUDIO=0` 可以关掉录音留存。

**能看到浮层出字，但文字没插进输入框** —— 辅助功能权限没给。这种情况
App 会弹窗提示，并且**文字已经在剪贴板里，可以直接 Cmd+V**。
设置界面顶部也会显示权限状态，点「去授权」直接跳到对应的设置页。

重装 App 后权限会失效（macOS 按应用签名记权限），要在系统设置里把旧条目
删掉重新添加。

**说话没反应** —— 确认按的是右 Option 不是左 Option。改键见配置一节。
如果听到"叮"一声，说明服务还没就绪。

**菜单栏图标找不到** —— 图标是个**麦克风**符号，在右侧时钟那一排。
按住 `Cmd` 拖动菜单栏图标可以重新排序，把它拖到时钟旁边就不容易被挤掉。

不想折腾的话，菜单里的功能都有对应的命令：

```bash
open ~/Library/Application\ Support/MixDictate/logs/last_request.wav  # 听最近一次录音
open ~/Library/Application\ Support/MixDictate/logs/transcripts.log   # 看转写记录
open ~/Library/Application\ Support/MixDictate/logs/server.log        # 看服务日志
open -e ~/Library/Application\ Support/MixDictate/hotwords.txt        # 改热词表
```

`./scripts/doctor.sh` 的结尾也会把这些命令打出来。

**菜单栏里根本看不到图标** —— 刘海屏图标太多会被挤到刘海后面（退几个别的
菜单栏 App 试试，或用 Bartender / Ice 管理）；也可能 App 压根没起来，
在「应用程序」里双击看有没有报错。

## 开发

```bash
make dev-setup         # 在 server/.venv 建独立的开发环境
make test              # 全部测试，不需要模型，任何平台都能跑
make dev-server        # 前台跑服务，看实时日志
make dev-server-mock   # 不加载模型空跑，验证链路
make app               # 只重新编译 App
```

开发环境（`server/.venv`）和 App 用的环境
（`~/Library/Application Support/MixDictate/venv`）是分开的，互不干扰。

测试分三层：`test_postprocess.py` 测纯函数，`test_paths.py` 测路径解析和词表播种，
`test_server.py` 用 mock 后端走完整 HTTP 链路。都不需要 mlx，所以 CI 在 Linux 上就能跑。

CI（`.github/workflows/ci.yml`）跑四个 job：Python 测试（3.10 / 3.12）、
Apple Silicon runner 上的 Swift 编译 + bundle 校验、shellcheck。

## 状态

**早期原型。** Python 侧 39 个测试覆盖，Swift 侧由 CI 在 Apple Silicon runner
上编译验证。但**完整的录音 → 转写 → 注入流程还没在真机上端到端跑过** ——
权限授予、真实模型推理、剪贴板注入在各 App 里的行为，这几段需要人工验证。

## 许可

MIT。用到的 [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) 模型是 Apache 2.0，
[mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr) 提供 Apple Silicon 推理。
