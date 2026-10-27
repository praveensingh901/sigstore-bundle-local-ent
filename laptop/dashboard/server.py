#!/usr/bin/env python3
"""Sigstore Control Panel -- local dashboard for the offline Sigstore laptop kit.

Python 3.10+, standard library only (the laptop is air-gapped: no pip).
Binds to 127.0.0.1 only. Every /api call needs the per-start random token in the
X-Dashboard-Token header. See docs/14-dashboard.md.

Environment (all optional):
  KIT_ROOT              kit directory (default: parent of this file's directory)
  DASHBOARD_PORT        listen port (default 9443)
  DASHBOARD_CTLOG_URL   http://host:port/prefix of a directly reachable CT log
                        (the real kit keeps the CT log inside the cluster)
"""
from __future__ import annotations

import argparse
import base64
import concurrent.futures
import datetime as dt
import difflib
import hashlib
import hmac
import http.client
import http.server
import ipaddress
import json
import os
import re
import secrets
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import webbrowser

if sys.version_info < (3, 10):  # pragma: no cover
    sys.exit("server.py needs Python 3.10 or newer")

HERE = os.path.dirname(os.path.realpath(__file__))
KIT = os.path.realpath(os.environ.get("KIT_ROOT") or os.path.join(HERE, ".."))
SCRIPTS = os.path.join(KIT, "scripts")
ENV_SH = os.path.join(KIT, "config", "env.sh")
PKI = os.path.join(KIT, "pki")
OUT = os.path.join(KIT, "out")
DASH_OUT = os.path.join(OUT, "dashboard")
LOG_DIR = os.path.join(DASH_OUT, "logs")
STATE_FILE = os.path.join(DASH_OUT, "state.json")
LAST_VALIDATION = os.path.join(DASH_OUT, "last-validation.json")

MAX_BODY = 256 * 1024
DEFAULT_PORT = 9443
STEP_RE = re.compile(r"^\d\d-.*\.sh$")
DANGER_STEP = "99"
ONLINE_ONLY_STEPS = {"01"}


# =============================================================================
# Redaction -- nothing secret may reach a log file or an API response
# =============================================================================
_PEM_BLOCK = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\Z)", re.S)
_PEM_BEGIN = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")
_PEM_END = re.compile(r"-----END [A-Z0-9 ]*PRIVATE KEY-----")
_JWT = re.compile(r"eyJ[A-Za-z0-9_\-=]*(?:\.[A-Za-z0-9_\-=]*)*")
# "SECRET" is matched upper-case only so ordinary words ("secret created") survive.
_SECRET_LINE = re.compile(r"(?i:PASSWORD=|TOKEN=)|SECRET")
REDACTED_LINE = "[redacted: line matched a secret pattern]"


class Redactor:
    """Line-oriented redactor that remembers whether it is inside a PEM private key."""

    def __init__(self) -> None:
        self.in_key = False

    def line(self, text: str) -> str:
        if self.in_key:
            if _PEM_END.search(text):
                self.in_key = False
            return REDACTED_LINE
        if _PEM_BEGIN.search(text):
            self.in_key = not _PEM_END.search(text)
            return REDACTED_LINE
        if _SECRET_LINE.search(text):
            return REDACTED_LINE
        return _JWT.sub("[redacted-jwt]", text)


def redact_text(text: str) -> str:
    """Redact a multi-line string (API responses, file excerpts)."""
    text = _PEM_BLOCK.sub(REDACTED_LINE, text)
    r = Redactor()
    return "\n".join(r.line(ln) for ln in text.split("\n"))


_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")


def clean_line(raw: str) -> str:
    raw = raw.rstrip("\r\n")
    if "\r" in raw:  # progress bars: keep what the terminal would finally show
        raw = raw.split("\r")[-1] or raw
    return _ANSI.sub("", raw)


def is_forbidden_path(path: str) -> bool:
    """Files the dashboard must never read or serve."""
    base = os.path.basename(path)
    return base.endswith(".key") or base == "secrets.env"


# =============================================================================
# env.sh parser / writer (round-trips byte-for-byte when nothing changes)
# =============================================================================
_EXPORT = re.compile(r"""^(?P<pre>export[ \t]+(?P<key>[A-Za-z_][A-Za-z0-9_]*)=)(?P<rest>.*)$""")
_SECTION = re.compile(r"^#\s*-{3,}\s*(?P<name>.+?)\s*-{2,}\s*$")
_WRAP = re.compile(r"^\$\{(?P<var>[A-Za-z_][A-Za-z0-9_]*):-(?P<default>[^}]*)\}$")
_REF = re.compile(r"\$\{(?P<name>[A-Za-z_][A-Za-z0-9_]*)(?::-(?P<default>[^}]*))?\}")


class EnvEntry:
    __slots__ = ("key", "lineno", "pre", "quote", "raw", "post", "section", "help")

    def __init__(self, key, lineno, pre, quote, raw, post, section, help_):
        self.key, self.lineno, self.pre, self.quote = key, lineno, pre, quote
        self.raw, self.post, self.section, self.help = raw, post, section, help_

    @property
    def wrapper(self):
        m = _WRAP.match(self.raw)
        return m.group("var") if m else None

    @property
    def editable_value(self) -> str:
        m = _WRAP.match(self.raw)
        return m.group("default") if m else self.raw


def _split_value(rest: str):
    """Return (quote, raw, post) for the text after `export KEY=`."""
    if rest[:1] in ('"', "'"):
        q = rest[0]
        end = rest.find(q, 1)
        if end != -1:
            return q, rest[1:end], rest[end + 1:]
    m = re.match(r"^(?P<v>[^\s#]*)(?P<post>.*)$", rest)
    return "", m.group("v"), m.group("post")


def parse_env_text(text: str):
    """-> (lines, entries). `lines` keeps every original line (with newline)."""
    lines = text.splitlines(keepends=True)
    entries: list[EnvEntry] = []
    section = "General"
    block: list[str] = []
    for i, ln in enumerate(lines):
        s = ln.rstrip("\r\n")
        sm = _SECTION.match(s)
        if sm and set(sm.group("name")) <= set("- "):
            sm = None
        if sm:
            section, block = sm.group("name"), []
            continue
        m = _EXPORT.match(s)
        if m:
            quote, raw, post = _split_value(m.group("rest"))
            help_ = ""
            pm = re.match(r"^\s*#\s?(.*)$", post)
            if pm:
                help_ = pm.group(1).strip()
            elif block:
                help_ = " ".join(block)
            entries.append(EnvEntry(m.group("key"), i, m.group("pre"), quote, raw, post, section, help_))
            block = []
        elif s.lstrip().startswith("#"):
            block.append(re.sub(r"^\s*#\s?", "", s).strip())
        else:
            block = []
    return lines, entries


def render_env_text(lines, entries, new_raw: dict[str, str]) -> str:
    out = list(lines)
    for e in entries:
        if e.key not in new_raw:
            continue
        nl = "\r\n" if lines[e.lineno].endswith("\r\n") else ("\n" if lines[e.lineno].endswith("\n") else "")
        out[e.lineno] = f"{e.pre}{e.quote}{new_raw[e.key]}{e.quote}{e.post}{nl}"
    return "".join(out)


# ---- validation --------------------------------------------------------------
_LABEL = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
_VERSION = re.compile(r"^v?\d+\.\d+\.\d+$")
_IDENT = re.compile(r"^[a-z0-9][a-z0-9_-]{0,62}$")
_EMAIL = re.compile(r"^[a-z0-9._%+-]{1,64}@(?P<d>[a-z0-9.-]{1,253})$")
_TEXT = re.compile(r"^[A-Za-z0-9._ -]{1,64}$")


class ValidationError(ValueError):
    pass


def v_domain(s: str) -> str:
    if not s or len(s) > 253:
        raise ValidationError("must be a lowercase DNS name (a-z, 0-9, '-', dots; max 253 chars)")
    for lab in s.split("."):
        if not _LABEL.match(lab):
            raise ValidationError(f"'{lab}' is not a valid lowercase DNS label (a-z0-9-, 1-63 chars, "
                                  "no leading/trailing '-')")
    return s


def v_label(s: str) -> str:
    if not _LABEL.match(s):
        raise ValidationError("must be a single lowercase DNS label (a-z, 0-9, '-')")
    return s


def v_ident(s: str) -> str:
    if not _IDENT.match(s):
        raise ValidationError("must match [a-z0-9][a-z0-9_-]{0,62}")
    return s


def v_version(s: str) -> str:
    if not _VERSION.match(s):
        raise ValidationError("must look like 1.2.3 or v1.2.3")
    return s


def v_int(lo: int, hi: int):
    def check(s: str) -> str:
        if not re.fullmatch(r"\d{1,6}", s):
            raise ValidationError("must be a whole number")
        if not lo <= int(s) <= hi:
            raise ValidationError(f"must be between {lo} and {hi}")
        return s
    return check


def v_url(s: str, allow_loopback_http: bool = False) -> str:
    u = urllib.parse.urlsplit(s)
    host = u.hostname or ""
    try:
        port = u.port
    except ValueError:
        raise ValidationError("invalid port in URL") from None
    if u.username or u.password or u.query or u.fragment:
        raise ValidationError("URL must not contain credentials, query or fragment")
    loop = host in ("localhost", "127.0.0.1")
    if u.scheme == "http" and allow_loopback_http and loop:
        if port is None:
            raise ValidationError("loopback redirect URL needs an explicit port")
    elif u.scheme != "https":
        raise ValidationError("must be an https:// URL" +
                              (" (or http://localhost:<port>/... for the loopback redirect)"
                               if allow_loopback_http else ""))
    if not host:
        raise ValidationError("URL has no host")
    if u.netloc != u.netloc.lower():
        raise ValidationError("host must be lowercase")
    if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", host):
        v_domain(host)
    if not re.fullmatch(r"[A-Za-z0-9._~/%-]*", u.path):
        raise ValidationError("URL path contains unusual characters")
    return s


def v_url_https(s: str) -> str:
    return v_url(s, False)


def v_url_redirect(s: str) -> str:
    return v_url(s, True)


def v_email(s: str) -> str:
    m = _EMAIL.match(s)
    if not m:
        raise ValidationError("must be a lowercase e-mail address, e.g. alice@example.local")
    if "." not in m.group("d"):
        raise ValidationError("e-mail domain must contain a dot, e.g. alice@example.local")
    v_domain(m.group("d"))
    return s


def v_text(s: str) -> str:
    if not _TEXT.match(s):
        raise ValidationError("1-64 characters from A-Z a-z 0-9 . _ - and space")
    return s


def v_ipv4_in(net: str):
    network = ipaddress.ip_network(net)

    def check(s: str) -> str:
        try:
            ip = ipaddress.IPv4Address(s)
        except ValueError:
            raise ValidationError("must be an IPv4 address") from None
        if ip not in network:
            raise ValidationError(f"must be inside {net} (kind's default service CIDR)")
        return s
    return check


# key -> (type label for the UI, validator)
EDITABLE: dict[str, tuple[str, object]] = {
    "DOMAIN": ("domain", v_domain),
    "CLUSTER_NAME": ("label", v_label),
    "INGRESS_CLUSTER_IP": ("ipv4", v_ipv4_in("10.96.0.0/16")),
    "OIDC_REALM": ("ident", v_ident),
    "OIDC_CLIENT_ID": ("ident", v_ident),
    "OIDC_CI_CLIENT_ID": ("ident", v_ident),
    "OIDC_REDIRECT_URL": ("url (https, or http://localhost:port)", v_url_redirect),
    "DEMO_USER": ("ident", v_ident),
    "DEMO_USER_EMAIL": ("email", v_email),
    "FULCIO_URL": ("url (https)", v_url_https),
    "REKOR_URL": ("url (https)", v_url_https),
    "TUF_URL": ("url (https)", v_url_https),
    "CTLOG_PREFIX": ("ident", v_ident),
    "SIGSTORE_OPERATOR": ("text", v_text),
    "MIRROR_NAME": ("ident", v_ident),
    "MIRROR_PORT": ("port 1024-65535", v_int(1024, 65535)),
    "KIND_VERSION": ("version", v_version),
    "KUBECTL_VERSION": ("version", v_version),
    "HELM_VERSION": ("version", v_version),
    "CRANE_VERSION": ("version", v_version),
    "COSIGN_VERSION": ("version", v_version),
    "GITSIGN_VERSION": ("version", v_version),
    "CHART_TRILLIAN_VERSION": ("version", v_version),
    "CHART_REKOR_VERSION": ("version", v_version),
    "CHART_FULCIO_VERSION": ("version", v_version),
    "CHART_CTLOG_VERSION": ("version", v_version),
    "CHART_TRAEFIK_VERSION": ("version", v_version),
    "CHART_KYVERNO_VERSION": ("version", v_version),
}

_ALL = [f"{n:02d}" for n in range(0, 15)]


def _from(n: str):
    return [s for s in _ALL if s >= n]


# key -> (steps to re-run, why). Order of steps is the order to run them.
RERUN: dict[str, tuple[list[str], str]] = {
    "DOMAIN": (_from("03"), "every hostname, certificate, realm and trust root derives from DOMAIN: "
                            "regenerate the PKI (03) and redeploy everything after it"),
    "CLUSTER_NAME": (_from("04"), "the kind cluster is named after it: recreate the cluster (04) and redeploy"),
    "INGRESS_CLUSTER_IP": (_from("04"), "the node /etc/hosts and CoreDNS point at it: recreate cluster (04) onward"),
    "OIDC_REALM": (_from("07"), "Keycloak realm, Fulcio issuer config and trust files change (07 onward)"),
    "OIDC_CLIENT_ID": (_from("07"), "Keycloak client and Fulcio ClientID change (07 onward)"),
    "OIDC_CI_CLIENT_ID": (_from("07"), "Keycloak CI client changes (07 onward)"),
    "OIDC_REDIRECT_URL": (["07", "09", "14"], "redirect URI is registered in Keycloak and written to client config"),
    "DEMO_USER": (["07", "10"], "demo user is created in the Keycloak realm"),
    "DEMO_USER_EMAIL": (["07", "10", "14"], "certificate identity and Keycloak user e-mail change"),
    "FULCIO_URL": (["09", "12", "13", "14"], "client trust material, TUF repo, policy and gitsign embed it"),
    "REKOR_URL": (["09", "12", "13", "14"], "client trust material, TUF repo, policy and gitsign embed it"),
    "TUF_URL": (["09", "12", "13", "14"], "client trust bootstrap and Kyverno use it"),
    "CTLOG_PREFIX": (_from("08"), "CT log path is baked into Fulcio and trusted_root.json (08 onward)"),
    "SIGSTORE_OPERATOR": (["09", "12", "13", "14"], "operator label is written into signing_config/trusted_root"),
    "MIRROR_NAME": (_from("02"), "the mirror container and containerd registry config are named after it"),
    "MIRROR_PORT": (_from("02"), "the mirror listens on it and containerd is configured for it"),
    "KIND_VERSION": (["01", "02", "04"], "online bundle must be rebuilt; cluster recreated"),
    "KUBECTL_VERSION": (["01"], "rebuild the online bundle to fetch the new binary"),
    "HELM_VERSION": (["01"], "rebuild the online bundle to fetch the new binary"),
    "CRANE_VERSION": (["01"], "rebuild the online bundle to fetch the new binary"),
    "COSIGN_VERSION": (["01"], "rebuild the online bundle to fetch the new binary"),
    "GITSIGN_VERSION": (["01", "14"], "rebuild the online bundle; reconfigure gitsign"),
    "CHART_TRILLIAN_VERSION": (["01", "02", "08"], "rebuild bundle (online), reload, redeploy Sigstore"),
    "CHART_REKOR_VERSION": (["01", "02", "08"], "rebuild bundle (online), reload, redeploy Sigstore"),
    "CHART_FULCIO_VERSION": (["01", "02", "08"], "rebuild bundle (online), reload, redeploy Sigstore"),
    "CHART_CTLOG_VERSION": (["01", "02", "08"], "rebuild bundle (online), reload, redeploy Sigstore"),
    "CHART_TRAEFIK_VERSION": (["01", "02", "05"], "rebuild bundle (online), reload, redeploy ingress"),
    "CHART_KYVERNO_VERSION": (["01", "02", "13"], "rebuild bundle (online), reload, redeploy policy"),
}


def expand_refs(value: str, values: dict[str, str], depth: int = 0) -> str:
    """Expand ${NAME} / ${NAME:-default} using `values` (itself expanded lazily)."""
    if depth > 10:
        raise ValidationError("circular ${...} reference")

    def sub(m: re.Match) -> str:
        name, default = m.group("name"), m.group("default")
        if name in values:
            return expand_refs(values[name], values, depth + 1)
        if default is not None:
            return default
        raise ValidationError(f"unknown variable ${{{name}}}")
    return _REF.sub(sub, value)


def check_shell_safe(value: str, known: set[str]) -> None:
    """env.sh is sourced by bash: refuse anything that could execute or break quoting."""
    if re.search(r"[\"'`\\\n\r\x00]", value):
        raise ValidationError("must not contain quotes, backticks, backslashes or newlines")
    stripped = _REF.sub(lambda m: "" if m.group("name") in known and m.group("default") is None else m.group(0), value)
    if "$" in stripped:
        raise ValidationError("'$' is only allowed as ${KNOWN_VARIABLE}")
    if "#" in value or ";" in value or "&" in value or "|" in value or "<" in value or ">" in value:
        raise ValidationError("must not contain shell metacharacters (# ; & | < >)")


class EnvFile:
    """In-memory view of config/env.sh."""

    def __init__(self, path: str = ENV_SH):
        self.path = path
        with open(path, "r", encoding="utf-8", newline="") as f:
            self.text = f.read()
        self.sha = hashlib.sha256(self.text.encode()).hexdigest()
        self.lines, self.entries = parse_env_text(self.text)
        self.by_key = {e.key: e for e in self.entries}

    def current_values(self) -> dict[str, str]:
        """Effective values: ${VAR:-default} wrappers resolve to their default."""
        return {e.key: e.editable_value for e in self.entries}

    def validate_changes(self, changes: dict) -> tuple[dict[str, str], dict[str, str]]:
        """-> (new_raw per key that really changes, errors per key)."""
        errors: dict[str, str] = {}
        new_raw: dict[str, str] = {}
        known = set(self.by_key)
        values = self.current_values()
        cleaned: dict[str, str] = {}
        for key, val in changes.items():
            if not isinstance(key, str) or key not in self.by_key:
                errors[str(key)] = "unknown setting"
                continue
            if key not in EDITABLE:
                errors[key] = "read-only setting (not in the dashboard allowlist)"
                continue
            if not isinstance(val, str):
                errors[key] = "value must be a string"
                continue
            val = val.strip()
            try:
                check_shell_safe(val, known)
            except ValidationError as ex:
                errors[key] = str(ex)
                continue
            e = self.by_key[key]
            cleaned[key] = f"${{{e.wrapper}:-{val}}}" if e.wrapper else val
        # validate against the final set of values so cross-references are consistent
        merged = dict(values)
        for k, r in cleaned.items():
            m = _WRAP.match(r)
            merged[k] = m.group("default") if m else r
        for key, raw in cleaned.items():
            e = self.by_key[key]
            try:
                m = _WRAP.match(raw)
                EDITABLE[key][1](expand_refs(m.group("default") if m else raw, merged))
            except ValidationError as ex:
                errors[key] = str(ex)
                continue
            if raw != e.raw:
                new_raw[key] = raw
        return new_raw, errors

    def new_text(self, new_raw: dict[str, str]) -> str:
        return render_env_text(self.lines, self.entries, new_raw)


def unified_diff(old: str, new: str) -> str:
    return "".join(difflib.unified_diff(
        old.splitlines(keepends=True), new.splitlines(keepends=True),
        fromfile="config/env.sh", tofile="config/env.sh (new)"))


def rerun_plan(changed_keys) -> list[dict]:
    steps: dict[str, list[str]] = {}
    for k in changed_keys:
        for s in RERUN.get(k, ([], ""))[0]:
            steps.setdefault(s, []).append(k)
    reasons = [{"key": k, "steps": RERUN[k][0], "why": RERUN[k][1]} for k in changed_keys if k in RERUN]
    return [{"step": s, "because": steps[s]} for s in sorted(steps)], reasons


def atomic_write(path: str, data: str, backup: bool) -> None:
    d = os.path.dirname(path)
    st = os.stat(path)
    fd, tmp = tempfile.mkstemp(prefix=".env.sh.", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, st.st_mode & 0o7777)
        if backup:
            shutil.copy2(path, path + ".bak")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def config_view(env: EnvFile) -> dict:
    sections: list[dict] = []
    idx: dict[str, dict] = {}
    for e in env.entries:
        sec = idx.get(e.section)
        if sec is None:
            sec = {"name": e.section, "fields": []}
            idx[e.section] = sec
            sections.append(sec)
        ed = EDITABLE.get(e.key)
        sec["fields"].append({
            "key": e.key, "raw": e.raw, "value": e.editable_value if ed else e.raw,
            "wrapper": e.wrapper, "help": e.help, "editable": bool(ed),
            "type": ed[0] if ed else "",
            "rerun": RERUN.get(e.key, ([], ""))[0] if ed else [],
        })
    return {"sha": env.sha, "sections": sections}


# =============================================================================
# Script discovery / job runner
# =============================================================================
def resolve_script(name: str) -> str:
    """Return the real path of an allowlisted script or raise ValueError."""
    if not isinstance(name, str) or "/" in name or "\\" in name or "\x00" in name \
            or not (STEP_RE.match(name) or name in ("install-all.sh", "verify-stack.sh")):
        raise ValueError("script name not allowed")
    real_scripts = os.path.realpath(SCRIPTS)
    p = os.path.realpath(os.path.join(real_scripts, name))
    if os.path.dirname(p) != real_scripts or not os.path.isfile(p):
        raise ValueError("script not found inside scripts/")
    return p


def header_comment(path: str) -> tuple[str, str]:
    """-> (one-line title, description) from the leading comment block."""
    out: list[str] = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for i, ln in enumerate(f):
                if i == 0 and ln.startswith("#!"):
                    continue
                s = ln.rstrip("\n")
                if not s.startswith("#"):
                    break
                t = re.sub(r"^#\s?", "", s)
                if re.fullmatch(r"[=\-\s]*", t):
                    continue
                out.append(t.rstrip())
    except OSError:
        pass
    while out and not out[0].strip():
        out.pop(0)
    title = out[0] if out else ""
    title = re.sub(r"^\S+\.sh\s+[—-]+\s*", "", title)
    return title, "\n".join(out)


def discover_steps() -> list[dict]:
    steps = []
    try:
        names = sorted(n for n in os.listdir(SCRIPTS) if STEP_RE.match(n))
    except OSError:
        names = []
    for n in names:
        num = n[:2]
        title, desc = header_comment(os.path.join(SCRIPTS, n))
        steps.append({
            "id": num, "script": n, "title": title, "description": desc,
            "online": num in ONLINE_ONLY_STEPS, "danger": num == DANGER_STEP,
            "options": STEP_OPTIONS.get(num, {}),
        })
    return steps


# env overrides a caller may pass, per step (values allowlisted)
STEP_OPTIONS = {
    "10": {"AUTH": ["browser", "device", "password", "ci"]},
    "13": {"POLICY_ACTION": ["Deny", "Audit"]},
}
ALL_OPTIONS = {"AUTH": ["browser", "device", "password", "ci"], "POLICY_ACTION": ["Deny", "Audit"]}
ARG_OPTIONS = {"99": ["--purge"]}


def tool_env() -> dict:
    env = dict(os.environ)
    binp = os.path.join(KIT, "bundle", "bin")
    if os.path.isdir(binp):
        env["PATH"] = binp + os.pathsep + env.get("PATH", "")
    env["KIT_ROOT"] = KIT
    return env


def atomic_json(path: str, obj) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=2, sort_keys=True)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class JobManager:
    """Runs one allowlisted script at a time, streaming redacted output."""

    def __init__(self) -> None:
        self.lock = threading.Lock()          # held while a job is running
        self.cv = threading.Condition()
        self.state_lock = threading.Lock()
        self.job: dict | None = None
        self.proc: subprocess.Popen | None = None
        self.lines: list[str] = []
        self.state = self._load_state()

    # ---- persistence
    def _load_state(self) -> dict:
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                st = json.load(f)
            if not isinstance(st, dict):
                return {}
        except (OSError, ValueError):
            return {}
        for v in st.values():
            if isinstance(v, dict) and v.get("status") == "running":
                v["status"] = "failed"
                v["note"] = "dashboard stopped while this was running"
        return st

    def _save_state(self) -> None:
        with self.state_lock:
            try:
                atomic_json(STATE_FILE, self.state)
            except OSError:
                pass

    @staticmethod
    def log_path(key: str) -> str:
        return os.path.join(LOG_DIR, f"{key}.log")

    # ---- control
    def start(self, key: str, script: str, extra_env: dict, args: list[str]) -> dict:
        if not self.lock.acquire(blocking=False):
            raise RuntimeError("another job is already running")
        try:
            path = resolve_script(script)
            os.makedirs(LOG_DIR, exist_ok=True)
            env = tool_env()
            env.update(extra_env)
            env["TERM"] = "dumb"
            started = time.time()
            with self.cv:
                self.lines = []
            proc = subprocess.Popen(
                ["bash", path, *args], cwd=KIT, env=env, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        except BaseException:
            self.lock.release()
            raise
        self.proc = proc
        self.job = {"key": key, "script": script, "started": now_iso(), "status": "running"}
        with self.state_lock:
            self.state[key] = {"status": "running", "started": now_iso(), "script": script}
        self._save_state()
        threading.Thread(target=self._pump, args=(key, proc, started, script, args), daemon=True).start()
        return dict(self.job)

    def _pump(self, key, proc, started, script, args) -> None:
        red = Redactor()
        logf = None
        try:
            logf = open(self.log_path(key), "w", encoding="utf-8")
            head = f"# {now_iso()}  bash scripts/{script} {' '.join(args)}".rstrip()
            logf.write(head + "\n")
            self._emit(head, logf)
            assert proc.stdout is not None
            for raw in iter(proc.stdout.readline, b""):
                line = red.line(clean_line(raw.decode("utf-8", "replace")))
                self._emit(line, logf)
        except Exception as ex:  # keep the manager alive whatever happens
            self._emit(f"[dashboard] log pump error: {type(ex).__name__}", logf)
        finally:
            rc = proc.wait()
            dur = round(time.time() - started, 1)
            res = {"status": "passed" if rc == 0 else "failed", "exit_code": rc, "duration": dur,
                   "started": self.job["started"] if self.job else now_iso(), "finished": now_iso(),
                   "script": script}
            if rc < 0:
                res["note"] = f"terminated by signal {-rc}"
            tail = f"# finished: exit {rc} in {dur}s"
            self._emit(tail, logf)
            if logf:
                logf.close()
            with self.state_lock:
                self.state[key] = res
            self._save_state()
            with self.cv:
                self.job = {**(self.job or {}), "key": key, "status": res["status"], "exit_code": rc}
                self.proc = None
                self.cv.notify_all()
            self.lock.release()

    def _emit(self, line: str, logf) -> None:
        if logf:
            logf.write(line + "\n")
            logf.flush()
        with self.cv:
            self.lines.append(line)
            if len(self.lines) > 50000:
                del self.lines[:10000]
            self.cv.notify_all()

    def stop(self) -> bool:
        p = self.proc
        if p and p.poll() is None:
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                return False
            return True
        return False

    def running_key(self) -> str | None:
        return self.job["key"] if self.job and self.job.get("status") == "running" else None

    def snapshot(self) -> dict:
        with self.state_lock:
            return json.loads(json.dumps(self.state))

    def read_log(self, key: str, tail: int = 3000) -> str:
        try:
            with open(self.log_path(key), "r", encoding="utf-8", errors="replace") as f:
                lines = f.read().split("\n")
        except OSError:
            return ""
        return redact_text("\n".join(lines[-tail:]))

    def stream(self, key: str, start: int, write) -> None:
        """Send SSE events for the running job `key` until it ends."""
        i = start
        while True:
            with self.cv:
                while i >= len(self.lines) and self.running_key() == key:
                    self.cv.wait(timeout=10)
                    if i >= len(self.lines) and self.running_key() == key:
                        write(": keepalive\n\n")
                batch = self.lines[i:i + 500]
                done = self.running_key() != key and i + len(batch) >= len(self.lines)
            for ln in batch:
                write(f"id: {i}\nevent: line\ndata: {json.dumps(ln)}\n\n")
                i += 1
            if done:
                st = self.snapshot().get(key, {})
                write(f"event: end\ndata: {json.dumps({'status': st.get('status'), 'exit_code': st.get('exit_code')})}\n\n")
                return


JOBS: JobManager | None = None
LOG_KEYS = re.compile(r"^(\d\d|all|smoke|verify)$")


# =============================================================================
# Validation checks
# =============================================================================
class Skip(Exception):
    pass


class Warn(Exception):
    pass


def result(group, check, status, detail="", hint=""):
    return {"group": group, "check": check, "status": status,
            "detail": redact_text(str(detail))[:600], "hint": hint}


def run_cmd(cmd: list[str], timeout: int = 15, env: dict | None = None) -> tuple[int, str]:
    """Run a tool with a timeout. Missing tool -> Skip. Timeout -> RuntimeError."""
    e = env or tool_env()
    exe = shutil.which(cmd[0], path=e.get("PATH"))
    if not exe:
        raise Skip(f"{cmd[0]} not found on PATH")
    try:
        p = subprocess.run([exe, *cmd[1:]], capture_output=True, text=True, timeout=timeout,
                           env=e, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{cmd[0]} timed out after {timeout}s") from None
    return p.returncode, (p.stdout + p.stderr).strip()


class Settings:
    """Values of env.sh that the checks need (expanded)."""

    def __init__(self) -> None:
        env = EnvFile()
        vals = env.current_values()
        self.v: dict[str, str] = {}
        for k in vals:
            try:
                self.v[k] = expand_refs(vals[k], vals)
            except ValidationError:
                self.v[k] = vals[k]

    def __getitem__(self, k: str) -> str:
        return self.v.get(k, "")


def ctx_name(s: Settings) -> str:
    return f"kind-{s['CLUSTER_NAME']}"


class ClusterProbe:
    """Lazily checks (once per validation run) whether the kind cluster API answers."""

    def __init__(self, s: Settings):
        self.s = s
        self.lock = threading.Lock()
        self.done = False
        self.reason = ""

    def require(self) -> None:
        with self.lock:
            if not self.done:
                self.done = True
                try:
                    rc, out = run_cmd(["kubectl", "--context", ctx_name(self.s), "--request-timeout=6s",
                                       "get", "--raw", "/readyz"], timeout=12)
                    if rc != 0:
                        self.reason = f"cluster '{ctx_name(self.s)}' not reachable: {out.splitlines()[-1][:160] if out else 'no output'}"
                except Skip as ex:
                    self.reason = str(ex)
                except RuntimeError as ex:
                    self.reason = str(ex)
        if self.reason:
            raise Skip(self.reason)

    def kubectl(self, *args: str, timeout: int = 15) -> tuple[int, str]:
        self.require()
        return run_cmd(["kubectl", "--context", ctx_name(self.s), "--request-timeout=10s", *args], timeout=timeout)


def tls_context(s: Settings) -> ssl.SSLContext:
    ca = os.path.join(PKI, "tls", "ca.crt")
    if not os.path.isfile(ca):
        raise Skip("pki/tls/ca.crt missing (run scripts/03-generate-pki.sh)")
    return ssl.create_default_context(cafile=ca)


def https_get(url: str, ctx: ssl.SSLContext, timeout: int = 8, limit: int = 2_000_000):
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("https", "http") or not u.hostname:
        raise RuntimeError("bad URL")
    try:
        if u.scheme == "https":
            conn = http.client.HTTPSConnection(u.hostname, u.port or 443, timeout=timeout, context=ctx)
        else:
            conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=timeout)
        conn.request("GET", (u.path or "/") + (f"?{u.query}" if u.query else ""),
                     headers={"Accept": "application/json, */*", "User-Agent": "sigstore-control-panel"})
        r = conn.getresponse()
        body = r.read(limit)
        conn.close()
        return r.status, body
    except ssl.SSLCertVerificationError as ex:
        raise RuntimeError(f"TLS verification failed: {ex.verify_message or ex}") from None
    except socket.gaierror:
        raise RuntimeError(f"cannot resolve {u.hostname}") from None
    except (OSError, http.client.HTTPException) as ex:
        raise RuntimeError(f"{type(ex).__name__}: {ex}") from None


def get_json(url: str, ctx) -> object:
    status, body = https_get(url, ctx)
    if status != 200:
        raise RuntimeError(f"HTTP {status}")
    try:
        return json.loads(body)
    except ValueError:
        raise RuntimeError("response is not JSON") from None


def pem_blocks(text: str, label: str | None = None) -> list[bytes]:
    out = []
    for m in re.finditer(r"-----BEGIN ([A-Z0-9 ]+)-----(.*?)-----END \1-----", text, re.S):
        if label is None or m.group(1) == label:
            try:
                out.append(base64.b64decode("".join(m.group(2).split())))
            except ValueError:
                pass
    return out


def read_text(path: str, limit: int = 2_000_000) -> str:
    if is_forbidden_path(path):
        raise PermissionError("refusing to read a key or secrets file")
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read(limit)


def parse_ts(s: str) -> dt.datetime:
    s = s.strip().replace("Z", "+00:00")
    d = dt.datetime.fromisoformat(s)
    return d if d.tzinfo else d.replace(tzinfo=dt.timezone.utc)


def days_until(d: dt.datetime) -> float:
    return (d - dt.datetime.now(dt.timezone.utc)).total_seconds() / 86400


# ---- check implementations: each returns (status, detail) or raises Skip/Warn/RuntimeError
def chk_mirror(s, cl):
    rc, out = run_cmd(["docker", "inspect", "-f", "{{.State.Status}}", s["MIRROR_NAME"]])
    if rc != 0 or out != "running":
        raise RuntimeError(out.splitlines()[-1] if out else "container not found")
    return f"{s['MIRROR_NAME']} is running"


def chk_kind(s, cl):
    rc, out = run_cmd(["kind", "get", "clusters"])
    if rc != 0:
        raise RuntimeError(out[:200])
    if s["CLUSTER_NAME"] not in out.split():
        raise RuntimeError(f"cluster '{s['CLUSTER_NAME']}' not found (have: {', '.join(out.split()) or 'none'})")
    return f"cluster {s['CLUSTER_NAME']} exists"


def chk_node_ready(s, cl):
    rc, out = cl.kubectl("get", "nodes", "-o", "jsonpath={range .items[*]}{.metadata.name}={.status.conditions[?(@.type=='Ready')].status}{'\\n'}{end}")
    if rc != 0:
        raise RuntimeError(out[:200])
    nodes = [ln for ln in out.splitlines() if ln]
    bad = [n for n in nodes if not n.endswith("=True")]
    if not nodes or bad:
        raise RuntimeError("not Ready: " + ", ".join(bad or ["no nodes"]))
    return f"{len(nodes)} node(s) Ready"


def chk_node_hosts(s, cl):
    node = f"{s['CLUSTER_NAME']}-control-plane"
    rc, out = run_cmd(["docker", "inspect", "-f", "{{.State.Status}}", node])
    if rc != 0:
        raise Skip(f"node container {node} not found")
    rc, out = run_cmd(["docker", "exec", node, "grep", "-c", "sigstore-offline", "/etc/hosts"])
    if rc != 0 or out.strip() in ("", "0"):
        raise RuntimeError("no sigstore-offline entry in node /etc/hosts")
    return f"{out.strip()} entry line(s) in {node}:/etc/hosts"


def make_dns_check(host):
    def chk(s, cl):
        try:
            addrs = sorted({a[4][0] for a in socket.getaddrinfo(host, None, socket.AF_INET)})
        except socket.gaierror:
            raise RuntimeError("does not resolve") from None
        if "127.0.0.1" not in addrs:
            raise RuntimeError(f"resolves to {', '.join(addrs)} (expected 127.0.0.1)")
        return "127.0.0.1"
    return chk


POD_NS = [("traefik", "05"), ("registry", "06"), ("keycloak", "07"), ("trillian-system", "08"),
          ("rekor-system", "08"), ("fulcio-system", "08"), ("ctlog-system", "08"),
          ("tuf-system", "12"), ("kyverno", "13")]


def make_pod_check(ns):
    def chk(s, cl):
        rc, out = cl.kubectl("get", "ns", ns, "-o", "name")
        if rc != 0:
            raise RuntimeError("namespace not deployed")
        rc, out = cl.kubectl("-n", ns, "get", "pods", "-o", "json")
        if rc != 0:
            raise RuntimeError(out[:200])
        pods = json.loads(out).get("items", [])
        bad, unready = [], []
        for p in pods:
            phase = p.get("status", {}).get("phase")
            name = p["metadata"]["name"]
            if phase == "Succeeded":
                continue
            reason = phase
            for cs in p.get("status", {}).get("containerStatuses", []) + p.get("status", {}).get("initContainerStatuses", []):
                w = cs.get("state", {}).get("waiting")
                if w and w.get("reason"):
                    reason = w["reason"]
            if p["metadata"].get("deletionTimestamp"):
                reason = "Terminating"
            if phase != "Running" or reason != "Running":
                bad.append(f"{name}({reason})")
            elif not all(c.get("ready") for c in p.get("status", {}).get("containerStatuses", [])):
                unready.append(name)
        if bad:
            raise RuntimeError(" ".join(bad))
        if unready:
            raise Warn("Running but not Ready: " + " ".join(unready))
        return f"{len(pods)} pod(s) Running/Completed"
    return chk


def chk_keycloak(s, cl):
    ctx = tls_context(s)
    doc = get_json(f"{s['OIDC_ISSUER']}/.well-known/openid-configuration", ctx)
    iss = doc.get("issuer") if isinstance(doc, dict) else None
    if iss != s["OIDC_ISSUER"]:
        raise RuntimeError(f"issuer is {iss!r}, expected {s['OIDC_ISSUER']!r}")
    return f"issuer = {iss}"


def chk_fulcio_root(s, cl):
    ctx = tls_context(s)
    status, body = https_get(s["FULCIO_URL"] + "/api/v1/rootCert", ctx)
    if status != 200:
        raise RuntimeError(f"HTTP {status}")
    certs = pem_blocks(body.decode("utf-8", "replace"), "CERTIFICATE")
    if not certs:
        raise RuntimeError("response contains no PEM certificate")
    detail = f"{len(certs)} certificate(s) in chain"
    local = os.path.join(PKI, "fulcio", "chain.pem")
    if os.path.isfile(local):
        mine = pem_blocks(read_text(local), "CERTIFICATE")
        if mine and hashlib.sha256(mine[0]).digest() != hashlib.sha256(certs[0]).digest():
            raise RuntimeError("served chain differs from pki/fulcio/chain.pem")
        detail += "; matches pki/fulcio/chain.pem"
    return detail


def chk_fulcio_cfg(s, cl):
    ctx = tls_context(s)
    doc = get_json(s["FULCIO_URL"] + "/api/v2/configuration", ctx)
    issuers = [i.get("issuerUrl") for i in (doc.get("issuers", []) if isinstance(doc, dict) else [])]
    if s["OIDC_ISSUER"] not in issuers:
        raise RuntimeError(f"issuers: {issuers or 'none'}; expected {s['OIDC_ISSUER']}")
    return f"lists {s['OIDC_ISSUER']}"


def chk_rekor_log(s, cl):
    ctx = tls_context(s)
    doc = get_json(s["REKOR_URL"] + "/api/v1/log", ctx)
    if not isinstance(doc, dict) or "treeSize" not in doc:
        raise RuntimeError("response has no treeSize")
    return f"treeSize={doc['treeSize']}"


def chk_rekor_key(s, cl):
    ctx = tls_context(s)
    local = os.path.join(PKI, "rekor", "rekor.pub")
    if not os.path.isfile(local):
        raise Skip("pki/rekor/rekor.pub missing")
    status, body = https_get(s["REKOR_URL"] + "/api/v1/log/publicKey", ctx)
    if status != 200:
        raise RuntimeError(f"HTTP {status}")
    text = body.decode("utf-8", "replace")
    if text.lstrip().startswith('"'):  # Rekor JSON-encodes the PEM when Accept is application/json
        try:
            text = json.loads(text)
        except ValueError:
            pass
    a = pem_blocks(text, "PUBLIC KEY")
    b = pem_blocks(read_text(local), "PUBLIC KEY")
    if not a or not b or a[0] != b[0]:
        raise RuntimeError("Rekor's public key differs from pki/rekor/rekor.pub")
    return "matches pki/rekor/rekor.pub"


def chk_registry(s, cl):
    ctx = tls_context(s)
    status, _ = https_get(f"https://{s['REGISTRY_HOST']}/v2/", ctx)
    if status != 200:
        raise RuntimeError(f"HTTP {status} (expected 200)")
    return "GET /v2/ -> 200"


def chk_tuf(s, cl):
    ctx = tls_context(s)
    doc = get_json(s["TUF_URL"] + "/timestamp.json", ctx)
    try:
        exp = parse_ts(doc["signed"]["expires"])
    except (KeyError, TypeError, ValueError):
        raise RuntimeError("timestamp.json has no signed.expires") from None
    d = days_until(exp)
    msg = f"expires {exp:%Y-%m-%d} ({d:.1f} days)"
    if d < 1:
        raise RuntimeError(msg + " - re-run 12-publish-tuf.sh")
    if d < 3:
        raise Warn(msg + " - re-sign soon (12-publish-tuf.sh)")
    return msg


def chk_ct_key(s, cl):
    local = os.path.join(PKI, "ctlog", "ctlog.pub")
    if not os.path.isfile(local):
        raise Skip("pki/ctlog/ctlog.pub missing")
    rc, out = cl.kubectl("-n", "ctlog-system", "get", "secret", "ctlog-public-key", "-o", "jsonpath={.data.public}")
    if rc != 0:
        raise RuntimeError(out[:200])
    a = pem_blocks(base64.b64decode(out).decode("utf-8", "replace"), "PUBLIC KEY")
    b = pem_blocks(read_text(local), "PUBLIC KEY")
    if not a or not b or a[0] != b[0]:
        raise RuntimeError("cluster CT log key differs from pki/ctlog/ctlog.pub")
    return "matches pki/ctlog/ctlog.pub"


def chk_ct_reach(s, cl):
    direct = os.environ.get("DASHBOARD_CTLOG_URL", "").rstrip("/")
    if direct:
        if not direct.startswith("http://"):
            raise Skip("DASHBOARD_CTLOG_URL must be http://")
        status, body = https_get(direct + "/ct/v1/get-sth", None)
    else:
        # The kit does not expose the CT log outside the cluster: ask the API server's service proxy.
        rc, out = cl.kubectl("get", "--raw", f"/api/v1/namespaces/ctlog-system/services/ctlog:80/proxy/{s['CTLOG_PREFIX']}/ct/v1/get-sth")
        if rc != 0:
            raise RuntimeError(out[:200])
        status, body = 200, out.encode()
    if status != 200:
        raise RuntimeError(f"HTTP {status}")
    try:
        sth = json.loads(body)
        return f"get-sth ok, tree_size={sth['tree_size']}"
    except (ValueError, KeyError, TypeError):
        raise RuntimeError("get-sth response unreadable") from None


def openssl_cert(path: str) -> tuple[str, dt.datetime]:
    rc, out = run_cmd(["openssl", "x509", "-in", path, "-noout", "-subject", "-enddate"], timeout=10)
    if rc != 0:
        raise RuntimeError(out.splitlines()[-1][:160] if out else "openssl could not parse the file")
    subj = end = None
    for ln in out.splitlines():
        if ln.startswith("subject="):
            subj = ln[len("subject="):].strip()
        elif ln.startswith("notAfter="):
            end = dt.datetime.strptime(re.sub(r"\s+", " ", ln[len("notAfter="):].strip()),
                                       "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)
    if not subj or not end:
        raise RuntimeError("could not read subject/notAfter")
    return subj, end


CERT_FILES = [("TLS root CA", "tls/ca.crt"), ("Wildcard TLS cert", "tls/wildcard.crt"),
              ("Fulcio root CA", "fulcio/root.crt"), ("Fulcio intermediate CA", "fulcio/intermediate.crt")]


def make_cert_check(rel):
    def chk(s, cl):
        if not os.path.isdir(PKI):
            raise Skip("pki/ not generated (run scripts/03-generate-pki.sh)")
        p = os.path.join(PKI, rel)
        if not os.path.isfile(p):
            raise RuntimeError(f"pki/{rel} missing")
        subj, end = openssl_cert(p)
        d = int(days_until(end) // 1)
        msg = f"{subj}; notAfter {end:%Y-%m-%d}; {d} days left"
        if d < 0:
            raise RuntimeError(msg.replace("days left", "days (EXPIRED)"))
        if d < 30:
            raise Warn(msg)
        return msg
    return chk


def load_json_file(path: str):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def chk_trusted_root(s, cl):
    p = os.path.join(OUT, "trusted_root.json")
    if not os.path.isfile(p):
        raise RuntimeError("out/trusted_root.json missing")
    doc = load_json_file(p)
    return f"parses; {doc.get('mediaType', '?')}"


def chk_signing_config(s, cl):
    p = os.path.join(OUT, "signing_config.json")
    if not os.path.isfile(p):
        raise RuntimeError("out/signing_config.json missing")
    doc = load_json_file(p)
    return f"parses; {doc.get('mediaType', '?')}"


def _norm(u):
    return (u or "").rstrip("/")


def chk_trust_urls(s, cl):
    p = os.path.join(OUT, "trusted_root.json")
    if not os.path.isfile(p):
        raise Skip("out/trusted_root.json missing (run 09-configure-cosign.sh)")
    doc = load_json_file(p)
    cas = sorted(_norm(c.get("uri")) for c in doc.get("certificateAuthorities", []))
    tl = sorted(_norm(t.get("baseUrl")) for t in doc.get("tlogs", []))
    ct = sorted(_norm(t.get("baseUrl")) for t in doc.get("ctlogs", []))
    problems = []
    if cas != [_norm(s["FULCIO_URL"])]:
        problems.append(f"Fulcio {cas} != [{s['FULCIO_URL']}]")
    if tl != [_norm(s["REKOR_URL"])]:
        problems.append(f"Rekor {tl} != [{s['REKOR_URL']}]")
    suffix = "/" + s["CTLOG_PREFIX"]
    if len(ct) != 1 or not ct[0].endswith(suffix):
        problems.append(f"CT log {ct} should be exactly one URL ending in {suffix}")
    if problems:
        raise RuntimeError("; ".join(problems))
    return f"Fulcio={cas[0]}, Rekor={tl[0]}, CT={ct[0]} (env.sh gives the prefix only)"


def chk_signing_urls(s, cl):
    p = os.path.join(OUT, "signing_config.json")
    if not os.path.isfile(p):
        raise Skip("out/signing_config.json missing (run 09-configure-cosign.sh)")
    doc = load_json_file(p)
    got = {
        "Fulcio": sorted(_norm(x.get("url")) for x in doc.get("caUrls", [])),
        "OIDC": sorted(_norm(x.get("url")) for x in doc.get("oidcUrls", [])),
        "Rekor": sorted(_norm(x.get("url")) for x in doc.get("rekorTlogUrls", [])),
    }
    want = {"Fulcio": [_norm(s["FULCIO_URL"])], "OIDC": [_norm(s["OIDC_ISSUER"])], "Rekor": [_norm(s["REKOR_URL"])]}
    bad = [f"{k} {got[k]} != {want[k]}" for k in want if got[k] != want[k]]
    if bad:
        raise RuntimeError("; ".join(bad))
    return "Fulcio, OIDC and Rekor URLs match env.sh"


def tuf_expiry_from_meta() -> dt.datetime | None:
    p = os.path.join(OUT, "tuf", "meta.env")
    if not os.path.isfile(p):
        return None
    m = re.search(r"^TUF_EXPIRES=\"?([^\"\s]+)\"?", read_text(p), re.M)
    return parse_ts(m.group(1)) if m else None


def chk_tuf_meta(s, cl):
    try:
        exp = tuf_expiry_from_meta()
    except ValueError:
        raise RuntimeError("TUF_EXPIRES in out/tuf/meta.env is not a date") from None
    if exp is None:
        raise Skip("out/tuf/meta.env missing (run 12-publish-tuf.sh)")
    d = days_until(exp)
    msg = f"expires {exp:%Y-%m-%d} ({d:.0f} days)"
    if d < 1:
        raise RuntimeError(msg + " - re-run 12-publish-tuf.sh")
    if d < 30:
        raise Warn(msg + " - re-run 12-publish-tuf.sh soon")
    return msg


def chk_policy(s, cl):
    rc, out = cl.kubectl("get", "imagevalidatingpolicy", "require-private-sigstore-signature", "-o", "json")
    if rc != 0:
        raise RuntimeError(out.splitlines()[-1][:200] if out else "policy not found")
    doc = json.loads(out)
    actions = doc.get("spec", {}).get("validationActions", [])
    ready = doc.get("status", {}).get("conditionStatus", {}).get("ready")
    if ready is not True and str(ready).lower() != "true":
        raise RuntimeError(f"policy present but not ready (ready={ready})")
    if "Deny" in actions:
        return "present, ready, Enforce (validationActions: Deny)"
    raise Warn(f"present and ready but NOT enforcing: validationActions={actions} (POLICY_ACTION=Deny to enforce)")


def gitsign_env_path():
    return os.path.join(OUT, "gitsign", "gitsign.env")


def chk_gitsign_bin(s, cl):
    rc, out = run_cmd(["gitsign", "--version"])
    first = out.splitlines()[0] if out else "(no output)"
    if rc != 0:
        raise RuntimeError(first[:160])
    return first[:160]


def chk_gitsign_env(s, cl):
    p = gitsign_env_path()
    if not os.path.isfile(p):
        raise Skip("out/gitsign/gitsign.env missing (run 14-configure-gitsign.sh)")
    names = re.findall(r"^export\s+([A-Z0-9_]+)=", read_text(p), re.M)
    if not names:
        raise RuntimeError("gitsign.env defines no variables")
    return f"defines {', '.join(names)}"


def chk_gitsign_files(s, cl):
    p = gitsign_env_path()
    if not os.path.isfile(p):
        raise Skip("out/gitsign/gitsign.env missing (run 14-configure-gitsign.sh)")
    missing, ok = [], 0
    for m in re.finditer(r"^export\s+([A-Z0-9_]+)=\"?([^\"\n]+)\"?\s*$", read_text(p), re.M):
        val = m.group(2)
        if val.startswith("/"):
            # gitsign.env was written for the kit's real location; accept a relocated kit
            alt = os.path.join(OUT, "gitsign", os.path.basename(val))
            if (os.path.isfile(val) and os.path.getsize(val) > 0) or (os.path.isfile(alt) and os.path.getsize(alt) > 0):
                ok += 1
            else:
                missing.append(f"{m.group(1)}={val}")
    if missing:
        raise RuntimeError("missing: " + ", ".join(missing))
    return f"{ok} referenced file(s) exist"


# (group id, group title, check name, fn, fix hint, needs_cluster)
def build_checks(s: Settings):
    C = []

    def add(g, name, fn, hint, cluster=False):
        C.append((g, name, fn, hint, cluster))
    add("platform", "mirror container", chk_mirror, f"docker start {s['MIRROR_NAME']} (or scripts/02-load-offline-bundle.sh)")
    add("platform", "kind cluster", chk_kind, "scripts/04-create-cluster.sh")
    add("platform", "node Ready", chk_node_ready, "kubectl describe node", True)
    add("platform", "node /etc/hosts entry", chk_node_hosts, "scripts/fix-node-dns.sh (needed after a laptop reboot)")
    for hn in s["ALL_HOSTS"].split():
        add("platform", f"laptop DNS {hn}", make_dns_check(hn), "sudo scripts/setup-hosts.sh")
    for ns, step in POD_NS:
        add("pods", f"namespace {ns}", make_pod_check(ns), f"scripts/{step}-*.sh; kubectl -n {ns} describe pod", True)
    add("endpoints", "Keycloak OIDC discovery", chk_keycloak, "kubectl -n keycloak logs deploy/keycloak")
    add("endpoints", "Fulcio rootCert chain", chk_fulcio_root, "scripts/08-deploy-sigstore.sh")
    add("endpoints", "Fulcio trusts Keycloak", chk_fulcio_cfg, "kubectl -n fulcio-system logs deploy/fulcio-server (issuer discovery)")
    add("endpoints", "Rekor log", chk_rekor_log, "kubectl -n trillian-system get pods")
    add("endpoints", "Rekor key = pki rekor.pub", chk_rekor_key, "check the rekor-signer secret (08)")
    add("endpoints", "CT log key = pki ctlog.pub", chk_ct_key, "check the ctlog-signer secret (08)", True)
    add("endpoints", "CT log reachable", chk_ct_reach, "kubectl -n ctlog-system logs deploy/ctlog", True if not os.environ.get("DASHBOARD_CTLOG_URL") else False)
    add("endpoints", "Registry /v2/", chk_registry, "scripts/06-deploy-registry.sh")
    add("endpoints", "TUF timestamp.json", chk_tuf, "scripts/12-publish-tuf.sh")
    for label, rel in CERT_FILES:
        add("certs", label, make_cert_check(rel), "scripts/03-generate-pki.sh (regenerates the whole PKI - see docs/05)")
    add("trust", "trusted_root.json parses", chk_trusted_root, "scripts/09-configure-cosign.sh")
    add("trust", "signing_config.json parses", chk_signing_config, "scripts/09-configure-cosign.sh")
    add("trust", "trusted_root URLs match env.sh", chk_trust_urls, "scripts/09-configure-cosign.sh")
    add("trust", "signing_config URLs match env.sh", chk_signing_urls, "scripts/09-configure-cosign.sh")
    add("trust", "TUF metadata expiry (meta.env)", chk_tuf_meta, "scripts/12-publish-tuf.sh")
    add("policy", "Kyverno ImageValidatingPolicy", chk_policy, "scripts/13-deploy-policy.sh", True)
    add("gitsign", "gitsign binary", chk_gitsign_bin, "scripts/01 bundles gitsign; see docs/13-gitsign.md")
    add("gitsign", "gitsign.env present", chk_gitsign_env, "scripts/14-configure-gitsign.sh")
    add("gitsign", "gitsign.env files exist", chk_gitsign_files, "scripts/14-configure-gitsign.sh")
    return C


GROUPS = [("platform", "Platform"), ("pods", "Pods"), ("endpoints", "Endpoints (TLS)"),
          ("certs", "Certificates"), ("trust", "Trust material"), ("policy", "Policy"), ("gitsign", "gitsign")]
GROUP_IDS = [g for g, _ in GROUPS]


def run_one(item, cluster: ClusterProbe, s: Settings) -> dict:
    g, name, fn, hint, needs_cluster = item
    try:
        if needs_cluster:
            cluster.require()
        detail = fn(s, cluster)
        return result(g, name, "PASS", detail)
    except Skip as ex:
        return result(g, name, "SKIP", str(ex), hint)
    except Warn as ex:
        return result(g, name, "WARN", str(ex), hint)
    except PermissionError as ex:
        return result(g, name, "FAIL", str(ex), hint)
    except Exception as ex:  # a check must never take the dashboard down
        msg = str(ex) or type(ex).__name__
        return result(g, name, "FAIL", msg, hint)


VALIDATE_LOCK = threading.Lock()


def run_validation(groups: list[str]) -> dict:
    s = Settings()
    cluster = ClusterProbe(s)
    items = [c for c in build_checks(s) if c[0] in groups]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(lambda it: run_one(it, cluster, s), items))
    now = now_iso()
    last = load_last_validation()
    by_group = last.get("groups", {})
    for g in groups:
        by_group[g] = {"time": now, "results": [r for r in results if r["group"] == g]}
    last = {"time": now, "groups": by_group}
    try:
        atomic_json(LAST_VALIDATION, last)
    except OSError:
        pass
    return {"time": now, "results": results}


def load_last_validation() -> dict:
    try:
        d = load_json_file(LAST_VALIDATION)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def validation_counts(last: dict) -> dict:
    c = {"PASS": 0, "FAIL": 0, "WARN": 0, "SKIP": 0}
    for g in last.get("groups", {}).values():
        for r in g.get("results", []):
            c[r.get("status", "SKIP")] = c.get(r.get("status", "SKIP"), 0) + 1
    return c


def overview() -> dict:
    jobs = JOBS
    steps = discover_steps()
    st = jobs.snapshot() if jobs else {}
    numbered = [x for x in steps if not x["danger"]]
    passed = [x["id"] for x in numbered if st.get(x["id"], {}).get("status") == "passed"]
    nxt = next((x["id"] for x in numbered if st.get(x["id"], {}).get("status") != "passed"), None)
    last = load_last_validation()
    ov = {"install": {"passed": len(passed), "total": len(numbered), "next": nxt,
                      "failed": [x["id"] for x in numbered if st.get(x["id"], {}).get("status") == "failed"]},
          "validation": {"counts": validation_counts(last), "time": last.get("time")},
          "certs": {"days": None, "name": None, "error": None}, "tuf": {"days": None, "error": None},
          "running": jobs.running_key() if jobs else None}
    # earliest certificate expiry (live: four quick openssl calls)
    try:
        best = None
        for label, rel in CERT_FILES:
            p = os.path.join(PKI, rel)
            if os.path.isfile(p):
                _, end = openssl_cert(p)
                if best is None or end < best[1]:
                    best = (label, end)
        if best:
            ov["certs"] = {"days": int(days_until(best[1]) // 1), "name": best[0], "error": None}
        else:
            ov["certs"]["error"] = "no certificates under pki/"
    except Skip as ex:
        ov["certs"]["error"] = str(ex)
    except Exception as ex:
        ov["certs"]["error"] = str(ex)[:120]
    try:
        exp = tuf_expiry_from_meta()
        if exp:
            ov["tuf"]["days"] = int(days_until(exp) // 1)
        else:
            ov["tuf"]["error"] = "out/tuf/meta.env not found (run step 12)"
    except Exception as ex:
        ov["tuf"]["error"] = str(ex)[:120]
    return ov


# =============================================================================
# HTTP layer
# =============================================================================
CSP = ("default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
       "connect-src 'self'; frame-ancestors 'none'")


def allowed_hosts(port: int) -> set[str]:
    return {f"127.0.0.1:{port}", f"localhost:{port}"}


def host_ok(host_header: str | None, port: int) -> bool:
    return (host_header or "").lower() in allowed_hosts(port)


def origin_ok(origin: str | None, port: int) -> bool:
    if origin is None:
        return True
    return origin.lower() in {f"http://127.0.0.1:{port}", f"http://localhost:{port}"}


def token_ok(supplied: str | None, expected: str) -> bool:
    if not supplied or not expected:
        return False
    return hmac.compare_digest(supplied.encode("utf-8", "replace"), expected.encode("utf-8"))


class HttpError(Exception):
    def __init__(self, code: int, msg: str):
        super().__init__(msg)
        self.code, self.msg = code, msg


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "SigstoreControlPanel"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    timeout = 60

    # injected on the server object
    @property
    def token(self) -> str:
        return self.server.token  # type: ignore[attr-defined]

    @property
    def port(self) -> int:
        return self.server.server_address[1]

    def log_message(self, fmt, *args):  # quiet; never log request details
        if os.environ.get("DASHBOARD_ACCESS_LOG"):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    # ---- helpers
    def _headers(self, code: int, ctype: str, length: int | None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        if length is not None:
            self.send_header("Content-Length", str(length))
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        if self.close_connection:
            self.send_header("Connection", "close")

    def _send(self, code: int, body: bytes, ctype: str):
        self._headers(code, ctype, len(body))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, obj, code: int = 200):
        self._send(code, json.dumps(obj).encode(), "application/json; charset=utf-8")

    def _err(self, code: int, msg: str):
        if self.command == "POST":  # request body may be unread: do not reuse the connection
            self.close_connection = True
        self._json({"error": msg}, code)

    def handle_expect_100(self):
        n = self.headers.get("Content-Length")
        if n and n.isdigit() and int(n) > MAX_BODY:
            self.close_connection = True
            self._err(413, "request body too large")
            return False
        return super().handle_expect_100()

    def _gate(self, api: bool):
        if not host_ok(self.headers.get("Host"), self.port):
            raise HttpError(403, "bad Host header")
        if not origin_ok(self.headers.get("Origin"), self.port):
            raise HttpError(403, "foreign Origin")
        if api and not token_ok(self.headers.get("X-Dashboard-Token"), self.token):
            raise HttpError(401, "missing or invalid token")

    def _body(self) -> dict:
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            raise HttpError(411, "Content-Length required")
        ct = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ct != "application/json":
            raise HttpError(415, "Content-Type must be application/json")
        n = self.headers.get("Content-Length")
        if n is None or not n.isdigit():
            raise HttpError(411, "Content-Length required")
        if int(n) > MAX_BODY:
            # discard (bounded) so the client can read the 413 instead of a reset
            left = min(int(n), 16 * 1024 * 1024)
            while left > 0:
                chunk = self.rfile.read(min(65536, left))
                if not chunk:
                    break
                left -= len(chunk)
            raise HttpError(413, "request body too large")
        raw = self.rfile.read(int(n)) if int(n) else b"{}"
        try:
            doc = json.loads(raw or b"{}")
        except ValueError:
            raise HttpError(400, "invalid JSON") from None
        if not isinstance(doc, dict):
            raise HttpError(400, "JSON body must be an object")
        return doc

    # ---- dispatch
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_PUT(self):
        self._err(405, "method not allowed")

    do_DELETE = do_PATCH = do_PUT

    def _dispatch(self, method: str):
        try:
            u = urllib.parse.urlsplit(self.path)
            path, query = u.path, urllib.parse.parse_qs(u.query)
            api = path.startswith("/api/")
            self._gate(api)
            if not api:
                if method != "GET" and self.command != "HEAD":
                    raise HttpError(405, "method not allowed")
                if path in ("/", "/index.html"):
                    with open(os.path.join(HERE, "index.html"), "rb") as f:
                        return self._send(200, f.read(), "text/html; charset=utf-8")
                if path == "/favicon.ico":
                    return self._send(204, b"", "image/x-icon")
                raise HttpError(404, "not found")
            if method == "GET":
                return self._api_get(path, query)
            return self._api_post(path, self._body())
        except HttpError as ex:
            self._err(ex.code, ex.msg)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except Exception as ex:
            sys.stderr.write(f"internal error: {type(ex).__name__}: {redact_text(str(ex))}\n")
            try:
                self._err(500, "internal error")
            except Exception:
                pass

    # ---- GET API
    def _api_get(self, path: str, query: dict):
        if path == "/api/overview":
            return self._json(overview())
        if path == "/api/config":
            return self._json(config_view(EnvFile()))
        if path == "/api/steps":
            return self._json({"steps": discover_steps(), "state": JOBS.snapshot(),
                               "running": JOBS.running_key(), "options": ALL_OPTIONS})
        if path == "/api/validate/last":
            return self._json({"last": load_last_validation(), "groups": [{"id": g, "title": t} for g, t in GROUPS]})
        m = re.fullmatch(r"/api/logs/([a-z0-9]+)(/stream)?", path)
        if m:
            key = m.group(1)
            if not LOG_KEYS.match(key):
                raise HttpError(400, "bad log key")
            if not m.group(2):
                return self._json({"key": key, "text": JOBS.read_log(key), "running": JOBS.running_key() == key})
            try:
                start = max(0, int(query.get("from", ["0"])[0]))
            except ValueError:
                raise HttpError(400, "bad offset") from None
            if JOBS.running_key() != key:
                raise HttpError(409, "job is not running")
            self._headers(200, "text/event-stream; charset=utf-8", None)
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True

            def write(s: str):
                self.wfile.write(s.encode())
                self.wfile.flush()
            try:
                JOBS.stream(key, start, write)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        raise HttpError(404, "not found")

    # ---- POST API
    def _api_post(self, path: str, body: dict):
        if path == "/api/config/preview":
            return self._config(body, save=False)
        if path == "/api/config/save":
            return self._config(body, save=True)
        if path == "/api/jobs/start":
            return self._start_job(body)
        if path == "/api/jobs/stop":
            return self._json({"stopped": JOBS.stop()})
        if path == "/api/validate":
            groups = body.get("groups")
            if groups is None:
                groups = GROUP_IDS
            if not isinstance(groups, list) or not groups or any(g not in GROUP_IDS for g in groups):
                raise HttpError(400, "unknown check group")
            if not VALIDATE_LOCK.acquire(blocking=False):
                raise HttpError(409, "validation already running")
            try:
                return self._json(run_validation(list(dict.fromkeys(groups))))
            finally:
                VALIDATE_LOCK.release()
        raise HttpError(404, "not found")

    def _config(self, body: dict, save: bool):
        changes = body.get("changes")
        if not isinstance(changes, dict) or len(changes) > 200:
            raise HttpError(400, "'changes' must be an object")
        env = EnvFile()
        new_raw, errors = env.validate_changes(changes)
        new_text = env.new_text(new_raw)
        plan, reasons = rerun_plan(sorted(new_raw))
        out = {"errors": errors, "changed": sorted(new_raw), "diff": unified_diff(env.text, new_text),
               "rerun": plan, "reasons": reasons, "sha": env.sha}
        if not save:
            return self._json(out)
        if errors:
            return self._json(out, 422)
        if JOBS.running_key():
            raise HttpError(409, "a script is running; wait for it to finish before saving env.sh")
        if body.get("base_sha") != env.sha:
            raise HttpError(409, "env.sh changed on disk since it was loaded; reload the page")
        if not new_raw:
            return self._json({**out, "saved": False, "message": "no changes"})
        atomic_write(env.path, new_text, backup=True)
        out["saved"] = True
        out["sha"] = hashlib.sha256(new_text.encode()).hexdigest()
        out["backup"] = "config/env.sh.bak"
        return self._json(out)

    def _start_job(self, body: dict):
        kind = body.get("kind")
        env_in = body.get("env") or {}
        args_in = body.get("args") or []
        if not isinstance(env_in, dict) or not isinstance(args_in, list):
            raise HttpError(400, "bad env/args")
        extra_env: dict[str, str] = {}
        args: list[str] = []
        if kind == "step":
            step = body.get("step")
            steps = {x["id"]: x for x in discover_steps()}
            if not isinstance(step, str) or step not in steps:
                raise HttpError(400, "unknown step")
            script, key = steps[step]["script"], step
            allowed_env = STEP_OPTIONS.get(step, {})
            allowed_args = ARG_OPTIONS.get(step, [])
            if step == DANGER_STEP:
                want = "purge" if "--purge" in args_in else "teardown"
                if body.get("confirm") != want:
                    raise HttpError(400, f"type '{want}' to confirm")
        elif kind == "all":
            script, key, allowed_env, allowed_args = "install-all.sh", "all", ALL_OPTIONS, []
        elif kind == "verify":
            script, key, allowed_env, allowed_args = "verify-stack.sh", "verify", {}, []
        elif kind == "smoke":
            if body.get("confirm") is not True:
                raise HttpError(400, "confirm that this writes a Rekor entry")
            script, key, allowed_env, allowed_args = "10-sign-and-verify.sh", "smoke", {}, []
            extra_env["AUTH"] = "ci"
        else:
            raise HttpError(400, "unknown job kind")
        for k, v in env_in.items():
            if k not in allowed_env or v not in allowed_env[k]:
                raise HttpError(400, f"option {k} not allowed")
            extra_env[k] = v
        for a in args_in:
            if a not in allowed_args:
                raise HttpError(400, f"argument {a!r} not allowed")
            args.append(a)
        try:
            resolve_script(script)
        except ValueError as ex:
            raise HttpError(400, str(ex)) from None
        try:
            job = JOBS.start(key, script, extra_env, args)
        except RuntimeError as ex:
            raise HttpError(409, str(ex)) from None
        return self._json({"job": job}, 202)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 16


def make_server(port: int, token: str, host: str = "127.0.0.1") -> Server:
    if host not in ("127.0.0.1", "localhost"):
        raise SystemExit(f"refusing to bind to {host!r}: the dashboard listens on 127.0.0.1 only")
    srv = Server(("127.0.0.1", port), Handler)
    srv.token = token  # type: ignore[attr-defined]
    return srv


def main(argv=None) -> int:
    global JOBS
    ap = argparse.ArgumentParser(description="Sigstore Control Panel (local, offline)")
    ap.add_argument("--host", default="127.0.0.1", help="must be 127.0.0.1 (anything else is refused)")
    ap.add_argument("--port", type=int, default=int(os.environ.get("DASHBOARD_PORT", DEFAULT_PORT)))
    ap.add_argument("--no-open", action="store_true", help="do not open a browser")
    a = ap.parse_args(argv)
    if a.host not in ("127.0.0.1", "localhost"):
        print(f"refusing to bind to {a.host!r}: the dashboard listens on 127.0.0.1 only", file=sys.stderr)
        return 2
    if not 1 <= a.port <= 65535:
        print("invalid --port", file=sys.stderr)
        return 2
    if not os.path.isfile(ENV_SH):
        print(f"{ENV_SH} not found (KIT_ROOT={KIT})", file=sys.stderr)
        return 2
    os.makedirs(LOG_DIR, exist_ok=True)
    JOBS = JobManager()
    token = secrets.token_urlsafe(32)
    try:
        srv = make_server(a.port, token)
    except OSError as ex:
        print(f"cannot listen on 127.0.0.1:{a.port}: {ex}", file=sys.stderr)
        return 1
    url = f"http://127.0.0.1:{a.port}/"
    print(f"Sigstore Control Panel  (kit: {KIT})")
    print(f"  URL    : {url}#token={token}")
    print(f"  Token  : {token}")
    print("  Listening on 127.0.0.1 only. Press Ctrl+C to stop.", flush=True)
    if not a.no_open:
        threading.Thread(target=lambda: webbrowser.open(f"{url}#token={token}"), daemon=True).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
