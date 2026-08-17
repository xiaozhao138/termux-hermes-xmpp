# Termux Hermes + XMPP 可恢复项目

把"Termux 原生 Hermes（含 XMPP 通讯能力）"做成可重复安装、可重复恢复的 Git 项目。

- **来源机器状态快照（2026-08-17）**：Hermes Agent v0.20.1，Python 3.13.13，
  源码锁定上游提交 `45af7a7`，XMPP 已实际验证连接 `hermes@sky.959011.xyz`
  （端口 443，服务器 sky.959011.xyz），与个人 JID 双向收发正常。
- **项目原则**：一切可自动化的步骤全部由脚本完成；只有密钥/OAuth 需要你动手；
  敏感数据（密钥、数据库、历史、会话、memory、venv）一律不进仓库。

---

## 一、快速恢复（新 Termux 上，总共 3 步）

```bash
# 0. 前提：Termux 已装好基础环境（pkg 可用；python/git 等脚本会自动装）

# 1. 克隆项目（换成你自己的仓库地址）
git clone git@github.com:<你的用户名>/<本仓库名>.git
cd <本仓库名>

# 2. 一键安装（自动完成源码锁定、venv、依赖、补丁、插件、skills、配置模板、健康检查）
./install.sh

# 3. 按提示操作
#    - 输入 XMPP_PASSWORD（机器人账号密码）
#    - 输入 DEEPSEEK_API_KEY，或留空后用 hermes auth login nous 登录 Nous Portal
#    - 启动：hermes gateway run
#    - 日志出现 "XMPP: connected as hermes@sky.959011.xyz" 即成功
#    - 用你的 XMPP 客户端给机器人发一条消息验证双向
```

`install.sh` 结束时已经跑过 `verify.sh` 健康检查，一眼看出各项状态。

---

## 二、脚本说明

| 脚本 | 作用 | 是否幂等 |
|---|---|---|
| `install.sh` | 一键安装：系统依赖 + 恢复 + 密钥提示 + 健康检查 | 是 |
| `restore.sh` | 核心恢复（install.sh 内部调用）：源码/venv/依赖/补丁/插件/skills/模板 | 是 |
| `verify.sh` | 健康检查：核心/补丁/插件/依赖/配置/Gateway 六组状态 | - |
| `backup.sh` | 导出脱敏安全备份（不含任何密钥/数据库/历史） | 是 |

- **restore.sh 幂等规则**：检测到已有源码在锁定提交（或源码标记有效）且补丁已应用 → 跳过；
  状态不同 → 停止并报告（`FORCE=1` 才备份重建）；**绝不覆盖**现有
  `config.yaml` / `.env` / `auth.json` / 已有插件。
- **补丁严格绑定** `45af7a7`：`git apply --check` 失败立即停止，不强行改源码。
- **源码获取多级回退**（针对 GitHub 临时 429 / HTTP/2 RPC 异常 / 浅克隆抓取历史 SHA 失败）：
  阶段1 浅克隆+锁定SHA（自动重试并升级 HTTP/1.1、protocol v1）→ 阶段2 完整克隆 →
  阶段3 官方源码归档（codeload tar.gz + 根树哈希内容级校验）。任何路径都只接受
  精确等于 `45af7a7` 的源码；全部失败才停止并给出诊断。获取成功后写入
  `~/.hermes/.hermes-source-meta`（commit/tree/via 标记），verify.sh 据此识别归档源。
- **verify.sh 退出码**：0 = 无缺失项；1 = 有缺失项（待办项不影响退出码）。
  可直接 `./verify.sh` 查看，也支持 `HERMES_HOME=/path ./verify.sh`。

---

## 三、目录结构

```
termux-hermes-xmpp/
├── install.sh                    # 一键安装入口
├── restore.sh                    # 幂等恢复核心
├── verify.sh                     # 健康检查
├── backup.sh                     # 脱敏备份导出
├── .env.example                  # 环境变量模板（可提交）
├── config.yaml.template          # Hermes 配置模板（已脱敏，可提交）
├── .gitignore                    # 安全边界（密钥/数据库/历史绝不进仓库）
├── patches/
│   ├── hermes-45af7a7-xmpp-custom.patch   # 8 文件定制补丁（绑定 45af7a7）
│   └── PATCHES.md                # 逐文件改动说明 + 重新生成方法
├── plugins/xmpp/                 # XMPP 平台插件（plugin.yaml + adapter.py + __init__.py）
├── skills/                       # 7 个自定义 skill（18 个文件，会话沉淀的知识）
├── scripts/
│   └── scrub_check.py            # 脱敏校验（backup.sh 调用）
└── optional-scripts/
    ├── web-browser               # 可选：浏览器抓取脚本（依赖 proot Ubuntu+Playwright）
    └── README.md                 # 说明（install.sh 默认不安装）
```

## 四、XMPP 关键事实（恢复时可能用到）

- 机器人账号：`hermes@sky.959011.xyz`，服务器 `sky.959011.xyz`，端口 `443`（公网入口）
- 端口 443 为明文直连（服务器侧终止 TLS），所以 `XMPP_USE_TLS=false`；
  传统 C2S 直连走 5222 时一般 `XMPP_USE_TLS=true`
- 访问控制：`XMPP_ALLOWED_JIDS` 白名单（逗号分隔）；生产保持 `XMPP_ALLOW_ALL_JIDS=false`
- 依赖链：slixmpp → aiodns → pycares（C 扩展，Termux 需 clang/binutils/make 编译）
- 常见日志：`SCRAM-SHA-1-PLUS ... falling back to non-PLUS mechanism` 属正常回退；
  断线后 gateway 会自动指数退避重连

## 五、敏感信息政策（红线）

以下内容**绝不**提交 GitHub（.gitignore 已兜底）：
`.env`（真实密钥）、`auth.json` / `shared/nous_auth.json`（OAuth 令牌）、
`state.db*`（会话数据库）、`sessions/`、`pastes/`、`logs/`、`memories/`
（个人资料）、`venv/`、所有缓存与 `.bak`。

如需备份这些敏感数据，另行使用本地加密备份（不要放进本仓库）。

## 六、与 lianxi 仓库的隔离

本目录是**独立的 git 仓库**（有自己的 .git）。父目录 ~/lianxi 的
`push_lianxi_auto.sh` 会 `git add .`，因此已在 `~/lianxi/.gitignore` 中加入
`/termux-hermes-xmpp/` 防止误收。**不要**在 ~/lianxi 目录下运行
`push_lianxi_auto.sh` 时把本项目内容推送进 lianxi 仓库。

## 七、上游升级注意事项

- 本项目的补丁只对 `45af7a7` 保证干净应用。升级 Hermes 前请先：
  1. 在现机器重新生成补丁（`git diff > 新补丁`）
  2. 更新 restore.sh 中的 `PIN` 与新补丁文件名
  3. 更新 PATCHES.md
- 否则升级后 restore.sh 会按设计停止并报告，不会破坏源码。
