# hebing · OpenWrt 双网关统一域名脚手架

> 借鉴 [fn-knock-turborepo](https://github.com/tianlmm/fn-knock-turborepo) 的 OpenWrt 打包方案，
> 精简为仅 **x86_64 (AMD64)** 架构、仅 **tar 容器**的通用脚手架，
> 服务于"双网关统一域名"架构：**有 IPv6 → DDNS 直连；无 IPv4 → Cloudflare Tunnel 穿透**。

---

## 架构一句话

```
客户端 → a.c.xxx → { 有 v6 → DDNS AAAA 直连 / 仅 v4 → CF Tunnel A 穿透 } → FPK 入口容器
```

- AAAA 记录（灰云 DNS only）：DDNS 实时同步 NAS 公网 IPv6，直连、最快、不经过任何第三方
- A 记录（橙云 Proxied）：Cloudflare Tunnel 兜底，让纯 v4 客户端也能访问，自带 CDN + DDoS 防护
- FPK 入口容器：两条链路最终都收敛到同一个反代收口做 TLS 终止和后端路由

## 文档

| 文档 | 内容 |
|---|---|
| [docs/dual-network-guide.html](docs/dual-network-guide.html) | 架构说明书 · 含原始 SVG 图 |
| [docs/operations-guide.html](docs/operations-guide.html) | 全程 **GUI 点击**操作流程（LuCI + CF Zero Trust + 飞牛），**零 SSH** |

## 目录结构

```
hebing/
├── deploy/openwrt/            # OpenWrt 包模板（装进 .ipk 的内容）
│   ├── control/               # control 元数据 + 生命周期钩子
│   │   ├── postinst            # 安装/升级后：enable + restart
│   │   ├── prerm               # 卸载前：stop 服务，停不下来拒绝卸载
│   │   ├── postrm              # 卸载后：清理 LuCI 缓存
│   │   ├── conffiles           # 标记 /etc/config/hebing 为用户配置文件
│   │   └── control.example     # control 元数据长啥样（打包时动态生成）
│   ├── etc/config/hebing      # UCI 默认配置
│   ├── etc/init.d/hebing       # procd 启动脚本（respawn 自动拉起）
│   ├── usr/bin/                # 辅助命令
│   └── usr/libexec/            # 迁移脚本等
├── scripts/
│   ├── build-ipk.sh            # 精简版 .ipk 打包脚本（仅 x86_64 / 仅 tar 容器）
│   └── release.py               # 一键自动发布到 GitHub Releases
└── .gitignore
```

## 快速开始

### 1. 准备好你的 x86_64 Linux ELF 二进制

脚手架里 `dist/bin/hebing` 是一个 Python 生成的 mock 二进制（验证用，只 exit 0）。生产部署请替换成你真实构建的 hebing：

```bash
file dist/bin/hebing
# 期望输出包含: ELF 64-bit LSB executable, x86-64
```

### 2. 打 .ipk

```bash
bash scripts/build-ipk.sh
# 产出: dist/openwrt/hebing_0.1.0-1_x86_64.ipk
```

可选环境变量：

```bash
VERSION=1.2.3 APP_NAME=myapp DEPENDS="libc, curl" bash scripts/build-ipk.sh
```

### 3. 自动发布到 GitHub Releases

```bash
GITHUB_TOKEN=<你的PAT> python3 scripts/release.py
```

可选覆盖：`GITHUB_REPO`, `GITHUB_TAG`, `GITHUB_IPK`。已存在同名 asset 会自动删了重传。

## 在 OpenWrt 上安装（GUI）

1. 浏览器打开 LuCI → **系统 → 软件包 → 上传软件包**
2. 选 `hebing_0.1.0-1_x86_64.ipk` → 上传并安装
3. **服务 → hebing** 查看/重启/改配置

具体配置步骤看 [docs/operations-guide.html](docs/operations-guide.html)。

## 在 OpenWrt 上安装（命令行）

```bash
opkg install /tmp/hebing_0.1.0-1_x86_64.ipk
/etc/init.d/hebing status
```

## control 钩子做了什么

| 钩子 | 时机 | 行为 |
|---|---|---|
| `postinst` | 安装/升级后 | `enable` + `restart`，刷新 LuCI 索引缓存 |
| `prerm` | 卸载/升级前 | `stop` 服务；**停不下来返回 1 → opkg 拒绝卸载** |
| `postrm` | 卸载后 | 清临时目录，重启 rpcd |
| `conffiles` | 卸载时 | `/etc/config/hebing` 被标记为配置文件，卸载后**保留**用户改动 |

`postinst` / `prerm` / `postrm` 都会在 `$IPKG_INSTROOT` 非空（离线安装）时提前 `exit 0`，避免污染宿主机。

## .ipk 内部结构

OpenWrt 的 .ipk 现在主流是 **tar 容器**（不是 ar）：

```
hebing_0.1.0-1_x86_64.ipk        (gzip 压缩的 tar)
├── debian-binary                 # 内容就是 "2.0\n"
├── control.tar.gz                # control 元数据 + 钩子脚本
│   ├── control                   # Package / Version / Architecture / Depends ...
│   ├── conffiles
│   ├── postinst / prerm / postrm
└── data.tar.gz                   # 实际安装到 rootfs 的文件
    ├── etc/config/hebing
    ├── etc/init.d/hebing
    ├── usr/lib/hebing/bin/hebing # 你的二进制
    ├── usr/lib/hebing/hebing     # 软链 → ../bin/hebing
    └── usr/libexec/...
```

`build-ipk.sh` 会强制校验：
- 所有条目 **owner=root:root**（opkg 硬性要求）
- 二进制是 **Linux x86_64 ELF**
- control 元数据字段完整
- 关键文件都在（init.d / config / binary 软链）

## 为什么要借鉴 fn-knock

[fn-knock-turborepo](https://github.com/tianlmm/fn-knock-turborepo) 有一套非常扎实的 OpenWrt 打包流水线：多架构矩阵交叉编译、tar/ar 双容器支持、procd init.d、生命周期钩子、iStore 元数据、完整的 ELF 架构 + 所有者校验。这个脚手架**只保留核心骨架**，去掉了 Rust 交叉编译、Go 网关打包、LuCI 前端、iStore APK 等不需要的东西，让你能"往里塞自己的二进制就能跑"。

## License

MIT
