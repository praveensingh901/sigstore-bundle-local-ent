# 14 · Sigstore Control Panel (local dashboard)

A small web UI for the offline kit: configure `config/env.sh`, run the install
steps, and validate the whole stack. It runs **on your laptop only**, offline:
Python 3.10+ standard library (no pip packages) and a single HTML file with no
CDN or external fonts.

```bash
scripts/dashboard.sh                # http://127.0.0.1:9443, opens your browser
scripts/dashboard.sh --port 9500    # or DASHBOARD_PORT=9500
scripts/dashboard.sh --no-open      # print the URL only (SSH / headless)
```

The script prints the URL and a fresh random access token on every start. The
URL ends in `#token=...`; the page reads the token from the fragment, keeps it
in `sessionStorage` and removes it from the address bar. Stop with Ctrl+C.

## Tabs

| Tab | What it does |
|---|---|
| **Overview** | Tiles: install progress (steps that passed *when run from the dashboard*), validation pass/fail counts, days to the earliest certificate expiry (TLS root, wildcard, Fulcio root and intermediate), days to TUF metadata expiry, and the time of the last validation. |
| **Configure** | A form generated from `config/env.sh`, grouped by its `# ---- Section ----` headers, with each comment as help text. Only allowlisted keys are editable (domain, cluster name, ingress IP, OIDC names, URLs, mirror name/port, pinned versions); everything else is read-only. **Preview** shows a unified diff; **Save** writes atomically (temp file + rename), keeps `config/env.sh.bak`, and preserves comments, ordering and quoting. After a change it lists the install steps you must re-run (for example `DOMAIN` means regenerate the PKI, step 03, and everything after it). |
| **Install** | One card per `scripts/NN-*.sh` (00-14) with its header comment, status (not run / running / passed / failed, exit code, duration, time), **Run** and **View log**. Step 01 is marked "run on the online machine". Only one script runs at a time; output streams live (Server-Sent Events). **Run all** runs `install-all.sh`. `99-teardown.sh` sits in a danger zone and needs a typed confirmation (`teardown`, or `purge` with `--purge`). Step 10 and 13 offer `AUTH` / `POLICY_ACTION` selectors. |
| **Validate** | Run all checks or one group; results are a table of group, check, PASS / WARN / FAIL / SKIP, detail and fix hint. A check whose prerequisite is missing (no kubectl, no cluster, no gitsign) is SKIP with the reason. Also: the optional signing smoke test and the raw `verify-stack.sh` output. |

### Check groups

| Group | Checks |
|---|---|
| Platform | mirror container, kind cluster, node Ready, node `/etc/hosts`, laptop DNS for each `*.DOMAIN` host (as `verify-stack.sh`) |
| Pods | every namespace `verify-stack.sh` looks at; Running but not Ready is a WARN |
| Endpoints (TLS) | verified against `pki/tls/ca.crt`: Keycloak discovery `issuer`, Fulcio `/api/v1/rootCert` (and equals `pki/fulcio/chain.pem`), Fulcio `/api/v2/configuration` lists `OIDC_ISSUER`, Rekor `/api/v1/log` treeSize and key, CT log key, CT log reachability, registry `/v2/`, TUF `timestamp.json` expiry (FAIL under 1 day, WARN under 3) |
| Certificates | `openssl x509` on the four PEMs under `pki/`; WARN under 30 days, FAIL when expired |
| Trust material | `out/trusted_root.json` and `out/signing_config.json` parse; their Fulcio and Rekor URLs equal `env.sh` and the CT log URL ends in `/CTLOG_PREFIX`; TUF expiry from `out/tuf/meta.env` (WARN under 30 days) |
| Policy | Kyverno `ImageValidatingPolicy require-private-sigstore-signature` exists, is ready, and has `validationActions: [Deny]` (Audit is a WARN) |
| gitsign | binary and version, `out/gitsign/gitsign.env`, every file it references |

Notes:

* The CT log is **not exposed outside the cluster** by the kit
  (`http://ctlog.ctlog-system.svc/sigstore`), so `env.sh` only contains its path
  prefix. The dashboard checks it through the Kubernetes API proxy and SKIPs
  without a cluster. For a CT log you can reach directly (test harnesses), set
  `DASHBOARD_CTLOG_URL=http://host:port/prefix`.
* The **signing smoke test** runs `scripts/10-sign-and-verify.sh` with
  `AUTH=ci` and **writes a Rekor entry**; it needs a tick-box confirmation.
* Install progress only knows about runs started from the dashboard.

## Security model

* Binds to `127.0.0.1` only; any other `--host` is refused. Plain HTTP on loopback.
* A random 32-byte token per start; every `/api/*` call needs the
  `X-Dashboard-Token` header (`hmac.compare_digest`). Requests whose `Host` is not
  `127.0.0.1:<port>` / `localhost:<port>` (DNS rebinding) or whose `Origin` is
  foreign are rejected with 403. No CORS headers are sent.
* Responses carry a strict `Content-Security-Policy`, `X-Content-Type-Options: nosniff`
  and `Referrer-Policy: no-referrer`.
* No arbitrary execution: only `scripts/NN-*.sh`, `install-all.sh` and
  `verify-stack.sh`, resolved with `realpath` inside `scripts/`, started with
  list-form `subprocess` (never `shell=True`). Environment overrides and
  arguments come from fixed allowlists.
* POST bodies must be JSON, at most 256 KiB (413 otherwise). The UI renders all
  data with `textContent`.
* `pki/secrets.env` and `*.key` files are never read or served. Logs and API
  output are redacted: lines containing `PASSWORD=`, `TOKEN=` or `SECRET`, JWTs
  (`eyJ...`) and PEM private-key blocks.
* The server is single-user tooling. Anyone who can run processes as you on the
  laptop can read the token from the process list or terminal; protect the laptop.

## Files

| Path | Purpose |
|---|---|
| `dashboard/server.py` | the server (standard library only) |
| `dashboard/index.html` | the UI (inline CSS/JS) |
| `dashboard/test_server.py` | unit tests: `python3 -m unittest -v dashboard/test_server.py` |
| `out/dashboard/state.json` | per-step status |
| `out/dashboard/logs/NN.log` | step logs (`all.log`, `verify.log`, `smoke.log`) |
| `out/dashboard/last-validation.json` | most recent result per check group |
| `config/env.sh.bak` | copy of `env.sh` before the last save |

## Troubleshooting

| Symptom | Fix |
|---|---|
| "No access token" banner | open the full URL printed by `dashboard.sh`, including `#token=...` |
| 403 "bad Host header" | use `http://127.0.0.1:<port>/` or `http://localhost:<port>/`, not another name or a tunnel |
| "another job is already running" | wait, or press **Stop running script** |
| Every Endpoint check FAILs "cannot resolve" | hosts entries missing: `sudo scripts/setup-hosts.sh --trust-ca` |
| Port in use | `scripts/dashboard.sh --port 9500` |
