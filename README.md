# AI Boot Pro

> 把 U 盘插到开不了机的电脑上，让远程的人或 AI 接进来。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-BIOS%20%7C%20UEFI-lightgrey.svg)](#运行要求)
[![Base](https://img.shields.io/badge/base-Debian%20Live%2013-red.svg)](https://www.debian.org/)

---

## ⚠️ 请先阅读：免责与法律声明

**本节是全文最重要的部分。使用本项目即表示你已阅读、理解并接受以下全部内容。**

1. **本项目按"现状"提供，不附带任何形式的担保。** 包括但不限于对适销性、特定用途适用性
   及不侵权的默示担保。作者与贡献者**不对任何直接、间接、附带、特殊、惩罚性或后果性损害
   承担任何责任**，无论其如何产生、基于何种责任理论，也无论是否已被告知此类损害的可能性。

2. **本系统以 root 权限运行在真实计算机上。** 它可以读写磁盘、修改系统文件、挂载文件系统、
   执行任意命令。它包含会**清空磁盘**的操作（写入镜像、格式化、写盘工具）。

3. **这些操作没有撤销机制，也没有回收站。** 写错目标设备会直接、永久地破坏该设备上的数据。
   执行任何写盘或格式化操作前，**你必须自行确认目标设备**。

4. **风险由使用者自行承担。** 你需要在"能救回数据"与"可能造成进一步损失"之间自行判断。
   如果机器上有唯一一份重要数据，请优先考虑先把数据复制出来，而不是先修系统。

5. **远程接入意味着把机器的控制权交给网络另一端。** 系统会生成随机密码并显示在屏幕上，
   任何看到该屏幕与密码的人都可以登录并获得 root 权限。请勿在不可信环境中使用。

6. **本项目与 Debian 项目无隶属关系。** 它是基于 Debian Live 构建的衍生品，
   Debian 的名称与标识归其各自所有者。详见下文"与 Debian 的关系"。

---

## 这是什么

AI Boot Pro 是一个基于 **Debian Live 13** 构建的救援启动盘系统。

把它写入 U 盘，插到一台开不了机的电脑上启动，系统会自动尝试联网、启动 SSH 服务，
并把 IP、端口、用户名和密码显示在屏幕上。之后远程的人员或 AI 就可以登录进来排查故障、
抢救数据、修复引导。

界面是纯文本的，不需要图形环境，也不依赖显卡驱动。

---

## 适用场景

**远程处理系统故障。** 电脑出故障时，具备处理能力的人常常不在现场。现场人员只需插上 U 盘、
开机并从 U 盘引导，剩下的由系统与远程人员完成。

**由 AI 处理需要大量知识或反复试错的故障。** 例如修复 Windows 引导记录、清理异常启动项、
修改注册表以关闭反复失败的自动更新、排查驱动或更新引起的循环重启。
这类问题往往需要一边查资料一边试，AI 在这方面通常比现场人员更有效率。

**与 Windows PE 相比更合适的情形。** Windows PE 对非 Windows 文件系统的读写能力有限，
对较新的存储设备与文件系统的支持也滞后；它的运行环境依赖 Windows 组件，
在故障机器上稳定性不佳。AI Boot Pro 运行完整的 Linux 环境，可直接读写 NTFS、ext4、
XFS、Btrfs 等文件系统，也不受原系统状态影响。

**老旧机器。** 完整版镜像约 2 GB，Slim 版小于 2 GB；系统启动后不需要图形界面，
内存占用低。在只有 1 GB 内存、老式 CPU 的机器上同样可用。

---

## 运行要求

| 项目 | 要求 |
|---|---|
| 底子 | Debian Live 13（当前基于 13.6，amd64） |
| 引导方式 | 传统 BIOS 与 UEFI 均可 |
| 内存 | 建议 1 GB 以上（系统本身占用很低） |
| U 盘 | ≥ 4 GB |
| 显示 | 任意文本模式控制台；不需要图形界面与专用显卡驱动 |
| 网络 | BIOS/UEFI 支持的有线网卡、常见无线网卡，或手机热点 |

系统在以下情况仍可运行：原系统盘完全损坏、无操作系统、无网络驱动、显卡驱动异常。

---

## 下载与写入

Releases 提供 Slim 版镜像（小于 2 GB，**单个完整文件**，下载后可直接写入）。

| 写入工具 | 平台 |
|---|---|
| [Rufus](https://rufus.ie/) | Windows |
| [balenaEtcher](https://etcher.balena.io/) | Windows / macOS / Linux |
| [Ventoy](https://www.ventoy.net/) | 跨平台，支持多 ISO 共存 |
| `dd` | Linux / macOS |

```bash
sudo dd if=AI-Boot-Pro-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

> `of=` 必须指向整块设备（`/dev/sdb`），不能是分区（`/dev/sdb1`）。写错目标盘会直接
> 破坏其上的数据，且无法撤销。

写入前建议核对 MD5，正确值列于对应 Release 的说明中。

---

## 使用

开机时按启动菜单键（F12 / F11 / F8 / ESC，视机型而定），选择 U 盘。

主菜单分为三栏：

**整体配置** —— 用于把机器接入网络。

- **急救模式**：无需任何输入。系统依次尝试 U 盘上的配置、有线网络、上次连接成功的 WiFi、
  手机热点，最后自行创建一个热点供其他设备接入。每一步的结果与下一步动作都显示在屏幕上。
- **引导配置**：面向可以使用键盘鼠标的场景，通过递进提问确定联网方式，条件由宽到严逐步收紧。
  每种方式都会实际尝试，并验证是否真正能够访问互联网。

**单独配置** —— 按需使用单个功能：SSH、WiFi、密码文件、命令行、Windows 工具、文件浏览、
备份、自检。

**设置** —— 配置总开关、自动保存、逐项修改配置、界面语言（中文 / 英文）、帮助。

联网成功后屏幕显示连接信息：

```
IP        : 192.168.1.23
port      : 22
user      : ai
password  : 8246391052736481
```

```bash
ssh -p 22 ai@192.168.1.23
```

登录后应先阅读 `/usr/local/share/ai-boot/AI-README.txt`。该文件面向远程 AI，
说明可用工具、操作范围与安全约束。提权使用 `sudo su -`（免密）。

---

## 与 Debian 的关系

AI Boot Pro 是 **Debian Live 的衍生品**，不是 Debian 官方项目，也未获 Debian 项目背书。

- 系统底子（内核、initrd、大部分用户空间软件）来自 Debian Live 13 amd64 standard 镜像
- 本项目在此基础上追加救援界面与自动化流程，并以相同方式重新打包为可引导镜像
- Debian 是 Software in the Public Interest, Inc. 的注册商标
- 各 Debian 软件包遵循其各自的许可证，详见镜像内 `/usr/share/doc/*/copyright`

---

## 已知限制

- 不做图形界面。所有操作在文本控制台完成。
- 不会主动修改原系统。救援界面本身只读取信息；对目标磁盘的写入仅在用户明确选择后发生。
- 远程接入需要机器能够联网。完全无法联网时，系统只能提供本地指引。
- 引导配置中的"手机 USB 共享"依赖手机与内核驱动的配合，并非所有机型都可用。
- 中文界面使用 512 字形控制台字体，界面用字受字形数量限制（约 415 个汉字）。
- 本项目只维护当前版本；历史版本不再更新，也不在本仓库中。

---

## 安全与责任边界

**系统会做什么**：以 root 运行；自动配置网络；生成随机密码并启动 sshd；
读写你指定的磁盘；执行你通过界面或 SSH 发起的命令。

**系统不会做什么**：不会在未经选择的情况下格式化或写入磁盘；
不会把密码或账号上传到任何服务器；不含遥测与回传。

**对远程 AI 的硬性约束**：随镜像发布的 `AI-README.txt` 中规定了若干必须遵守的规则，
其中最重要的是：不得删除或覆盖任何数据文件；不得写块设备或修改分区表；
诊断默认只读；任何改动前先说明并获得确认。

**这些约束依赖使用者的监督。** 系统提供了监视页，可随时断开会话、暂停 AI、查看日志、
进入 root 命令行或急停（断开会话并停止 sshd）。

---

## 从源码构建

环境要求：Linux（无需 root）、`xorriso`、`squashfs-tools-ng`，
以及一份 Debian Live 13 amd64 **standard** ISO 作为底子。

```bash
sudo apt-get install -y xorriso squashfs-tools-ng

# 准备底子
cp /path/to/debian-live-13.x.x-amd64-standard.iso base.iso
mkdir -p work/newiso
xorriso -osirrox on -indev base.iso -extract / work/newiso
cp work/newiso/live/filesystem.squashfs base.squashfs

# 把 src/ etc/ share/ 覆盖进解开的 rootfs，再重新打包
# （完整步骤与注意事项见构建脚本中的注释）
```

需要注意的几点：

- **不要复用上一次的构建产物作为底子**，否则历次改动会层层叠加。
- **不要用 `tar --delete` 删除文件**：GNU tar 会一并丢弃 PAX 长文件名头，
  导致一批文件被静默改名。
- **非 root 解包会丢失 setuid / setgid 位**，`passwd`、`sudo`、`mount` 等文件需重新设置权限。
- **`/run` 是 tmpfs**：放入镜像 `/run/` 下的文件在启动后会被覆盖，
  面向用户或 AI 的文件应放在 `/usr/local/share/` 下。

---

## 参与

问题与建议请通过 Issues 提出。提交改动前，建议在真机或虚拟机中实际引导并逐屏检查，
并通过 SSH 真实登录走一遍远程流程；仅做文件层面的检查不足以确认系统可用。

---

## 许可证

[MIT](LICENSE)

镜像中包含的 Debian 组件遵循其各自的许可证。

---

## 第三方组件与商标

本仓库以 MIT 发布，但分发的镜像中包含第三方组件，其中一项需要特别说明：

- **中文字体**（`share/aiboot-cjk.psf.gz`）是从 **GNU Unifont** 生成的子集，
  遵循 **GPL v2+ 并附字体嵌入例外** —— 详见 [THIRD-PARTY.md](THIRD-PARTY.md)
- **镜像中的 Debian 组件**遵循各自许可证，版权与许可证全文随镜像分发
  （镜像内 `/usr/share/doc/<包名>/copyright`），源代码可从 Debian 官方镜像获取

**商标**：`Windows`、`Windows PE`、`Microsoft` 是 Microsoft Corporation 的商标或注册商标，
本项目仅在描述性语境下提及；`Debian` 是 Software in the Public Interest, Inc. 的注册商标；
`Linux` 是 Linus Torvalds 的注册商标。本项目与上述组织**无隶属关系，亦未获其背书**。
完整声明见 [THIRD-PARTY.md](THIRD-PARTY.md)。
