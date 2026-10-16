# 中文字体子集（GPL v2+）

`../share/aiboot-cjk.psf.gz` 是 Linux 控制台字体（PSF2，512 字形，16×16 中文 / 8×16 英文），
由 **GNU Unifont** 生成的**修改版子集**。

## 许可证与来源

- 上游：**GNU Unifont** — https://unifoundry.com/unifont/
- 上游许可证：**GNU GPL v2 或更高版本**，并附
  [GNU font embedding exception](https://unifoundry.com/LICENSE.txt)
- 本文件是**修改后的版本**：从 Unifont 全量字形中**截取子集**，并**转换格式**为 PSF2。
  按 GPL v2 §3 的要求，在此提供对应的完整源码与复现方法（见下）。
- 关于"字体嵌入例外"：该例外用于把字体**嵌入文档**的场景。本镜像把字体作为**功能性组件**
  随系统分发，因此**不依赖该例外**，字体本身按 **GPL v2+** 对待。
  本仓库其余原创代码为 MIT，二者互不影响（属聚合分发）。

## 如何复现这个字体（对应源码）

```bash
# 1) 取 Unifont 的源码字形（hex 格式，即 GPL 意义上的"对应源码"）
wget https://unifoundry.com/pub/unifont/unifont-15.1.05/font-builds/unifont.hex.gz
gunzip unifont.hex.gz

# 2) 用本目录的脚本重新生成完全相同的子集
python3 mkfont.py unifont.hex ../share/aiboot-cjk.psf.gz
```

`mkfont.py` 会：
1. 按固定顺序分配 512 个字形槽位（ASCII 区用 8×16 拉伸，CJK 区用 16×16）
2. 只收录 `chars.txt` 中列出的码点（即界面实际用到的字符）
3. 写出 PSF2 格式并 gzip

* 生成脚本：`mkfont.py`
* 字符清单（可精确复现同一子集）：`chars.txt`
* 上游源码获取途径：https://unifoundry.com/unifont/ （或 Debian 的 `unifont` 源码包）
