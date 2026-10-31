# hermes-cn-install

Hermes Agent 的 Windows 安装器在中国大陆网络下的可用版本。

上游 `install.ps1` 的下载层全部指向无法访问的主机。本项目**只替换 URL**，不改动安装逻辑——产物 pin、sha256 校验、回退顺序一律保留。

**仅 Windows + PowerShell**（5.1 / 7）。macOS、Linux、WSL 请用官方 `install.sh`。

## 用法

```powershell
iwr https://raw.githubusercontent.com/zhangyu921/hermes-cn-install/main/install-cn.ps1 -OutFile install-cn.ps1
powershell -ExecutionPolicy Bypass -File .\install-cn.ps1
```

装完后开新终端：

```powershell
hermes setup
hermes
```

参数：

| 参数 | 说明 |
|---|---|
| `-SkipSetup` | 跳过配置向导 |
| `-Channel main` | 跟踪 main（默认 stable） |
| `-PatchOnly` | 只生成补丁，不安装 |
| `-OutFile <path>` | 补丁输出路径 |

## 实测

大陆家宽，2026-10-31。

| 资源 | 大小 | 上游 | 本项目 | 结果 |
|---|---|---|---|---|
| 仓库 | 91.6 MiB¹ | github.com | cnb.cool | 36 KB/s → 28 MB/s |
| PortableGit | 55.6 MiB | github.com | npmmirror | 17 KB/s → 1.18 MB/s |
| uv | 2.8 MiB | astral.sh | ghproxy.net | reset → <40 s |
| Python 依赖 | ~57 MiB | pypi.org | 清华 | timeout → ok |

¹ 完整历史 1.35 GiB。`--depth 1` 保留 `git pull`，`hermes update` 不受影响。

以下路线经测试不可用，不再尝试：`gitclone.com`(502)、`ghfast.top`、`mirror.ghproxy.com`、`releases.astral.sh`(传输重置)、`mirrors.huaweicloud.com/uv/`(任意路径返回同一 12434 字节错误页)、GitHub 代理(大文件 `early EOF`)。

## 实现

1. 拉取上游 `install.ps1`（三个源依次尝试）
2. 按锚点替换下载层，**每个锚点必须恰好匹配一次**
3. `Parser::ParseInput` 校验语法
4. 执行

锚点失配时中止，不输出半成品。原因：漏改的 URL 不会报错，只会静默卡在 github.com 上，排查方向从一开始就是错的。

改动点：

```powershell
# 产物 pin ×4（uv / Git，各双架构）
"win32-x64" = @{
    Url       = "https://ghproxy.net/https://github.com/astral-sh/uv/..."  # ←
    MirrorUrl = "https://hermes-assets.nousresearch.com/..."              # 国内不可达
    Sha256    = "a38b8d19..."                                             # 不变
}

# 仓库 clone
$RepoUpstream = "https://github.com/NousResearch/hermes-agent.git"
$RepoMirror   = "https://cnb.cool/hermesagent-cn/hermes-agent-cn-mirror.git"
```

另在 `Invoke-VerifiedDownload` 的候选列表中插入国内源，位置在官方那个不可达的 fallback 之前。单个镜像抖动不再导致整体失败。

**sha256 校验未做任何放宽。** 镜像返回错误字节时失败退出。

clone 完成后 `origin` 重写回 GitHub，`hermes update` 跟随上游而非镜像。

## 系统改动

| 路径 | 内容 |
|---|---|
| `%LOCALAPPDATA%\hermes\` | 安装目录 |
| `%APPDATA%\pip\pip.ini` | pip 索引 |
| `%APPDATA%\uv\uv.toml` | uv 索引 |
| `%USERPROFILE%\.npmrc` | npm registry |
| User PATH | `%LOCALAPPDATA%\hermes\bin` |

均为用户级，无需管理员权限，不写注册表。

## 已知问题

**PowerShell 5.1 的 `-Encoding UTF8` 写入 BOM。** Python `configparser` 按 locale 解码（中文 Windows 为 GBK），BOM 触发 `UnicodeDecodeError: 'gbk' codec can't decode byte 0xbf`，依赖安装中断。5.1 无 `utf8NoBOM` 选项：

```powershell
[System.IO.File]::WriteAllText($p, $s, (New-Object System.Text.UTF8Encoding($false)))
```

其余踩坑记录：

- `$args`、`$home` 是自动变量，用作变量名会静默出错
- `Join-Path` 不能拼接 URL（`Cannot find drive 'https'`）
- `Select-String -Path <不存在的文件> -Quiet` 返回 `$true`，检查前先 `Test-Path`
- 探测网络需 `$req.Proxy = $null`；注册表残留的 `ProxyServer` 会让所有请求发往死端口
- `irm | iex` 可能拿到 `byte[]`，解析出 `unexpected token 110` 之类的错误

## 卸载

```powershell
Remove-Item "$env:LOCALAPPDATA\hermes" -Recurse -Force
Remove-Item "$env:APPDATA\pip\pip.ini", "$env:APPDATA\uv\uv.toml", "$env:USERPROFILE\.npmrc"
# User PATH 中手动移除 %LOCALAPPDATA%\hermes\bin
```

## 已验证

Windows 11 22621 / PowerShell 5.1 / Hermes v0.22.5 / Python 3.14.9，`Install method: git`。

上游脚本结构变更会导致锚点失配并中止，此时需要更新 `$swaps`。

## License

MIT
