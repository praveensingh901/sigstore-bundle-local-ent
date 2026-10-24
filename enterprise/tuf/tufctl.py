#!/usr/bin/env python3
"""tufctl.py — manage the private Sigstore TUF repository (04-trust-distribution.md).

Built on python-tuf's Metadata API and securesystemslib signers, so the same
commands work with hardware tokens (hsm:), AWS KMS (awskms:) and, for tests,
key files (file2:).

Layout of --repo:
  staged/           metadata being prepared and signed (root.json, targets.json)
  targets/          target files staged by add-target
  publish/          the static tree to upload, in this order:
                      targets/<sha256>.<name>, N.root.json, root.json,
                      N.targets.json, N.snapshot.json, timestamp.json (last)

Commands
  init        --repo R --root-key PEM [...] --online-pub PEM [--threshold 2]
  add-target  --repo R FILE [...]
  sign        --repo R --role root|targets --signer URI [--pub PEM]
  root-update --repo R [--add-root-key PEM] [--remove-root-key PEM]
              [--online-pub PEM] [--threshold N]     new root version (renewal / key rotation)
  refresh     --repo R --online-signer URI --online-pub PEM
  verify      --repo R --root ROOT.json   (acts as a client: full TUF update)

Exit codes: 0 ok, 1 usage/validation error, 2 threshold not met.
"""
from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import os
import shutil
import socketserver
import sys
import tempfile
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path

from securesystemslib.signer import CryptoSigner, Signer, SSlibKey
from tuf.api.metadata import (
    SPECIFICATION_VERSION, Metadata, MetaFile, Role, Root, Snapshot, TargetFile, Targets, Timestamp,
)
from tuf.api.serialization.json import JSONSerializer

EXPIRY = {  # 04 §2
    "root": timedelta(days=365),
    "targets": timedelta(days=180),
    "snapshot": timedelta(days=7),
    "timestamp": timedelta(days=7),
}
SERIALIZER = JSONSerializer(compact=False)


def now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def die(msg: str, code: int = 1):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


def load_pub(path: str) -> SSlibKey:
    from cryptography.hazmat.primitives.serialization import load_pem_public_key
    return SSlibKey.from_crypto(load_pem_public_key(Path(path).read_bytes()))


def signer_for(uri: str, pub: str | None) -> Signer:
    if uri.startswith("file2:"):
        key_path = uri.split(":", 1)[1]
        from cryptography.hazmat.primitives.serialization import load_pem_private_key
        priv = load_pem_private_key(Path(key_path).read_bytes(), password=None)
        return CryptoSigner(priv)
    if not pub:
        die("--pub/--online-pub is required for this signer URI")
    return Signer.from_priv_key_uri(uri, load_pub(pub))


class Repo:
    def __init__(self, path: str):
        self.base = Path(path)
        self.staged = self.base / "staged"
        self.tdir = self.base / "targets"
        self.pub = self.base / "publish"

    def read(self, role: str) -> Metadata:
        p = self.staged / f"{role}.json"
        if not p.exists():
            die(f"{p} not found (run init first)")
        return Metadata.from_file(str(p))

    def write(self, role: str, md: Metadata):
        self.staged.mkdir(parents=True, exist_ok=True)
        md.to_file(str(self.staged / f"{role}.json"), SERIALIZER)


def prev_root(repo: "Repo", root: Root) -> Root | None:
    """The root a new root version must also be signed by (TUF spec 5.3.4)."""
    p = repo.staged / "root.prev.json"
    if not p.exists():
        return None
    prev = Metadata.from_file(str(p)).signed
    return prev if prev.version == root.version - 1 else None


def root_threshold_ok(repo: "Repo", root_md: Metadata) -> tuple[bool, str]:
    """New root: threshold of its own keys AND of the previous root's keys."""
    ok, msg = threshold_ok(root_md.signed, "root", root_md)
    prev = prev_root(repo, root_md.signed)
    if prev is None:
        return ok, msg
    ok_prev, msg_prev = threshold_ok(prev, "root", root_md)
    return ok and ok_prev, f"{msg} (new keys); {msg_prev.replace('root:', 'root v%d keys:' % prev.version)}"


def threshold_ok(root: Root, role: str, md: Metadata) -> tuple[bool, str]:
    r = root.roles[role]
    valid = 0
    for keyid in r.keyids:
        if keyid in md.signatures:
            try:
                root.keys[keyid].verify_signature(md.signatures[keyid], md.signed_bytes)
                valid += 1
            except Exception:  # noqa: BLE001 - invalid signature counts as missing
                pass
    return valid >= r.threshold, f"{role}: {valid}/{r.threshold} valid signatures"


# ---------------------------------------------------------------- commands
def cmd_init(a):
    repo = Repo(a.repo)
    if (repo.staged / "root.json").exists():
        die("repository already initialised")
    root_keys = [load_pub(p) for p in a.root_key]
    online = load_pub(a.online_pub)
    if a.threshold > len(root_keys):
        die("threshold larger than the number of root keys")

    root = Root(expires=now() + EXPIRY["root"], consistent_snapshot=True)
    for k in root_keys:
        root.add_key(k, "root")
        root.add_key(k, "targets")
    root.roles["root"].threshold = a.threshold
    root.roles["targets"].threshold = a.threshold
    root.add_key(online, "snapshot")
    root.add_key(online, "timestamp")
    repo.write("root", Metadata(root))
    repo.write("targets", Metadata(Targets(expires=now() + EXPIRY["targets"])))
    print(f"initialised {repo.staged}: root and targets need {a.threshold} signatures each")


def cmd_add_target(a):
    repo = Repo(a.repo)
    md = repo.read("targets")
    repo.tdir.mkdir(parents=True, exist_ok=True)
    for f in a.files:
        data = Path(f).read_bytes()
        name = Path(f).name
        tf = TargetFile.from_data(name, data, ["sha256"])
        md.signed.targets[name] = tf
        (repo.tdir / f"{tf.hashes['sha256']}.{name}").write_bytes(data)
        print(f"target {name} sha256={tf.hashes['sha256']}")
    md.signed.version += 1
    md.signed.expires = now() + EXPIRY["targets"]
    md.signatures.clear()          # content changed: custodians must sign again
    repo.write("targets", md)
    print(f"targets v{md.signed.version} staged; needs custodian signatures")


def cmd_sign(a):
    repo = Repo(a.repo)
    md = repo.read(a.role)
    signer = signer_for(a.signer, a.pub)
    root = repo.read("root").signed
    allowed = set(root.roles[a.role].keyids)
    prev = prev_root(repo, root) if a.role == "root" else None
    if prev is not None:
        allowed |= set(prev.roles["root"].keyids)     # old keys co-sign a new root
    if signer.public_key.keyid not in allowed:
        die(f"key {signer.public_key.keyid[:12]} is not a {a.role} key in the staged (or previous) root")
    md.sign(signer, append=True)
    repo.write(a.role, md)
    _, msg = root_threshold_ok(repo, md) if a.role == "root" else threshold_ok(root, a.role, md)
    print(f"signed {a.role} v{md.signed.version} with {signer.public_key.keyid[:12]}; {msg}")


def cmd_root_update(a):
    """Stage root version N+1: renew expiry and/or change keys. Needs signatures
    from a threshold of the new AND the previous root keys before publishing."""
    repo = Repo(a.repo)
    cur = repo.read("root")
    ok, msg = root_threshold_ok(repo, cur)
    if not ok:
        die(f"current staged root is not fully signed ({msg}); publish it before updating", 2)
    shutil.copy(repo.staged / "root.json", repo.staged / "root.prev.json")
    new = Metadata.from_bytes(cur.to_bytes())
    r = new.signed
    for pem in a.remove_root_key or []:
        k = load_pub(pem)
        for role in ("root", "targets"):
            if k.keyid in r.roles[role].keyids:
                r.revoke_key(k.keyid, role)
    for pem in a.add_root_key or []:
        k = load_pub(pem)
        r.add_key(k, "root")
        r.add_key(k, "targets")
    if a.online_pub:
        new_online = load_pub(a.online_pub)
        for role in ("snapshot", "timestamp"):
            for keyid in list(r.roles[role].keyids):
                r.revoke_key(keyid, role)
            r.add_key(new_online, role)
    if a.threshold:
        r.roles["root"].threshold = a.threshold
        r.roles["targets"].threshold = a.threshold
    for role in ("root", "targets"):
        if len(r.roles[role].keyids) < r.roles[role].threshold:
            die(f"{role} would have fewer keys than its threshold")
    r.version += 1
    r.expires = now() + EXPIRY["root"]
    new.signatures.clear()
    repo.write("root", new)
    # targets keys may have changed: targets must be re-signed by the new keys
    t = repo.read("targets")
    if a.add_root_key or a.remove_root_key or a.threshold:
        t.signed.version += 1
        t.signed.expires = now() + EXPIRY["targets"]
        t.signatures.clear()
        repo.write("targets", t)
    print(f"root v{r.version} staged (expires {r.expires.date()}); needs {r.roles['root'].threshold} signatures "
          f"from the new keys and {prev_root(repo, r).roles['root'].threshold} from the v{r.version - 1} keys")


def cmd_refresh(a):
    """Sign snapshot + timestamp with the online key and build publish/."""
    repo = Repo(a.repo)
    root_md, targets_md = repo.read("root"), repo.read("targets")
    root = root_md.signed
    for role, md in (("root", root_md), ("targets", targets_md)):
        ok, msg = root_threshold_ok(repo, md) if role == "root" else threshold_ok(root, role, md)
        if not ok:
            die(f"threshold not met, nothing published: {msg}", 2)
        if md.signed.expires <= now():
            die(f"{role} metadata has expired; custodians must re-sign", 2)

    online = signer_for(a.online_signer, a.online_pub)
    if online.public_key.keyid not in root.roles["timestamp"].keyids:
        die("online signer is not the timestamp/snapshot key in root")

    pub = repo.pub
    prev_snapshot = 0
    if (pub / "timestamp.json").exists():
        prev_snapshot = Metadata.from_file(str(pub / "timestamp.json")).signed.snapshot_meta.version
    tmp = Path(tempfile.mkdtemp(prefix="tuf-publish-"))
    shutil.copytree(pub, tmp, dirs_exist_ok=True) if pub.exists() else None

    (tmp / "targets").mkdir(parents=True, exist_ok=True)
    for f in repo.tdir.glob("*"):
        shutil.copy2(f, tmp / "targets" / f.name)
    # every root version stays published so clients can walk the chain
    root_md.to_file(str(tmp / f"{root.version}.root.json"), SERIALIZER)
    root_md.to_file(str(tmp / "root.json"), SERIALIZER)
    targets_md.to_file(str(tmp / f"{targets_md.signed.version}.targets.json"), SERIALIZER)

    snap = Metadata(Snapshot(version=prev_snapshot + 1, expires=now() + EXPIRY["snapshot"],
                             meta={"targets.json": MetaFile(version=targets_md.signed.version)}))
    snap.sign(online)
    snap.to_file(str(tmp / f"{snap.signed.version}.snapshot.json"), SERIALIZER)
    ts = Metadata(Timestamp(version=prev_snapshot + 1, expires=now() + EXPIRY["timestamp"],
                            snapshot_meta=MetaFile(version=snap.signed.version)))
    ts.sign(online)
    ts.to_file(str(tmp / "timestamp.json"), SERIALIZER)

    if pub.exists():
        shutil.rmtree(pub)
    shutil.move(str(tmp), str(pub))
    print(f"publish/ ready: root v{root.version}, targets v{targets_md.signed.version}, "
          f"snapshot v{snap.signed.version}, timestamp expires {ts.signed.expires.isoformat()}")
    print("upload order: targets/ and versioned metadata first, timestamp.json last")


def cmd_verify(a):
    """Run a real TUF client update against publish/ (served on localhost)."""
    from tuf.ngclient import Updater

    repo = Repo(a.repo)
    pub = repo.pub.resolve()

    class Quiet(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kw):
            super().__init__(*args, directory=str(pub), **kw)

        def log_message(self, *_):
            pass

    with socketserver.TCPServer(("127.0.0.1", 0), Quiet) as httpd:
        port = httpd.server_address[1]
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        with tempfile.TemporaryDirectory() as meta, tempfile.TemporaryDirectory() as dl:
            up = Updater(metadata_dir=meta, metadata_base_url=f"http://127.0.0.1:{port}/",
                         target_base_url=f"http://127.0.0.1:{port}/targets/", target_dir=dl,
                         bootstrap=Path(a.root).read_bytes())
            up.refresh()
            for name in a.targets:
                info = up.get_targetinfo(name)
                if info is None:
                    die(f"target {name} not in repository")
                path = up.download_target(info)
                print(f"ok   {name} sha256={hashlib.sha256(Path(path).read_bytes()).hexdigest()}")
        httpd.shutdown()
    ts = json.loads((pub / "timestamp.json").read_text())["signed"]["expires"]
    left = datetime.fromisoformat(ts.replace("Z", "+00:00")) - now()
    print(f"ok   client update succeeded; timestamp valid for {left.days} more days")
    if left < timedelta(days=3):
        die("timestamp expires in less than 3 days (alert threshold)", 2)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("init")
    s.add_argument("--repo", required=True)
    s.add_argument("--root-key", action="append", required=True, help="custodian public key (PEM); repeat")
    s.add_argument("--online-pub", required=True, help="public key of the online KMS key (PEM)")
    s.add_argument("--threshold", type=int, default=2)
    s.set_defaults(fn=cmd_init)

    s = sub.add_parser("add-target")
    s.add_argument("--repo", required=True)
    s.add_argument("files", nargs="+")
    s.set_defaults(fn=cmd_add_target)

    s = sub.add_parser("sign")
    s.add_argument("--repo", required=True)
    s.add_argument("--role", choices=["root", "targets"], required=True)
    s.add_argument("--signer", required=True, help="hsm:..., awskms:..., or file2:<private key PEM> (tests)")
    s.add_argument("--pub", help="public key PEM for hsm:/awskms: signers")
    s.set_defaults(fn=cmd_sign)

    s = sub.add_parser("root-update")
    s.add_argument("--repo", required=True)
    s.add_argument("--add-root-key", action="append", help="custodian public key to add (PEM); repeat")
    s.add_argument("--remove-root-key", action="append", help="custodian public key to remove (PEM); repeat")
    s.add_argument("--online-pub", help="replace the snapshot/timestamp key with this public key (PEM)")
    s.add_argument("--threshold", type=int)
    s.set_defaults(fn=cmd_root_update)

    s = sub.add_parser("refresh")
    s.add_argument("--repo", required=True)
    s.add_argument("--online-signer", required=True)
    s.add_argument("--online-pub")
    s.set_defaults(fn=cmd_refresh)

    s = sub.add_parser("verify")
    s.add_argument("--repo", required=True)
    s.add_argument("--root", required=True, help="the root.json clients pin")
    s.add_argument("--targets", nargs="*", default=["trusted_root.json", "signing_config.v0.2.json"])
    s.set_defaults(fn=cmd_verify)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
