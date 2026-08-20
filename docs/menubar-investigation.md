# 菜单栏图标不出现 —— 排查记录（未解决）

**症状**：MixDictate 正常运行 —— 说话键有反应、浮层显示、文字插得进输入框、
剪贴板也有 —— **但菜单栏上没有任何图标**。菜单栏本身正常，微信等第三方
App 的图标都在。

## App 自己看到的（`logs/app_status.json`）

```
menuBarHasButton : true      状态栏项有 button
menuBarImageOK   : true      图标图像生成成功
menuBarVisible   : true      isVisible 是 true
menuBarWidth     : 31        button 有宽度
menuBarX / Y     : 0 / -22   button 窗口在屏幕外（见下面「无效的证据」）
accessibility    : true
microphone       : authorized
appPath          : /Applications/MixDictate.app
```

也就是说：**App 这边每一步都成功了，系统就是不显示它。**

## 已经排除的（都实测过，不是推测）

| 假设 | 怎么排除的 |
|---|---|
| 我改的代码引进的 | 退回 `d7be4d6`（用户确认过图标还在的那一版）重装，照样没有 |
| 「隐藏菜单栏项」的偏好被记住了 | `defaults read dev.mixdictate.app` → 根本没有这个偏好域 |
| preferred position 存坏了 | 同上，没有任何存下来的位置 |
| 状态栏服务状态坏了 | `killall ControlCenter` 无效 |
| LaunchServices 注册坏了 | `lsregister -u` + `-f` 重注册无效 |
| 会话状态坏了 | 重启电脑无效 |
| 代码签名坏了 | `codesign --verify --deep --strict` → valid，满足 Designated Requirement |
| 启动方式（launchd 直接 exec vs `open`） | 两种方式 A/B 测过，表现一样 |
| 菜单栏放不下 | 退掉微信等图标、改分辨率腾出空间，都没用 |
| 图标画不出来（模板渲染 / 符号缺失 / 尺寸为 0） | 加了纯文字标签 `menuBarLabel`，**文字也不显示** —— 说明这一项压根不在菜单栏上，不是画的问题 |

## 无效的证据（别再拿它当依据）

- **`menuBarX/Y = (0, -22)` 说明不了问题。** 现代 macOS 的菜单栏由系统进程
  绘制，`NSStatusItem` 在 App 这边的窗口本来就可能停在屏幕外。这个坐标
  对正常工作的 App 可能也是这个值。
- **`isVisible == true` 说明不了问题。** 它只是 App 提出的要求，不代表
  系统给了槽位。
- **`button != nil` / `button.window != nil` 说明不了问题。** 同上。

## 下一步该做什么

1. **跑探针**：`swift scripts/menubar_probe.swift`
   - 出现 `PROBE` → 菜单栏和 AppKit 都正常，问题是 MixDictate 独有的，
     接着去比对探针和 MixDictate 的差别（bundle、签名类型、`LSUIElement`、
     启动方式、`NSApplication` 初始化顺序）
   - 不出现 → 这个用户会话现在不给任何新进程状态栏槽位，跟 MixDictate 的
     代码无关，往系统/账户方向查
2. **换一个 macOS 用户账户登录**，装上跑一遍。新账户 = 干净的每用户状态，
   能一刀切开「这台机器的这个账户」和「这个 App」。
3. 打开「系统设置 › 键盘 › 键盘导航」后按 `Control+F8`，用方向键走一遍
   菜单栏，看有没有 MixDictate 那一项（比用眼睛找可靠）。

## 现在能用的替代入口（图标没回来之前）

- `open -a MixDictate` → 直接弹出设置窗口（`applicationShouldHandleReopen`）
- `./scripts/config.sh` → 所有配置项都能改
- `./scripts/doctor.sh`、`./scripts/verify.sh` → 状态和自检
- 听写本身完全不依赖菜单栏图标
