# 补丁说明 — hermes-45af7a7-xmpp-custom.patch

## 绑定关系（重要）

- **上游基线提交**: `45af7a71fcd420b4422d2c074b1ce58b9ce0d048`
  （hermes-agent `main` 分支，2026-08 期间，Hermes Agent v0.20.1）
- 本补丁由该提交的工作区差异生成（`git diff`），只对**该提交**保证干净应用。
- 若未来上游代码变化导致 `git apply --check` 失败，restore.sh 会**停止并报告**，
  绝不强行修改源码。届时需要：在新提交上重新生成补丁（方法见文末）。
- 重新生成方法（在有定制源码的机器上）：
  ```bash
  cd ~/.hermes/hermes-agent
  git diff > 新补丁.patch     # 相对当前 HEAD 的差异
  ```

## 补丁内容（8 个文件，282 增 24 删）

### A. XMPP 通讯能力（核心，2 个文件）

1. **gateway/config.py**（+32 行）
   - `Platform` 枚举新增 `XMPP = "xmpp"`
   - `_load()` 中新增 XMPP 环境变量解析：检测到 `XMPP_JID` + `XMPP_PASSWORD`
     时自动启用平台，并把 jid/password/server/port/use_tls 写入平台配置
   - 支撑环境变量：`XMPP_JID` `XMPP_PASSWORD` `XMPP_SERVER` `XMPP_PORT` `XMPP_USE_TLS`

2. **gateway/authz_mixin.py**（+2 行）
   - `platform_env_map`: `XMPP -> XMPP_ALLOWED_JIDS`（JID 白名单）
   - `platform_allow_all_map`: `XMPP -> XMPP_ALLOW_ALL_JIDS`

### B. 行为定制（与 XMPP 无关，但属于当前机器的实际行为，一并保留）

3. **AGENTS.md**（+7 行）：网页访问默认走 `~/bin/web-browser` 的规则
   （注意：该脚本依赖 proot Ubuntu + Playwright，见 optional-scripts/，非核心依赖）
4. **agent/agent_runtime_helpers.py**（+38 行）
5. **agent/chat_completion_helpers.py**（+46 行）
6. **agent/conversation_loop.py**（+126/-24）
7. **hermes_cli/config_defaults.py**（+9 行）
8. **hermes_cli/models.py**（+46 行）
   - 4-8 共同实现：**Nous Portal 免费模型动态轮换保护** —— 当用户在免费档且
     目标模型不再被 Portal 标记为免费时，静默切换到当前免费模型，而不是报错。

## 应用方式

```bash
cd ~/.hermes/hermes-agent          # 必须处于锁定提交 45af7a7
git apply --check hermes-45af7a7-xmpp-custom.patch   # 先检查
git apply hermes-45af7a7-xmpp-custom.patch           # 再应用
# 校验标记：
grep 'XMPP = "xmpp"' gateway/config.py
grep 'XMPP_ALLOWED_JIDS' gateway/authz_mixin.py
```

restore.sh 已内置以上全部步骤（含失败即停止）。
