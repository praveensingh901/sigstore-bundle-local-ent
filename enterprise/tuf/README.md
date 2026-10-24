# enterprise/tuf — private TUF repository tooling

| File | Purpose |
|---|---|
| `tufctl.py` | Create, sign, publish and verify the repository (python-tuf Metadata API, securesystemslib signers: `hsm:`, `awskms:`, `file2:` for tests) |
| `test.sh` | Offline end-to-end test: thresholds enforced, online key cannot sign root, client update, tamper detection, `cosign initialize` |
| `requirements.txt` | Pinned Python dependencies |
| `root/` | The pinned `1.root.json` (after the ceremony) |

Design: [04-trust-distribution.md](../docs/04-trust-distribution.md). Publishing pipeline: `../ci/tuf-publish.yml`, `../ci/tuf-replicate.yml`.

```bash
pip install -r requirements.txt
./test.sh            # PASS tufctl
```

Yearly root renewal and key rotation use `root-update`: it stages root version N+1 (new expiry, keys
added/removed, optional new online key) and `refresh` refuses to publish it until it carries a
threshold of signatures from the new keys **and** from the version-N keys (TUF specification §5.3.4).
`test.sh` rotates a custodian key and checks that a client pinned to `1.root.json` walks to `2.root.json`.
