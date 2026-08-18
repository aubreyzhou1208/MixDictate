# MixDictate

macOS 菜单栏语音输入。按住一个键说话，松开后文字直接落在当前光标处 —— 任何 App 的任何输入框都行。

跟同类工具的区别在于**专门为中英混说做了优化**。说"这个 pipeline 的 latency 有点高"这种话时，现有工具基本都只做到"能认"，标点、空格、术语大小写全是乱的。

```
Qwen3-ASR 原始输出   嗯,这个pipeline的latency有点高,我们要不要换个schema?
MixDictate 输出      这个 pipeline 的 latency 有点高，我们要不要换个 schema？
```

100% 本地运行，音频不出这台电脑。

---

## 状态

**早期原型。** Python 服务端已完整测试通过；Swift 端代码完整但**尚未在真机编译验证过**，第一次构建可能需要小修。

## 环境要求

- Apple Silicon Mac（M1/M2/M3/M4），16GB 内存跑 0.6B 模型很宽裕
- macOS 13+
- Python 3.10+、Xcode Command Line Tools（`xcode-select --install`）

## 上手

```bash
make setup     # 建虚拟环境，装依赖（含 mlx-qwen3-asr）
make server    # 启动本地转写服务，保持这个终端开着
```

另开一个终端：

```bash
make run       # 编译并启动菜单栏 App
```

首次运行要给两个权限：

| 权限 | 怎么给 | 不给会怎样 |
|---|---|---|
| 麦克风 | 自动弹窗，点允许 | 录不到音 |
| 辅助功能 | 系统设置 › 隐私与安全性 › 辅助功能，手动添加 `MixDictate.app` | 能转写，但文字插不进输入框 |

然后**按住右 Option 说话，松开**。菜单栏图标会走 🎙 → 🔴 → ⏳ → 文字出现。

第一次转写要等模型加载（约 3-10 秒），之后单次延迟在 1 秒以内。

## 热词表

改 `config/hotwords.txt`，**保存即生效，不用重启服务**。

```
Kubernetes            # 普通热词：解码时偏置 + 输出时统一大小写
Supabase

k8s => Kubernetes     # 别名：听错的写法强制改回来
拍森 => Python
```

这是提升准确率**性价比最高**的一环。把你常说的人名、项目名、技术术语加进去，效果比换更大的模型还明显。

两层机制互补：`context` 偏置是软的（让模型更容易听出这些词），别名替换是硬的（模型仍然听错时按规则改回来）。

## 架构

```
右 Option 按下
   ↓
AudioRecorder      AVAudioEngine 录音 → 重采样 16kHz 单声道 → WAV
   ↓  POST 127.0.0.1:8765
mixdictate_server  Qwen3-ASR (MLX, Metal GPU) + 热词 context 偏置
   ↓
hotwords.apply()   别名替换、术语大小写归一
postprocess()      去填充词 → 中英加空格 → 标点全角化
   ↓
TextInjector       写剪贴板 → 合成 Cmd+V → 还原剪贴板
```

拆成两个进程是因为模型在 Python/MLX 里，而全局快捷键和文字注入必须用原生 macOS API。HTTP 只走 127.0.0.1。

### 后处理为什么这么写

中英混说有几个规则不能想当然：

- **标点按整句语言判定，不是紧邻字符。** 中文句子经常以英文词结尾（"换个 schema?"），按紧邻字符判断会漏掉这些，而它们恰恰最需要转全角。
- **两侧紧贴 ASCII 字母数字时不转。** 保住 `3:30`、`a,b` 这类。
- **句点规则更严**（前面不是数字、后面是空格或结尾），保住 `3.14` 和 `config.json`。
- **叠词白名单。** "就是就是"是卡壳要压缩，"谢谢""看看"是正常中文不能动。

这些规则每条都有对应的测试锁着，见 `server/tests/test_postprocess.py`。

## 配置

可选，放在 `~/.config/mixdictate/config.json`：

```json
{
  "pushToTalkKeyCode": 61,
  "serverURL": "http://127.0.0.1:8765",
  "stripFillers": true,
  "minimumDurationSeconds": 0.3
}
```

按键码：右 Option `61`、左 Option `58`、右 Command `54`、右 Control `62`。
默认用右 Option 是因为右 Command 跟很多 App 的快捷键冲突。

更准但更慢的模型：`MIXDICTATE_MODEL=Qwen/Qwen3-ASR-1.7B make server`

## 开发

```bash
make test         # 后处理单元测试，不需要模型，任何平台都能跑
make server-mock  # 不加载模型空跑服务，用来验证 App→服务链路
```

## 排错

**菜单栏图标是 ⚠️** —— 点开菜单看错误信息，或选"检查服务状态"。

**文字没插进输入框** —— 辅助功能权限没给，或者改代码重新编译后权限失效了。macOS 按应用签名记权限，重新构建后要在系统设置里把旧条目删掉重新添加。

**说话没反应** —— 确认按的是右 Option 不是左 Option。想换键改配置文件里的 `pushToTalkKeyCode`。

**第一次转写很慢** —— 正常，在加载模型。`make server` 启动时已经预热了，如果还慢就是模型在从 Hugging Face 下载。

## 许可

MIT。用到的 [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) 模型是 Apache 2.0，[mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr) 提供 Apple Silicon 推理。
