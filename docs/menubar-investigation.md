# 菜单栏图标不出现 —— 排查记录（已解决）

**症状**：MixDictate 正常运行 —— 说话键有反应、浮层显示、文字插得进输入框、
剪贴板也有 —— **但菜单栏上没有任何图标**。菜单栏本身正常，微信等第三方
App 的图标都在。

## 结论

**macOS 26 把第三方菜单栏图标交给 Control Center 管，它有一份隐藏名单
（`blockedHosts`），MixDictate 在里面。** 名单按 `bundle id + autosaveName`
这个组合记账。

被列进去之后，App 这边**每一步都成功**：`NSStatusItem` 建得出来，
`button` 和 `button.window` 都在，`isVisible` 照样是 `true` ——
只有那个窗口被停在屏幕外面。系统不报错，App 自己也查不出异常。

两条出路，都实测过：

- **用户侧**：系统设置 › **菜单栏**（macOS 26 新加的一栏）里把它打开。
- **App 侧**：换一个 `autosaveName` 重建。名单认的是组合，换个它没见过的
  组合就放行 —— 而且换过一次之后，连原来那个名字都跟着解禁了。
  这条现在写进代码了：发现没放上去就自动换名字重建（见 `pitfalls.md` 17b）。

## 怎么问出真相

只有两条路能看见这件事，别的都会告诉你"一切正常"：

```bash
# 1. 系统怎么想。blocked 就是它。
log show --predicate 'process == "ControlCenter" AND category == "appStatusItems"' \
    --last 10m --style compact | grep -i mixdictate
#   正常： Starting to track host;         (bid:dev.mixdictate.app-…)
#   被隐藏：Starting to track blocked host; (bid:dev.mixdictate.app-…)

# 2. 几何位置。放上去了贴着屏幕顶边，没放上去停在 (0, -22)。
grep menuBar "$HOME/Library/Application Support/MixDictate/logs/app_status.json"
```

`blockedHosts` 这份名单在 `~/Library` 下**搜不到任何明文落点**，只存在
Control Center 自己的内部状态里 —— 所以没有"改个配置文件就好"的路子。

## 决定性的对照实验

`swift scripts/menubar_probe.swift` —— 或者任何一个十几行的菜单栏小程序。

它一放就上去（窗口落在 `(1073, 949, 31, 33)`），同一台机器同一时刻
MixDictate 却上不去。**这一步把"系统坏了"和"这个 bundle id 上了名单"
一刀切开**，是整轮排查里唯一直接指向答案的实验。

## 已经排除的（都实测过，不是推测）

| 假设 | 怎么排除的 |
|---|---|
| 我改的代码引进的 | 退回 `d7be4d6`（用户确认过图标还在的那一版）重装，照样没有 |
| 「隐藏菜单栏项」的偏好被记住了 | `defaults read dev.mixdictate.app` 里没有这条 —— **但方向是对的，只是记在了别的进程里**（见下） |
| preferred position 存坏了 | 同上，没有任何存下来的位置 |
| 状态栏服务状态坏了 | `killall ControlCenter` 无效 |
| LaunchServices 注册坏了 | `lsregister -u` + `-f` 重注册无效 |
| 会话状态坏了 | 重启电脑无效 |
| 代码签名坏了 | `codesign --verify --deep --strict` → valid，满足 Designated Requirement |
| 启动方式（launchd 直接 exec vs `open`） | 两种方式 A/B 测过，表现一样 |
| 菜单栏放不下 | 退掉微信等图标、改分辨率腾出空间，都没用 |
| 图标画不出来（模板渲染 / 符号缺失 / 尺寸为 0） | 加了纯文字标签 `menuBarLabel`，**文字也不显示** —— 说明这一项压根不在菜单栏上，不是画的问题 |

## ⚠️ 上一版这里写着「无效的证据」，其中一条正是答案

这一节原来劝后来人**别看** `menuBarX/Y`，理由是"现代 macOS 的菜单栏由系统
进程绘制，这个坐标对正常工作的 App 可能也是这个值"。

**那句话是错的，而且它把唯一有效的线索划掉了。** 实测：

| | 窗口 frame |
|---|---|
| 真的放进菜单栏了 | `(1073, 949, 31, 33)` —— 贴着屏幕顶边 |
| 被系统隐藏 | `(0, -22, 31, 22)` —— 屏幕底边外面 |

后者跟"把一个状态栏项显式设成 `isVisible = false`"得到的 frame **逐字节
相同**。也就是说 `(0, -22)` 不是噪音，它就是"这一项被藏起来了"的签名。

另外两条仍然成立，而且现在有了更准的说法：

- `isVisible == true` 说明不了问题 —— 它只是 App 提的要求，系统收下但可以不办。
- `button != nil` / `button.window != nil` 说明不了问题 —— 被隐藏的项这两样都有。

**教训：三个值里有两个是假的，剩下那个被当成假的划掉了。**
自检项写在被怀疑的那一层里，只会一遍遍告诉你"这里没问题"；
要么去问系统日志，要么去量最终结果（位置），不要问中间那个变量。

## 图标万一又没了：还能从哪儿进去

- `open -a MixDictate` → 直接弹出设置窗口（`applicationShouldHandleReopen`），
  顺带会再抢救一次菜单栏图标
- `./scripts/config.sh` → 所有配置项都能改
- `./scripts/doctor.sh`、`./scripts/verify.sh` → 状态和自检
  （`verify.sh` 现在会直接核对图标到底有没有被放进菜单栏）
- 听写本身完全不依赖菜单栏图标
