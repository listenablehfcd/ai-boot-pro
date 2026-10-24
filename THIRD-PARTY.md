# 第三方组件与商标声明

本项目自身以 MIT 许可证发布（见 [LICENSE](LICENSE)）。
分发的镜像与字体中包含第三方组件，其版权与许可证归各自所有者，说明如下。

## 中文字体（GPL v2+）

`share/aiboot-cjk.psf.gz` 是从 **GNU Unifont** 生成的**修改版子集**
（截取子集 + 转换为 Linux 控制台 PSF2 格式）。

- 上游：GNU Unifont — https://unifoundry.com/unifont/
- 许可证：**GNU GPL v2 或更高版本**，附
  [GNU font embedding exception](https://unifoundry.com/LICENSE.txt)
- **关于字体嵌入例外**：该例外针对把字体"嵌入文档"的场景。本镜像把字体作为**功能性组件**
  随系统分发，因此**不依赖该例外**，字体本身按 **GPL v2+** 对待。
- **对应源码与复现方法**（GPL v2 §3）：见 [`font/`](font/README.md)
  - `font/mkfont.py` —— 生成脚本
  - `font/chars.txt` —— 收录的码点清单，可精确复现同一子集
  - 复现步骤：
    ```bash
    wget https://unifoundry.com/pub/unifont/unifont-15.1.05/font-builds/unifont.hex.gz
    gunzip unifont.hex.gz
    python3 font/mkfont.py unifont.hex share/aiboot-cjk.psf.gz
    ```
  - 上游源码亦可通过 Debian 的 `unifont` 源码包获取

**许可关系说明**：本仓库的**原创代码**采用 MIT；上述字体为**独立的 GPL v2+ 组件**，
二者属**聚合分发**，互不影响。转载或再分发本仓库时，请同时遵守字体部分的 GPL v2+。

## 镜像中的 Debian 组件

发布的可引导镜像基于 **Debian Live 13** 构建，其中包含大量 Debian 软件包
（内核、GNU 工具链、OpenSSH、wpa_supplicant、hostapd、dnsmasq、ntfs-3g 等）。

- 每个软件包遵循其各自的许可证（以 GPL 系列为主，亦含 MIT/BSD/Apache 等）
- 各包的版权与许可证全文随镜像分发，位于镜像内 `/usr/share/doc/<包名>/copyright`
- 对应的完整源代码可从 Debian 官方镜像获取：https://www.debian.org/distrib/packages
- 本项目对 Debian 组件未作修改，仅将其重新打包进自制的可引导镜像

## 商标

本项目为独立项目，与下列组织**无隶属关系，亦未获其背书**：

- **Windows**、**Windows PE**、**Microsoft** 是 Microsoft Corporation 的商标或注册商标。
  本项目仅在**描述性**语境下提及这些名称（说明适用场景与对比），不表示任何关联或授权。
- **Debian** 是 Software in the Public Interest, Inc. 的注册商标。本项目是 Debian Live 的衍生品，
  不是 Debian 官方项目。
- **Linux** 是 Linus Torvalds 的注册商标。
- **Rufus**、**balenaEtcher**、**Ventoy** 等写入工具的名称与商标归各自所有者，
  本项目仅作推荐与说明之用，与它们无隶属关系。
- 文中出现的其它名称可能是其各自所有者的商标。

## 无担保

以上第三方组件均按"现状"提供，本项目作者不对其适用性或无缺陷性作任何担保。
详见 [README](README.md) 顶部的免责与法律声明。

## 使用提醒（不属于 MIT 条款）
额外提醒（不属于 MIT 条款，但请务必知悉）：
本软件是"救援工具"，会以 root 权限运行在真实机器上，且包含会清空磁盘的操作。
请勿在有重要数据的机器上试错；执行任何写盘/格式化操作前务必确认目标设备。
