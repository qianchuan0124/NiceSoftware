# XLLoginGuard —— 屏蔽迅雷「个人中心-登录」自动弹窗

一个约 10 KB、无依赖、不需要管理员权限的常驻小工具：迅雷每次启动时自动弹出的
**「迅雷个人中心-登录」**窗口（600×440，居中，带一层阴影），会在出现后 0.4 秒内被隐藏并关闭，
连带它的 `XL_ShadowWindow` 阴影窗一起清掉，所以基本看不到闪烁。

本目录是完整可复用的工程：源码 + 编译脚本 + 安装/卸载/诊断脚本 + 本说明。
换一台电脑只需要复制目录、跑一条安装命令。

---

## 1. 为什么不是「改配置」或「改迅雷文件」

网上流传的做法是改迅雷 `Profiles\config.json` 里的 `LoginWndAutoShow.Date`
（有的说改成未来日期，有的说改成过去的日期）。**实测两者都无效**：

| 实验 | `LoginWndAutoShow.Date` | 重启迅雷后 |
| --- | --- | --- |
| A | `20260101`（过去） | 启动 1 秒内照样弹出「迅雷个人中心-登录」，随后配置被改写回当天 |
| B | `20990101`（未来） | 照样弹出，配置同样被改写回当天 |

也就是说，这个字段的语义是「**日期 ≠ 今天** 就弹」，所以任何不等于今天的手改值都会触发弹窗；
而迅雷在启动时会把这个字段重新写成当天，改配置等于白改。

另一个思路是打补丁改 `Thunder.exe` / `XDASKernel.dll` 或它的界面资源，但迅雷是
Electron + 原生窗口混合、登录页来自服务端，改文件风险高（签名校验、自动更新回滚、杀软误报），
而且不可逆。所以这里采用**外部窗口守护**：不碰迅雷任何文件，随时可以停掉。

### 弹窗的真身（实测枚举结果）

| 属性 | 值 |
| --- | --- |
| 窗口类名 | `Chrome_WidgetWin_0`（和迅雷主界面同类，说明是 CEF 窗口） |
| 标题 | `迅雷个人中心-登录` |
| 尺寸/位置 | 600×440，屏幕居中 |
| 伴随窗口 | `XL_ShadowWindow`，约 616×456，向左上偏移 8px |
| 触发时机 | 当天第一次启动迅雷时自动弹出；弹过之后同一天内再启动不弹 |

---

## 2. 守护程序做了什么

每 400 毫秒枚举一次顶层可见窗口，同时满足以下条件才动手：

1. 类名以 `Chrome_WidgetWin` 开头；
2. 标题包含 `登录`；
3. 窗口所属进程的可执行文件名叫 `Thunder`；
4. 尺寸不小于 200×150（排除通知条等小窗）。

命中后 `ShowWindow(SW_HIDE)` + `PostMessage(WM_CLOSE)`，并在同进程内按登录窗矩形
（外扩 8px、容差 12px）找到 `XL_ShadowWindow` 一并关闭。

### 不会误关你自己点开的登录窗

- 迅雷进程**启动后 25 秒内**出现的登录窗，一律当作自动弹窗关掉；
- 超过 25 秒之后，只有**桌面空闲 ≥ 1.5 秒**时才关；如果你刚点了鼠标/键盘（说明是你自己
  点头像打开的个人中心），就跳过并在日志里记一条 `skip (looks user-initiated)`。

所以：想主动登录一次，等迅雷启动 25 秒后再点头像即可。

### 它不做什么

- 不修改、不替换迅雷的任何文件或注册表项（仅占一个 `HKCU` 自启项）；
- 不联网、不读你的下载数据、不开窗口、不出现在任务栏；
- 只在你登录后以普通用户权限运行，不需要 UAC。

---

## 3. 目录结构

```
xl-login-guard/
├─ README.md                  ← 本文件
├─ src/
│  └─ XLLoginGuard.cs         ← 全部逻辑，单文件 C#（源码刻意保持纯 ASCII，靠转义写中文关键字）
├─ scripts/
│  ├─ build.ps1               ← 用系统自带 .NET Framework 4 的 csc.exe 编译到 bin\
│  ├─ install.ps1             ← 编译 + 安装到 %LOCALAPPDATA%\XLLoginGuard + 写自启 + 启动
│  ├─ uninstall.ps1           ← 停进程、删自启项、删安装目录
│  └─ diag.ps1                ← 只读诊断：迅雷进程/窗口、登录窗候选、guard.ini、日志
└─ bin/                       ← build.ps1 生成的 XLLoginGuard.exe（不随目录分发也没关系，安装时会自动编译）
```

安装后的运行位置：`%LOCALAPPDATA%\XLLoginGuard\`
（`XLLoginGuard.exe` + `guard.ini` + `guard.log`）。

---

## 4. 在新电脑上使用

前提：Windows 10/11，系统里带 .NET Framework 4.x（所有 Win10/11 默认都有），
迅雷是常规安装形态（`Thunder.exe` 所在目录里有 `Profiles\config.json`）。

```powershell
# 1) 把整个 xl-login-guard 目录复制到目标电脑
# 2) 在该目录下打开 PowerShell，执行：
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

脚本做五件事：编译 → 停掉旧实例 → 拷到 `%LOCALAPPDATA%\XLLoginGuard` → 写
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run\XLLoginGuard` → 立即启动守护。

**不需要管理员权限**，也不要求迅雷当时正在运行：下次它弹登录窗时就会被关掉。

想要换安装目录或调整参数：

```powershell
# 装到 D:\Tools\XLLoginGuard，并且这次不立即启动
.\scripts\install.ps1 -InstallDir 'D:\Tools\XLLoginGuard' -NoStart

# 你的迅雷登录窗标题不是「登录」（比如被改成英文 Login）
.\scripts\install.ps1 -TitleKeyword 'Login'
```

验证：关掉迅雷 → 重新打开 → 观察是否一出现就消失。日志里应能看到
`closing login window: title=[迅雷个人中心-登录] ...`。

### 开机自启动说明

安装时写的就是自启项，**重启电脑后无需任何操作，登录进桌面时会自动运行**：

- 位置：`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，值名 `XLLoginGuard`，
  值为 `"<安装目录>\XLLoginGuard.exe"`（带引号，路径含空格也安全）；
- 触发时机：**当前用户登录桌面时**，不是开机阶段。这一点是刻意的——迅雷本身也是登录后
  才运行、弹窗也只会出现在这个用户的桌面上，守护提前到 Windows 登录界面之前跑没有任何意义
  （SYSTEM 级的计划任务运行在其他会话里，反而看不到、也关不掉你桌面上的窗口）；
- 权限：纯用户级，不触发 UAC、不需要管理员；每个 Windows 账户各装各的
  （给别的账户装就再跑一次 `install.ps1`）；
- 自检：`scripts\diag.ps1` 里 `autostart:` 一行会打印当前登记的命令行；
- 若某个「电脑管家/安全卫士」拦住了自启项，可把安装目录加入白名单，或
  把 `XLLoginGuard.exe` 的快捷方式放进 `shell:startup`（启动文件夹），效果等价。

### 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1
# 想保留日志和配置：加 -KeepFiles
```

---

## 5. 参数（`%LOCALAPPDATA%\XLLoginGuard\guard.ini`）

UTF-8 文本，`key=value`，`#` 开头是注释。改完重启守护进程（或重跑 install.ps1）生效。

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `ProcessName` | `Thunder` | 窗口所属进程名（不含 `.exe`） |
| `TitleKeyword` | `登录` | 标题里必须包含的文字 |
| `ClassPrefix` | `Chrome_WidgetWin` | 窗口类名前缀 |
| `MinWidth` / `MinHeight` | `200` / `150` | 小于此尺寸的窗口忽略 |
| `StartupGraceSeconds` | `25` | 迅雷启动后多少秒内的登录窗无条件关闭 |
| `IdleThresholdMs` | `1500` | 超过宽限期后，需要空闲多久才关 |
| `PollIntervalMs` | `400` | 扫描间隔 |

---

## 6. 诊断：换了迅雷版本、弹窗又回来了怎么办

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\diag.ps1
```

只读，输出包括：迅雷进程及路径、所有相关窗口（类名/标题/尺寸/所属进程）、
**「LOGIN CANDIDATE」**（守护此刻会关哪个窗）、`Profiles\config.json` 里的
`LoginWndAutoShow` 当前值、守护是否在跑、自启项、`guard.ini`、日志末尾 10 行。

如果新版迅雷的弹窗标题或类名变了，`LOGIN CANDIDATE` 就不会列出它。此时：

1. 在弹窗出现时跑 `diag.ps1`，从窗口列表里找到那个窗口的标题/类名/尺寸；
2. 用 `install.ps1 -TitleKeyword '新标题里的关键词'` 重装，或直接改 `guard.ini`
   里的 `TitleKeyword`（必要时连 `ClassPrefix`、`MinWidth/MinHeight` 一起改）；
3. 重启守护进程后复查 `diag.ps1` 是否出现 `LOGIN CANDIDATE`。

---

## 7. 已验证环境

- Windows 10 22H2（19045），PowerShell 5.1
- 迅雷 11.3.12.1692（绿化版，安装在 `D:\Program Files\Thunder`，桌面快捷方式指向它）
- 实测三次重启迅雷全部命中，最快一次弹窗出现在进程启动 2 秒内即被关闭；
  关闭后窗口枚举只剩 `Chrome_WidgetWin_0 [迅雷]` 主窗 + `XL_ShadowWindow`

---

## 8. 常见问题

**Q：双击 `bin\XLLoginGuard.exe` 没反应？**
正常，它是无界面程序。看 `%LOCALAPPDATA%\XLLoginGuard\guard.log` 是否在写。

**Q：任务管理器里多了一个 XLLoginGuard.exe，占多少资源？**
常驻内存几 MB，每 400ms 做一次 `EnumWindows`，CPU 占用可忽略。

**Q：安全软件拦截自启项？**
自启写在 `HKCU\...\Run`，属于普通用户级自启；若被拦截，把安装目录加入白名单，
或把 `XLLoginGuard.exe` 放到「启动」文件夹（`shell:startup`）里。

**Q：我想要弹窗回来 / 临时停用？**
临时停用：结束 `XLLoginGuard.exe` 进程即可（自启项还在，下次登录又回来）。
彻底不要：跑 `scripts\uninstall.ps1`。

**Q：会影响迅雷下载或登录状态吗？**
不会。它只关那一个窗口，不碰进程、不碰网络、不碰 `Profiles` 里的任何文件。
唯一的行为变化是：对话框里的「登录」入口仍在，你自己点头像照样能登录。
