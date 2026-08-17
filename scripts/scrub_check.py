#!/usr/bin/env python3
"""scrub_check.py — 脱敏校验：确保导出内容不含任何真实密钥值。

读取本机 ~/.hermes 中的真实密钥（.env 的值、auth.json / shared/nous_auth.json
中的令牌与长字符串），在目标目录中全文搜索。任何命中 => 退出码 1 并列出位置。

用法:
    python3 scrub_check.py <目录>
"""
import json
import os
import re
import sys

HERMES_HOME = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
SECRET_KEY_RE = ("PASSWORD", "API_KEY", "TOKEN", "SECRET", "PROXIES")


def load_env(path):
    out = {}
    if not os.path.isfile(path):
        return out
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def collect_secrets():
    secrets = {}
    env = load_env(os.path.join(HERMES_HOME, ".env"))
    for k, v in env.items():
        if any(t in k.upper() for t in SECRET_KEY_RE) and len(v) >= 8:
            secrets[f".env:{k}"] = v
    # JSON 凭据文件：只把真正的令牌/密钥字段视为机密
    # （client_id、scope、label、source、portal/inference base_url 等是公开标识，
    #  不应误报；access_token / refresh_token / agent_key 等才是红线）
    token_field_re = re.compile(r"(token|secret|password|agent[_-]?key|id_token)$", re.I)
    for jpath in ("auth.json", os.path.join("shared", "nous_auth.json")):
        p = os.path.join(HERMES_HOME, jpath)
        if not os.path.isfile(p):
            continue
        try:
            data = json.load(open(p, encoding="utf-8"))
        except Exception:
            continue

        def walk(o, prefix, keyname=""):
            if isinstance(o, dict):
                for k2, v in o.items():
                    walk(v, f"{prefix}.{k2}", k2)
            elif isinstance(o, list):
                for i, v in enumerate(o):
                    walk(v, f"{prefix}[{i}]", keyname)
            elif isinstance(o, str) and len(o) >= 8 and token_field_re.search(keyname or ""):
                secrets[f"{jpath}:{prefix}"] = o

        walk(data, "root")
    return secrets


def scan(target_dir, secrets):
    hits = []
    for root, dirs, files in os.walk(target_dir):
        dirs[:] = [d for d in dirs if d not in ("__pycache__", ".git")]
        for fname in files:
            path = os.path.join(root, fname)
            try:
                data = open(path, "rb").read()
            except Exception:
                continue
            for label, val in secrets.items():
                if val.encode() in data:
                    hits.append((label, path))
    return hits


def main():
    if len(sys.argv) != 2:
        print("用法: python3 scrub_check.py <目录>")
        return 2
    target = sys.argv[1]
    secrets = collect_secrets()
    if not secrets:
        print("[scrub_check] 未读取到本机密钥（正常，说明本机无敏感配置）")
    hits = scan(target, secrets)
    if hits:
        print(f"[scrub_check] 发现 {len(hits)} 处密钥泄漏，已中止导出:")
        for label, path in hits[:20]:
            print(f"  {label}  ->  {path}")
        return 1
    print(f"[scrub_check] 通过 ✔（校验 {len(secrets)} 个密钥值，{target} 无泄漏）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
