#!/usr/bin/env python3
"""一键自动发布 hebing OpenWrt .ipk 到 GitHub Releases"""
import json, os, sys, urllib.request, urllib.error

TOKEN = os.environ["GITHUB_TOKEN"]
REPO  = os.environ.get("GITHUB_REPO", "tianlmm/hebing")
TAG   = os.environ.get("GITHUB_TAG", "v0.1.0")
IPK   = os.environ.get("GITHUB_IPK", "dist/openwrt/hebing_0.1.0-1_x86_64.ipk")

API = f"https://api.github.com/repos/{REPO}"

def gh(path, method="GET", data=None, accept="application/vnd.github+json"):
    body = json.dumps(data).encode() if isinstance(data, (dict, list)) else data
    req = urllib.request.Request(
        API + path, data=body,
        headers={"Authorization": f"token {TOKEN}",
                 "Accept": accept,
                 "Content-Type": "application/json",
                 "User-Agent": "hebing-release"},
        method=method)
    try:
        with urllib.request.urlopen(req) as r:
            return r.getcode(), json.loads(r.read().decode()) if r.length else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:400]
        print(f"❌ HTTP {e.code}  {path}\n{detail}", file=sys.stderr)
        return e.code, None

# 1) 检查 tag 是否已存在
code, _ = gh(f"/git/refs/tags/{TAG}")
release_existed = (code == 200)

# 2) 创建或获取 release
body_md = """## 这是什么
借鉴 [fn-knock](https://github.com/tianlmm/fn-knock-turborepo) 的 OpenWrt 打包脚手架（精简到仅 x86_64 / 仅 tar 容器），服务于"双网关统一域名"架构：IPv6 走 DDNS 直连、IPv4 走 Cloudflare Tunnel 兜底。

## 架构
```
客户端 → a.c.xxx → { 有 v6 → DDNS AAAA 直连 / 仅 v4 → CF Tunnel A 穿透 } → FPK 入口容器
```

## 本仓库内容
- `deploy/openwrt/`     完整包模板（control 钩子 / UCI / procd init）
- `scripts/build-ipk.sh` 可复用打包脚本：`bash scripts/build-ipk.sh` → `dist/openwrt/`
- `docs/dual-network-guide.html`  架构说明书（含原始 SVG）
- `docs/operations-guide.html`    全程 GUI 操作流程（LuCI + CF + 飞牛）

## 说明
当前二进制为脚手架测试用 mock ELF，生产部署请替换为真实 hebing 后重新运行 `bash scripts/build-ipk.sh`。
"""

if release_existed:
    print(f"ℹ️  Tag {TAG} 已存在，查找对应 release…")
    code, releases = gh("/releases")
    release_id, upload_url = None, None
    for r in (releases or []):
        if r["tag_name"] == TAG:
            release_id = r["id"]
            upload_url = r["upload_url"]
            break
    if not release_id:
        print(f"❌  tag {TAG} 存在但没有 release，请先手动创建一个", file=sys.stderr)
        sys.exit(1)
else:
    print(f"🚀  创建 release {TAG}…")
    code, data = gh("/releases", "POST", {
        "tag_name": TAG,
        "target_commitish": "main",
        "name": f"hebing {TAG} — OpenWrt x86_64 .ipk",
        "body": body_md,
        "draft": False,
        "prerelease": False,
    })
    if code >= 300 or not data:
        sys.exit(1)
    release_id = data["id"]
    upload_url = data["upload_url"]

upload_url = upload_url.split("{")[0]
html_url   = f"https://github.com/{REPO}/releases/tag/{TAG}"
print(f"✅ Release ready → {html_url}")

# 3) 上传 .ipk
import pathlib
ipk_path = pathlib.Path(IPK)
if not ipk_path.is_file():
    print(f"❌  找不到 .ipk: {ipk_path}", file=sys.stderr)
    sys.exit(1)

asset_name = ipk_path.name
asset_size = ipk_path.stat().st_size
print(f"⬆️  上传 {asset_name} ({asset_size} bytes)…")

req = urllib.request.Request(
    f"{upload_url}?name={asset_name}",
    data=ipk_path.read_bytes(),
    headers={
        "Authorization": f"token {TOKEN}",
        "Content-Type": "application/octet-stream",
        "User-Agent": "hebing-release",
    },
    method="POST")
try:
    with urllib.request.urlopen(req) as r:
        resp = json.loads(r.read().decode())
    print(f"✅  Asset 上传成功 → {resp['browser_download_url']}")
except urllib.error.HTTPError as e:
    # 如果 asset 已存在，删了再传
    if e.code == 422 or "already_exists" in e.read().decode():
        print(f"ℹ️  Asset 已存在，先删除重传…")
        _, assets = gh(f"/releases/{release_id}/assets")
        for a in (assets or []):
            if a["name"] == asset_name:
                gh(f"/releases/assets/{a['id']}", "DELETE")
                break
        with urllib.request.urlopen(req) as r:
            resp = json.loads(r.read().decode())
        print(f"✅  Asset 上传成功 → {resp['browser_download_url']}")
    else:
        print(f"❌  Asset 上传失败 HTTP {e.code}", file=sys.stderr)
        print(e.read().decode()[:400], file=sys.stderr)
        sys.exit(1)

print(f"\n🎉  完成！{html_url}")
