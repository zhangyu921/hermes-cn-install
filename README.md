# Hermes Agent — 中国大陆 Windows 安装脚本（PowerShell）

给 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 官方的 Windows 安装器换一套国内下载源。

**Windows + PowerShell 专用**，不是 bash 版，不是跨平台通用脚本。

**只改下载地址，不碰安装逻辑。** 官方的产物锁定、sha256 校验、失败回退顺序全部原样保留 —— 那部分本来就是对的。

---

## 平台要求

- **Windows 10 / 11**（x64 或 arm64）
- **Windows PowerShell 5.1** 或 PowerShell 7
- 不需要管理员权限

> **macOS / Linux / WSL 用不上这个** —— 那些平台请用官方 `install.sh`。
> 这个脚本存在的唯一理由，是 Windows 安装器里写死的那些境外下载地址。

---

## 为什么需要这个

官方 `install.ps1` 结构严谨：它锁定精确版本、对每个下载做 sha256 校验、还准备了备用 URL。问题只有一个 —— **那些 URL 全都指向国内访问不了的主机**。

实测数据（2026-10-31，中国大陆家宽）：

| 资源 | 大小 | 官方地址 | 实测 |
|---|---|---|---|
| 仓库 clone | 91.6 MB（浅克隆） | github.com | **36 KB/s** |
| PortableGit | 55.6 MB | github.com | **17 KB/s**（走代理）≈ 55 分钟 |
| uv | 2.8 MB | astral.sh | HTTP 200，但**传输中被强制断连** |
| Python 依赖 | ~57 MB | pypi.org | 超时 |

> 仓库完整历史是 1.35 GB，浅克隆（`--depth 1`）也要 91.6 MB。浅克隆**保留完整的 `git pull` 能力**，所以 `hermes update` 不受影响。

### 换成什么

| 资源 | 换成 | 实测 |
|---|---|---|
| 仓库 | **cnb.cool**（腾讯） | **28 MB/s，不到 1 分钟** |
| PortableGit | **registry.npmmirror.com** | **1.18 MB/s，47 秒** |
| uv | **ghproxy.net** | 40 秒内完成 |
| pip / Node / npm | 清华 / npmmirror | 官方安装器已内置 |

### 试过但不可用的路线

记录在这里，省得后来的人重复踩：

- `gitclone.com` — 502
- `ghfast.top` — 无响应
- `mirror.ghproxy.com` — 已停止服务
- `releases.astral.sh` — 能连上，传输被重置
- `mirrors.huaweicloud.com/uv/` — 任意路径都返回同一个 HTML 错误页（12434 字节，看到这个数字就是没成）
- GitHub 加速代理 — 小文件能用，大文件一律断流（`early EOF`）。91.6 MB 的仓库实测 5–48 KB/s 且多次中断

---

## 用法

**1. 下载脚本**（在 PowerShell 里）：

```powershell
cd $HOME\Downloads
Invoke-WebRequest -Uri https://raw.githubusercontent.com/zhangyu921/hermes-cn-install/main/install-cn.ps1 -OutFile install-cn.ps1
```

**2. 运行**：

```powershell
powershell -ExecutionPolicy Bypass -File .\install-cn.ps1
```

或者一行搞定（下载后立刻运行）：

```powershell
powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/zhangyu921/hermes-cn-install/main/install-cn.ps1 -OutFile $env:TEMP\hermes-cn.ps1; & $env:TEMP\hermes-cn.ps1"
```

> `-ExecutionPolicy Bypass` 只对这一次进程生效，不改系统设置。

### 参数

| 参数 | 作用 |
|---|---|
| `-SkipSetup` | 跳过交互式配置向导，之后自己运行 `hermes setup` |
| `-Channel main` | 跟踪 main 分支（默认 stable） |
| `-PatchOnly` | 只下载并打补丁，保存后停止 —— 用来检查到底改了什么 |
| `-OutFile <路径>` | 指定补丁后的脚本保存位置 |

### 装完之后

```powershell
# 关掉当前终端，开一个新的（PATH 在启动时读取）
hermes
```

第一次用要先配置：

```powershell
hermes setup
```

---

## 工作原理

脚本按顺序做四件事：

1. 下载官方 `install.ps1`（三个源依次尝试）
2. **按锚点精确改写下载层** —— 每个锚点必须恰好匹配一次，否则中止
3. 校验改写后的脚本能通过 PowerShell 语法解析
4. 执行

### 锚点校验

如果上游重构了脚本结构，**宁可报错退出，也不输出一个半成品**。

原因很实际：漏改一个 URL 不会报错，只会安静地卡在 github.com 上，看起来像是网络问题 —— 排查方向从一开始就错了。

### 改了哪五处

```powershell
# 1-4. 产物 pin（uv × 2 架构，Git × 2 架构）
$script:UvPinFiles = @{
    "win32-x64" = @{
        Url       = "https://ghproxy.net/https://github.com/astral-sh/uv/..."  # 改这里
        MirrorUrl = "https://hermes-assets.nousresearch.com/..."              # 国内不可达
        Sha256    = "a38b8d19..."                                             # 未改动
    }
}

# 5. 仓库 clone：从 cnb.cool 拉，但 origin 指回 GitHub
$RepoUpstream = "https://github.com/NousResearch/hermes-agent.git"
$RepoMirror   = "https://cnb.cool/hermesagent-cn/hermes-agent-cn-mirror.git"
```

另外在 `Invoke-VerifiedDownload` 的候选列表里插入了国内镜像，排在官方那个不可达的备用地址**之前** —— 单个镜像抖动不再导致整体失败。

### sha256 一个都没少

每个候选地址下载完都要过 sha256。镜像给出错误的字节会**明确报错**，不会装进去。

### origin 为什么指回 GitHub

clone 走镜像（快），但 clone 完把 `origin` 改回上游 —— 这样 `hermes update` 跟随的是官方仓库，不是镜像。镜像只是搬运工，不接管更新。

---

## 会改动的系统位置

| 位置 | 内容 | 可逆 |
|---|---|---|
| `%LOCALAPPDATA%\hermes\` | 安装目录 | 删除即卸载 |
| `%APPDATA%\pip\pip.ini` | pip 镜像 | 可删 |
| `%APPDATA%\uv\uv.toml` | uv 索引 | 可删 |
| `%USERPROFILE%\.npmrc` | npm 镜像 | 可删 |
| User PATH | `%LOCALAPPDATA%\hermes\bin` | 手动移除 |

**全部是用户级，不需要管理员权限，不写注册表，不改系统 PATH。**

---

## 已知坑（都真踩过）

### 1. PowerShell 5.1 的 `-Encoding UTF8` 会写 BOM

```
UnicodeDecodeError: 'gbk' codec can't decode byte 0xbf in position 2
```

Python 的 `configparser` 用本地编码（中文 Windows 是 GBK）读 `pip.ini`，BOM 直接让它崩。PowerShell 5.1 没有 `utf8NoBOM` 选项，只能显式指定编码：

```powershell
[System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
```

### 2. `$args` 和 `$home` 是 PowerShell 的自动变量

用它们当变量名会静默出错（`$home` 直接报 `VariableNotWritable`）。换个名字。

### 3. `Join-Path` 不能拼 URL

会抛 `Cannot find drive 'https'`。字符串拼接。

### 4. `Select-String -Path <不存在的文件> -Quiet` 返回 `$true`

所以「是否已配置」的检查必须先 `Test-Path`。

### 5. 探测网络时要显式关掉代理

注册表里残留的 `ProxyServer`（哪怕 `ProxyEnable=0`）会让 .NET 把所有请求发往一个死端口，结果看起来是「所有站点都不通」：

```powershell
$req.Proxy = $null
```

### 6. `irm ... | iex` 拿到的可能是 `byte[]`

文本响应有时会变成字节数组，`iex` 会把 ASCII 码当代码解析，报 `unexpected token 110` 之类的怪错。先 `-OutFile` 存文件再执行。

---

## 卸载

```powershell
# 1. 删除安装目录
Remove-Item "$env:LOCALAPPDATA\hermes" -Recurse -Force

# 2. 删除镜像配置
Remove-Item "$env:APPDATA\pip\pip.ini"
Remove-Item "$env:APPDATA\uv\uv.toml"
Remove-Item "$env:USERPROFILE\.npmrc"

# 3. 手动从 User PATH 移除 %LOCALAPPDATA%\hermes\bin
```

---

## 适用范围

- **Windows 10/11 x64 或 arm64**
- 已验证：Windows 11 22621 / PowerShell 5.1 / Python 3.14.9 / Hermes v0.22.5
- 大版本升级后上游可能改动脚本结构 —— 那时脚本会因为锚点不匹配而**主动中止**，看到这个报错说明该更新补丁了

---

## 参考

- Hermes Agent：https://github.com/NousResearch/hermes-agent
- 官方安装文档：https://hermes-agent.nousresearch.com/docs

## License

MIT
