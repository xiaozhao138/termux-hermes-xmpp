# optional-scripts — 可选脚本（非核心）

## web-browser

浏览器抓取脚本，供 Hermes 的 `~/bin/web-browser` 规则使用（AGENTS.md 补丁中的
"Browser access rule" 引用它）。

**注意：本脚本依赖本机额外环境，install.sh 默认不安装：**
- Termux 内的 proot-distro Ubuntu（`proot-distro login ubuntu`）
- Ubuntu 内 `/root/workspace/venvs/main`（Python venv，含 playwright）
- Ubuntu 内 Playwright Chromium（`/root/.cache/ms-playwright/chromium-1228/...`）

如果你要在新机器上恢复这个能力，需要手动重建上述环境，并把脚本放到
`~/bin/web-browser`（chmod +x）。缺失时 Hermes 的网页抓取会退回其他方式。

## 为什么放这里

核心目标是"可移植的 Termux Hermes + XMPP"。web-browser 依赖具体设备的
proot/Playwright 布局，不属于核心可移植部分，因此单独存放、默认不安装。
