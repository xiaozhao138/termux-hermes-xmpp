# Termux / Hermes Venv Import Pitfalls

## Problem

Termux `python3` may resolve a different interpreter/`site-packages` than the Hermes venv. A package installed via the Hermes venv pip may be invisible to `python3`.

## Symptom

```bash
python3 -c "import slixmpp"
ModuleNotFoundError: No module named 'slixmpp'
```

Even though `~/.hermes/hermes-agent/venv/bin/pip install slixmpp` succeeded.

## Fix

Use the Hermes venv interpreter explicitly:

```bash
~/.hermes/hermes-agent/venv/bin/python -c "import slixmpp; print(slixmpp.__version__)"
```

For ad-hoc scripts, prepend both the repo root and plugin root to `sys.path`:

```python
import sys
sys.path.insert(0, "/data/data/com.termux/files/home/.hermes/hermes-agent")
sys.path.insert(0, "/data/data/com.termux/files/home/.hermes/plugins/xmpp")
```

This ensures the script resolves the same package paths the venv interpreter would use.
