"""Unit tests for dashboard/server.py (stdlib unittest).  Run:
    python3 -m unittest -v laptop/dashboard/test_server.py
"""
import http.client
import json
import os
import tempfile
import threading
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault("KIT_ROOT", os.path.realpath(os.path.join(HERE, "..")))
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("dashboard_server", os.path.join(HERE, "server.py"))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

SAMPLE = '''# header comment
# ---- Naming / DNS ----------------------------------------------------------
# All endpoints live under this zone.
export DOMAIN="${DOMAIN:-sigstore.local}"
export KEYCLOAK_HOST="keycloak.${DOMAIN}"
export OIDC_REALM="sigstore"
export OIDC_REDIRECT_URL="http://localhost:8765/auth/callback"   # loopback redirect
export DEMO_USER_EMAIL="alice@${DOMAIN}"

# ---- Pinned versions ---------------------------------------------------------
export COSIGN_VERSION="v3.1.3"                   # keyless client
export MIRROR_PORT="5000"                        # bound to 127.0.0.1 only
export UNQUOTED=abc
'''


class EnvParseTests(unittest.TestCase):
    def test_roundtrip_unchanged_real_file(self):
        env = S.EnvFile()
        self.assertEqual(env.new_text({}), env.text)
        self.assertEqual(S.unified_diff(env.text, env.new_text({})), "")
        self.assertEqual(len(env.entries), 44)

    def test_roundtrip_sample_and_comments_kept(self):
        lines, entries = S.parse_env_text(SAMPLE)
        self.assertEqual("".join(lines), SAMPLE)
        self.assertEqual(S.render_env_text(lines, entries, {}), SAMPLE)
        by = {e.key: e for e in entries}
        self.assertEqual(by["DOMAIN"].section, "Naming / DNS")
        self.assertEqual(by["DOMAIN"].help, "All endpoints live under this zone.")
        self.assertEqual(by["COSIGN_VERSION"].help, "keyless client")
        self.assertEqual(by["COSIGN_VERSION"].section, "Pinned versions")
        self.assertEqual(by["UNQUOTED"].raw, "abc")

    def test_edit_preserves_everything_else(self):
        lines, entries = S.parse_env_text(SAMPLE)
        new = S.render_env_text(lines, entries, {"COSIGN_VERSION": "v3.2.0", "DOMAIN": "${DOMAIN:-corp.local}"})
        a, b = SAMPLE.splitlines(), new.splitlines()
        self.assertEqual(len(a), len(b))
        changed = [(x, y) for x, y in zip(a, b) if x != y]
        self.assertEqual(len(changed), 2)
        self.assertIn('export COSIGN_VERSION="v3.2.0"                   # keyless client', b)
        self.assertIn('export DOMAIN="${DOMAIN:-corp.local}"', b)
        self.assertIn("# header comment", b)

    def test_no_edits_means_empty_diff_via_validate(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "env.sh")
            Path(p).write_text(SAMPLE)
            env = S.EnvFile(p)
            raw, errs = env.validate_changes({"DOMAIN": "sigstore.local", "OIDC_REALM": "sigstore"})
            self.assertEqual((raw, errs), ({}, {}))  # same values: nothing changes
            self.assertEqual(S.unified_diff(env.text, env.new_text(raw)), "")

    def test_atomic_save_with_backup(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "env.sh")
            Path(p).write_text(SAMPLE)
            os.chmod(p, 0o640)
            env = S.EnvFile(p)
            raw, errs = env.validate_changes({"COSIGN_VERSION": "v3.9.9"})
            self.assertFalse(errs)
            S.atomic_write(p, env.new_text(raw), backup=True)
            self.assertEqual(Path(p + ".bak").read_text(), SAMPLE)
            self.assertIn('COSIGN_VERSION="v3.9.9"', Path(p).read_text())
            self.assertEqual(os.stat(p).st_mode & 0o777, 0o640)
            self.assertEqual([f for f in os.listdir(d) if f.startswith(".env.sh.")], [])


class ValidationTests(unittest.TestCase):
    def ok(self, fn, *vals):
        for v in vals:
            fn(v)

    def bad(self, fn, *vals):
        for v in vals:
            with self.assertRaises(S.ValidationError, msg=repr(v)):
                fn(v)

    def test_domain(self):
        self.ok(S.v_domain, "sigstore.local", "a", "corp-1.example.com")
        self.bad(S.v_domain, "", "Sigstore.local", "-a.local", "a..local", "a_b.local", "x" * 64 + ".com", "a b")

    def test_label(self):
        self.ok(S.v_label, "sigstore", "k8s-1")
        self.bad(S.v_label, "a.b", "A", "-x", "x-")

    def test_version(self):
        self.ok(S.v_version, "v3.1.3", "0.18.0")
        self.bad(S.v_version, "3.1", "v3.1.3-rc1", "latest", "v3.1.x", "")

    def test_ports_and_ints(self):
        f = S.v_int(1024, 65535)
        self.ok(f, "5000", "1024", "65535")
        self.bad(f, "80", "65536", "-1", "abc", "50 00", "")

    def test_url(self):
        self.ok(S.v_url_https, "https://fulcio.sigstore.local", "https://a.b.c/path")
        self.bad(S.v_url_https, "http://fulcio.sigstore.local", "ftp://x.y", "https://", "https://u:p@a.b",
                 "https://a.b/?q=1", "https://A.B", "javascript:alert(1)", "http://localhost:8765/auth/callback")
        self.ok(S.v_url_redirect, "http://localhost:8765/auth/callback", "http://127.0.0.1:9000/cb", "https://app.corp.local/cb")
        self.bad(S.v_url_redirect, "http://evil.example.com/cb", "http://localhost/cb")

    def test_email(self):
        self.ok(S.v_email, "alice@sigstore.local")
        self.bad(S.v_email, "alice", "Alice@x.local", "a@b", "a@@b.c", "a b@c.local")

    def test_ip(self):
        f = S.v_ipv4_in("10.96.0.0/16")
        self.ok(f, "10.96.100.100")
        self.bad(f, "10.97.0.1", "999.1.1.1", "abc")

    def test_changes_end_to_end(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "env.sh")
            Path(p).write_text(SAMPLE)
            env = S.EnvFile(p)
            raw, errs = env.validate_changes({
                "DOMAIN": "Bad_Domain", "KEYCLOAK_HOST": "x.local", "NOPE": "1",
                "COSIGN_VERSION": 'v1.2.3"; rm -rf /; "', "MIRROR_PORT": "80",
                "OIDC_REALM": "$(id)"})
            self.assertIn("DOMAIN", errs)
            self.assertIn("read-only", errs["KEYCLOAK_HOST"])
            self.assertEqual(errs["NOPE"], "unknown setting")
            self.assertIn("COSIGN_VERSION", errs)
            self.assertIn("MIRROR_PORT", errs)
            self.assertIn("OIDC_REALM", errs)
            raw, errs = env.validate_changes({"DEMO_USER_EMAIL": "bob@${DOMAIN}"})  # ${DOMAIN} reference is allowed
            self.assertEqual((raw, errs), ({"DEMO_USER_EMAIL": "bob@${DOMAIN}"}, {}))
            raw, errs = env.validate_changes({"DEMO_USER_EMAIL": "bob@${NOPE}"})
            self.assertIn("DEMO_USER_EMAIL", errs)

    def test_domain_default_wrapper_kept(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "env.sh")
            Path(p).write_text(SAMPLE)
            env = S.EnvFile(p)
            raw, errs = env.validate_changes({"DOMAIN": "corp.example"})
            self.assertEqual(raw, {"DOMAIN": "${DOMAIN:-corp.example}"})
            plan, reasons = S.rerun_plan(sorted(raw))
            steps = [x["step"] for x in plan]
            self.assertEqual(steps[0], "03")
            self.assertIn("14", steps)
            self.assertNotIn("02", steps)

    def test_every_editable_key_exists_in_real_env(self):
        keys = {e.key for e in S.EnvFile().entries}
        self.assertFalse(set(S.EDITABLE) - keys)
        self.assertFalse(set(S.RERUN) - set(S.EDITABLE))


class ScriptNameTests(unittest.TestCase):
    def test_traversal_and_bad_names_rejected(self):
        for name in ["../../bin/sh", "../scripts/03-generate-pki.sh", "/bin/sh", "/etc/passwd",
                     "03-generate-pki.sh/../../x", "lib.sh", "backup.sh", "setup-hosts.sh", "3-x.sh",
                     "03-generate-pki.sh\x00.txt", "..\\x.sh", "", None, 3, "03-.sh;id", "03-x.sh "]:
            with self.assertRaises(ValueError, msg=repr(name)):
                S.resolve_script(name)

    def test_allowlisted_scripts_resolve_inside_scripts_dir(self):
        real = os.path.realpath(S.SCRIPTS)
        names = [s["script"] for s in S.discover_steps()]
        self.assertEqual(names[0][:2], "00")
        self.assertIn("99-teardown.sh", names)
        for n in names + ["install-all.sh", "verify-stack.sh"]:
            self.assertEqual(os.path.dirname(S.resolve_script(n)), real)

    def test_symlink_escape_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "scripts"))
            outside = os.path.join(d, "evil.sh")
            Path(outside).write_text("#!/bin/sh\n")
            os.symlink(outside, os.path.join(d, "scripts", "05-evil.sh"))
            old = S.SCRIPTS
            S.SCRIPTS = os.path.join(d, "scripts")
            try:
                with self.assertRaises(ValueError):
                    S.resolve_script("05-evil.sh")
            finally:
                S.SCRIPTS = old

    def test_header_comment(self):
        title, desc = S.header_comment(os.path.join(S.SCRIPTS, "03-generate-pki.sh"))
        self.assertTrue(title.startswith("create ALL keys"))
        self.assertIn("pki/", desc)

    def test_forbidden_paths(self):
        self.assertTrue(S.is_forbidden_path("/x/pki/secrets.env"))
        self.assertTrue(S.is_forbidden_path("/x/pki/tls/ca.key"))
        self.assertFalse(S.is_forbidden_path("/x/pki/tls/ca.crt"))
        with self.assertRaises(PermissionError):
            S.read_text("/x/anything/wildcard.key")


class RedactionTests(unittest.TestCase):
    def test_lines(self):
        r = S.Redactor
        for line in ["KEYCLOAK_ADMIN_PASSWORD=hunter2", "export CI_CLIENT_SECRET=abc", "access_token=abc", "password=x",
                     "-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN PRIVATE KEY-----", "MY_SECRET stuff"]:
            self.assertEqual(r().line(line), S.REDACTED_LINE, line)
        self.assertEqual(r().line("hello eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2ln world"), "hello [redacted-jwt] world")
        self.assertEqual(r().line("secret/sigstore-tls created"), "secret/sigstore-tls created")
        self.assertEqual(r().line("AUTH=password"), "AUTH=password")

    def test_stateful_private_key_block(self):
        r = S.Redactor()
        out = [r.line(x) for x in ["a", "-----BEGIN EC PRIVATE KEY-----", "MHcCAQEE", "zzz", "-----END EC PRIVATE KEY-----", "b"]]
        self.assertEqual(out, ["a"] + [S.REDACTED_LINE] * 4 + ["b"])

    def test_text(self):
        t = "ok\n-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\nTOKEN=abc\nfine eyJhbGciOi.eyJzdWIi.sig"
        out = S.redact_text(t)
        for leak in ["AAAA", "abc", "eyJhbGciOi"]:
            self.assertNotIn(leak, out)
        self.assertIn("ok", out)

    def test_result_detail_redacted(self):
        r = S.result("g", "c", "FAIL", "boom PASSWORD=hunter2")
        self.assertNotIn("hunter2", r["detail"])

    def test_ansi_stripped(self):
        self.assertEqual(S.clean_line("\x1b[1;34m==>\x1b[0m hello\n"), "==> hello")
        self.assertEqual(S.clean_line("10%\r50%\r100%\n"), "100%")


class HeaderTests(unittest.TestCase):
    def test_host_origin_token(self):
        self.assertTrue(S.host_ok("127.0.0.1:9443", 9443))
        self.assertTrue(S.host_ok("LOCALHOST:9443", 9443))
        for h in [None, "", "evil.example.com", "127.0.0.1", "127.0.0.1:9444", "localhost:9443.evil.com", "0.0.0.0:9443"]:
            self.assertFalse(S.host_ok(h, 9443), h)
        self.assertTrue(S.origin_ok(None, 9443))
        self.assertTrue(S.origin_ok("http://localhost:9443", 9443))
        for o in ["http://evil.com", "null", "https://127.0.0.1:9443", "http://127.0.0.1:1"]:
            self.assertFalse(S.origin_ok(o, 9443), o)

    def test_token_check(self):
        self.assertTrue(S.token_ok("abc", "abc"))
        for sup in [None, "", "abd", "abc ", "ABC", "abcd"]:
            self.assertFalse(S.token_ok(sup, "abc"), repr(sup))
        self.assertFalse(S.token_ok("", ""))
        self.assertFalse(S.token_ok("é", "abc"))

    def test_refuses_non_loopback_bind(self):
        with self.assertRaises(SystemExit):
            S.make_server(0, "t", host="0.0.0.0")
        self.assertEqual(S.main(["--host", "0.0.0.0", "--port", "9"]), 2)


class HttpTests(unittest.TestCase):
    """Starts the real server on an ephemeral loopback port."""

    @classmethod
    def setUpClass(cls):
        S.JOBS = S.JobManager.__new__(S.JobManager)
        S.JOBS.lock = threading.Lock()
        S.JOBS.cv = threading.Condition()
        S.JOBS.state_lock = threading.Lock()
        S.JOBS.job = S.JOBS.proc = None
        S.JOBS.lines = []
        S.JOBS.state = {}
        cls.token = "t" * 43
        cls.srv = S.make_server(0, cls.token)
        cls.port = cls.srv.server_address[1]
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def req(self, method, path, body=None, headers=None, host=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        h = {"Host": host or f"127.0.0.1:{self.port}"}
        h.update(headers or {})
        c.request(method, path, body=body, headers=h)
        r = c.getresponse()
        data = r.read()
        hdrs = dict(r.getheaders())
        c.close()
        return r.status, hdrs, data

    def auth(self, extra=None):
        h = {"X-Dashboard-Token": self.token}
        h.update(extra or {})
        return h

    def test_no_token_401_wrong_token_401(self):
        self.assertEqual(self.req("GET", "/api/steps")[0], 401)
        self.assertEqual(self.req("GET", "/api/steps", headers={"X-Dashboard-Token": "x"})[0], 401)
        self.assertEqual(self.req("GET", "/api/steps", headers=self.auth())[0], 200)

    def test_bad_host_403_even_with_token(self):
        self.assertEqual(self.req("GET", "/api/steps", headers=self.auth(), host="evil.example.com")[0], 403)
        self.assertEqual(self.req("GET", "/", host="evil.example.com:80")[0], 403)

    def test_foreign_origin_403(self):
        self.assertEqual(self.req("GET", "/api/steps", headers=self.auth({"Origin": "http://evil.com"}))[0], 403)

    def test_security_headers_and_no_cors(self):
        st, h, _ = self.req("GET", "/")
        self.assertEqual(st, 200)
        self.assertEqual(h["Content-Security-Policy"],
                         "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
                         "connect-src 'self'; frame-ancestors 'none'")
        self.assertEqual(h["X-Content-Type-Options"], "nosniff")
        self.assertEqual(h["Referrer-Policy"], "no-referrer")
        self.assertFalse([k for k in h if k.lower().startswith("access-control-")])

    def test_bad_script_name_400(self):
        for bad in ["../../bin/sh", "/bin/sh"]:
            st, _, _ = self.req("POST", "/api/jobs/start", json.dumps({"kind": "step", "step": bad}),
                                self.auth({"Content-Type": "application/json"}))
            self.assertEqual(st, 400, bad)
        st, _, _ = self.req("POST", "/api/jobs/start", json.dumps({"kind": "bash", "cmd": "id"}),
                            self.auth({"Content-Type": "application/json"}))
        self.assertEqual(st, 400)

    def test_teardown_needs_confirmation(self):
        st, _, b = self.req("POST", "/api/jobs/start", json.dumps({"kind": "step", "step": "99"}),
                            self.auth({"Content-Type": "application/json"}))
        self.assertEqual(st, 400)
        self.assertIn(b"teardown", b)

    def test_large_body_413_and_content_type_415(self):
        big = json.dumps({"x": "a" * (2 * 1024 * 1024)})
        st, _, _ = self.req("POST", "/api/config/preview", big, self.auth({"Content-Type": "application/json"}))
        self.assertEqual(st, 413)
        st, _, _ = self.req("POST", "/api/config/preview", "{}", self.auth({"Content-Type": "text/plain"}))
        self.assertEqual(st, 415)

    def test_config_preview_rejects_readonly_and_empty_diff(self):
        st, _, b = self.req("POST", "/api/config/preview", json.dumps({"changes": {"KEYCLOAK_HOST": "x"}}),
                            self.auth({"Content-Type": "application/json"}))
        d = json.loads(b)
        self.assertEqual(st, 200)
        self.assertIn("KEYCLOAK_HOST", d["errors"])
        self.assertEqual(d["diff"], "")

    def test_validation_group_allowlist(self):
        st, _, _ = self.req("POST", "/api/validate", json.dumps({"groups": ["nope"]}),
                            self.auth({"Content-Type": "application/json"}))
        self.assertEqual(st, 400)

    def test_log_key_allowlist(self):
        self.assertEqual(self.req("GET", "/api/logs/..%2f..%2fetc%2fpasswd", headers=self.auth())[0], 404)
        self.assertEqual(self.req("GET", "/api/logs/zz", headers=self.auth())[0], 400)


if __name__ == "__main__":
    unittest.main(verbosity=2)
