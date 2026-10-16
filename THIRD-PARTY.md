# 第三方组件与商标声明

本项目自身以 MIT 许可证发布（见 [LICENSE](LICENSE)）。
分发的镜像与字体中包含第三方组件，其版权与许可证归各自所有者，说明如下。

## 中文字体

`share/aiboot-cjk.psf.gz` 是从 **GNU Unifont** 生成的**子集**（仅保留界面实际用到的字形，
并转换为 Linux 控制台 PSF2 格式）。

- 上游：GNU Unifont — https://unifoundry.com/unifont/
- 许可证：**GNU GPL v2 或更高版本，并附字体嵌入例外（GNU font embedding exception）**
- 完整许可证文本见 https://www.gnu.org/licenses/gpl-2.0.html 与
  https://unifoundry.com/LICENSE.txt
- 由于本项目分发的是**修改后的版本**（子集 + 格式转换），按 GPL 要求在此声明来源与修改内容。
  生成脚本为 `tools/mkfont.py`（若随源码分发）。

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
