# 06 — Disaster Recovery Guide

## 1. What must survive, and why

| Asset | If lost… | Recovery possible without it? |
|---|---|---|
| **Fulcio root key** (`pki/fulcio/root.key` + `FULCIO_ROOT_PASSWORD`) | no new intermediates can be issued under the existing root | **No** — you must create a new root and redistribute trust to every client (re-root) |
| **Fulcio intermediate key** | Fulcio cannot issue certificates | Yes — issue a new intermediate from the root (docs/05 §6.2) |
| **Rekor signer key** | new entries are signed by a different key; clients reject them until trust is updated | Yes, via key rotation (docs/05 §6.3); old entries stay verifiable with the old key kept in `trusted_root.json` |
| **CT log key** | same as Rekor (SCTs) | Yes, via rotation |
| **Trillian MySQL** | the transparency history (Rekor + CT trees) | Partially — existing **bundles** still verify offline (they carry inclusion proofs), but you lose the ability to audit/search/prove consistency for old entries; new log needed |
| **Tree IDs** (`rekor-config`, `ctlog-config`) | redeploy creates new, empty trees | Yes — read them from the DB (`SELECT TreeId, DisplayName FROM Trees`) |
| **TUF repo + root.json** | clients can't refresh trust | Yes — rebuild with `12-publish-tuf.sh` (new root ⇒ redistribute `root.json`) |
| Keycloak DB | users/clients | Yes — realm is declarative (`realm-sigstore.json.tpl`); users from backup or IdP |
| Registry PVC | images + attached signatures | Re-push and re-sign, or restore volume snapshot |
| Redis | nothing important | Rebuilt by Rekor (backfill-redis) |

**Key insight:** because cosign v3 bundles embed the certificate, SCT, signed
entry timestamp and inclusion proof, **verification of already-signed artifacts
needs only `trusted_root.json`**. Losing the running services stops *new*
signing; it does not invalidate existing signatures as long as the trust root
is kept.

## 2. Backup strategy

| What | How | Frequency | Retention |
|---|---|---|---|
| `pki/` (all keys + `secrets.env`) | `backup.sh` → `pki.tar.gz.enc` (AES-256-CBC, PBKDF2 600k) | at creation + after every rotation | forever; 2 offline copies, 2 sites |
| Root key | separate encrypted USB/HSM in a safe; **delete from laptop** after creating the intermediate | at ceremony | forever |
| Trillian MySQL | `mysqldump --single-transaction` (in `backup.sh`) | daily (prod: continuous PITR) | 90 days + monthly forever |
| Tree IDs | `tree-ids.env` (in `backup.sh`) | with every DB backup | with DB |
| `out/` (trusted root, signing config, TUF repo) | `out.tar.gz` | after every change | forever |
| Keycloak | realm partial export + H2 files | daily | 30 days |
| Rekor attestation storage | tar of `/var/run/attestations` | daily | 90 days |

```bash
BACKUP_PASSPHRASE='…long passphrase from your vault…' scripts/backup.sh
# -> backups/20261020T080000Z/{pki.tar.gz.enc,out.tar.gz,trillian.sql.gz,tree-ids.env,
#                              keycloak-realm.json,keycloak-h2.tar.gz,rekor-attestations.tar.gz,MANIFEST.sha256}
```

Copy `backups/<ts>/` off the laptop. Test-decrypt periodically:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in backups/<ts>/pki.tar.gz.enc | tar -tzf - | head
```

## 3. Recovery objectives (laptop / production guidance)

| Scenario | RPO | RTO (laptop) | RTO (prod target) |
|---|---|---|---|
| Pod/node failure | 0 | minutes (self-healing) | minutes |
| Cluster lost, backups intact | last DB backup | ~20 min (`restore.sh`) | < 1 h |
| Laptop lost | last off-laptop backup | ~30 min on a new laptop + bundle | n/a |
| Intermediate key compromised | n/a | 30 min (rotate) + client trust refresh | < 4 h |
| Root key compromised | n/a | re-root: days (all clients) | ceremony + distribution plan |

## 4. Restore runbook (full rebuild)

Prerequisites: the kit folder with `bundle/`, a backup directory, its passphrase.

```bash
mv pki pki.broken 2>/dev/null || true          # restore never overwrites keys
BACKUP_PASSPHRASE='…' scripts/restore.sh backups/20261020T080000Z
```

What `restore.sh` does, in order (do these by hand if a step fails):

1. Verify `MANIFEST.sha256`; decrypt `pki/`; unpack `out/`.
2. `02` mirror → `04` cluster → `05` ingress/DNS → `06` registry → `07` Keycloak.
3. Restore Keycloak H2 files (scale to 0, copy into PVC, scale to 1).
4. Install **only** the Trillian release, then load the dump:
   ```bash
   gzip -dc trillian.sql.gz | kubectl -n trillian-system exec -i deploy/trillian-mysql -- \
     sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'
   kubectl -n trillian-system rollout restart deploy/trillian-logserver deploy/trillian-logsigner
   ```
5. Export the old tree IDs and run `08`:
   ```bash
   set -a; source backups/<ts>/tree-ids.env; set +a     # REKOR_TREE_ID, CTLOG_TREE_ID
   scripts/08-deploy-sigstore.sh                         # passes --set server.config.treeID=…
   ```
   The charts' `createtree` Jobs find the tree ID already set and create
   nothing; `createctconfig` rebuilds the CT config from **the same key** and
   **the same tree**.
6. `12` TUF, `13` policy, `verify-stack.sh`.

## 5. Proven in the integration test

The DR mechanism above was exercised against the running Docker harness:

```
before: {"treeSize":4,"rootHash":"745e2e67…"}
dump: 12K
databases after loss: information_schema mysql performance_schema sys      <- trillian DB dropped
restored leaves per tree: 3691848446415370687:4 5508145943716122533:4
after:  {"treeSize":4,"rootHash":"745e2e67…"}                               <- identical root hash
old signature (alice) still verifies
consistency proof 4 -> 5 after a new signature: {"hashes":1}               <- log continues append-only
```

## 6. Post-restore validation checklist

```bash
scripts/verify-stack.sh                                       # all PASS
curl -fsS --cacert pki/tls/ca.crt https://rekor.sigstore.local/api/v1/log | jq .treeSize   # == pre-incident size
cosign verify --trusted-root out/trusted_root.json \
  --certificate-identity alice@sigstore.local \
  --certificate-oidc-issuer https://keycloak.sigstore.local/realms/sigstore \
  "$(cat out/last-signed-image)"                              # an artifact signed BEFORE the incident
AUTH=password scripts/10-sign-and-verify.sh                   # new signing works
OLD=<treeSize before>; NEW=$(curl -fsS --cacert pki/tls/ca.crt https://rekor.sigstore.local/api/v1/log | jq .treeSize)
curl -fsS --cacert pki/tls/ca.crt "https://rekor.sigstore.local/api/v1/log/proof?firstSize=$OLD&lastSize=$NEW" | jq .  # consistency
```

## 7. Scenario playbooks

### 7.1 Trillian DB corrupted, no usable backup

1. Keep the trust root. Existing signatures still verify offline.
2. Create **new** trees: delete the `treeID` keys from ConfigMaps
   `rekor-config` and `ctlog-config` (or pass new IDs), re-run `08`.
3. Rekor's log ID depends on its **key**, not the tree, so `trusted_root.json`
   stays valid; but add a note in your change log that the log restarted at a
   given time (auditors will see a new tree ID in checkpoints).
4. Optionally use a new Rekor key + add it to `trusted_root.json` with a new
   `start-time` to make the break explicit (docs/05 §6.3).

### 7.2 Intermediate key compromised

1. Stop Fulcio (`kubectl -n fulcio-system scale deploy/fulcio-server --replicas=0`).
2. Issue a new intermediate (docs/05 §6.2), update `fulcio-server-secret`,
   regenerate `trusted_root.json` with the **old intermediate given an end
   time** = compromise time (`cosign trusted-root create` supports
   `end-time` on `--fulcio`), republish TUF.
3. Search Rekor for certificates issued after the compromise time and
   investigate; signatures in that window must be treated as untrusted.

### 7.3 Root key compromised

Treat as total loss of trust: generate a new PKI (`03 --force`), redeploy,
publish a new TUF root, re-sign every artifact you still trust, and remove the
old root from every verifier. Document the incident.

### 7.4 Laptop stolen

Assume `pki/` is compromised if it was on the laptop unencrypted (the keys are
password-encrypted, but `secrets.env` holds the passwords). Follow 7.2 for the
intermediate and Rekor/CT keys; if the root key was on the laptop, follow 7.3.
**This is why the root key must not live on the laptop.**
