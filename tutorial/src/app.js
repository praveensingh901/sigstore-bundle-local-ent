/* Sigstore Academy — vanilla JS, no dependencies. Progress is kept per
   browser in localStorage (wrapped in try/catch; the page works without it). */
(function () {
  "use strict";
  const KEY = "sigstore-academy-v1";
  const $ = (sel, el) => (el || document).querySelector(sel);
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const TOOLS = TOOLS_DATA.categories.flatMap((c) => c.tools.map((t) => ({ ...t, group: c.name, gid: c.id })));

  let state = { quiz: {}, lab: {}, seen: {}, last: "home" };
  try { const raw = localStorage.getItem(KEY); if (raw) state = Object.assign(state, JSON.parse(raw)); } catch (e) { /* storage unavailable */ }
  function save() { try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) { /* ignore */ } }

  /* ---------- progress ---------- */
  function quizScore(id) {
    const qs = id === "trouble" ? DRILLS : QUIZ[id] || [];
    const ans = state.quiz[id] || {};
    let right = 0, answered = 0;
    qs.forEach((q, i) => { if (ans[i] !== undefined) { answered++; if (ans[i] === q.c) right++; } });
    return { right, answered, total: qs.length };
  }
  function labDone(steps) { return steps.every((s) => state.lab[s.id]); }
  function moduleDone(id) {
    const s = quizScore(id);
    if (id === "trouble") return s.answered === s.total;
    const passed = s.answered === s.total && s.right >= s.total - 1;
    if (id === "install") return passed && labDone(INSTALL_STEPS);
    if (id === "sign") return passed && labDone(SIGN_STEPS);
    return passed;
  }
  function overall() { return MODULES.filter((m) => moduleDone(m.id)).length; }

  /* ---------- shell ---------- */
  const app = $("#app");
  app.className = "app";
  app.innerHTML = `
    <aside class="rail">
      <div class="brand">${SEAL_SVG}<div><h1>Sigstore Academy</h1><p>Private, offline keyless signing</p></div></div>
      <div class="overall" aria-live="polite"><span id="ovtext"></span><div class="bar"><i id="ovbar"></i></div></div>
      <nav aria-label="Modules"><ul class="nav" id="nav"></ul></nav>
      <div class="rail-foot">
        <span>Progress is saved in this browser only.</span>
        <button class="linkbtn" id="reset" type="button">Reset all progress</button>
        <span id="resetconfirm" hidden>Click again to confirm.</span>
      </div>
    </aside>
    <main><div class="wrap" id="view"></div></main>`;

  let armed = false;
  $("#reset").addEventListener("click", () => {
    if (!armed) { armed = true; $("#resetconfirm").hidden = false; setTimeout(() => { armed = false; $("#resetconfirm").hidden = true; }, 4000); return; }
    state = { quiz: {}, lab: {}, seen: {}, last: "home" }; save(); armed = false; $("#resetconfirm").hidden = true; go("home");
  });

  function renderNav(current) {
    const items = [{ id: "home", n: "★", title: "Start here", kind: "" }].concat(MODULES);
    $("#nav").innerHTML = items.map((m) => {
      const done = m.id !== "home" && moduleDone(m.id);
      return `<li class="${done ? "done" : ""}"><button type="button" data-go="${m.id}" ${m.id === current ? 'aria-current="page"' : ""}>
        <span class="num">${done ? "✓" : esc(m.n)}</span><span>${esc(m.title)}</span><span class="kind">${esc(m.kind)}</span></button></li>`;
    }).join("");
    const d = overall();
    $("#ovtext").textContent = `${d} of ${MODULES.length} modules complete`;
    $("#ovbar").style.width = (100 * d / MODULES.length) + "%";
  }
  document.addEventListener("click", (e) => {
    const b = e.target.closest("[data-go]");
    if (b) { go(b.dataset.go); }
  });

  function go(id) {
    if (id !== "home" && !MODULES.some((m) => m.id === id)) id = "home";
    state.last = id; save();
    renderNav(id);
    const view = $("#view");
    view.innerHTML = "";
    (RENDER[id] || RENDER.home)(view);
    window.scrollTo({ top: 0 });
    const h = $("h2", view); if (h) { h.setAttribute("tabindex", "-1"); h.focus({ preventScroll: true }); }
  }

  function header(m) {
    const s = quizScore(m.id);
    const done = moduleDone(m.id);
    return `<header class="head"><div class="eyebrow">Module ${m.n} · ${esc(m.kind)}</div><h2>${esc(m.title)}</h2><p>${esc(m.summary)}</p>
      <div class="meta"><span class="chip">${m.minutes} min</span>${done ? '<span class="chip ok">Complete</span>' : s.answered ? `<span class="chip amber">${s.right}/${s.total} correct so far</span>` : ""}</div></header>`;
  }
  function pager(id) {
    const i = MODULES.findIndex((m) => m.id === id);
    const prev = i > 0 ? MODULES[i - 1] : null, next = i < MODULES.length - 1 ? MODULES[i + 1] : null;
    return `<nav class="pager" aria-label="Module navigation">
      ${prev ? `<button class="btn ghost" type="button" data-go="${prev.id}">← ${esc(prev.title)}</button>` : `<button class="btn ghost" type="button" data-go="home">← Start here</button>`}
      ${next ? `<button class="btn" type="button" data-go="${next.id}">${esc(next.title)} →</button>` : `<button class="btn" type="button" data-go="home">Back to overview</button>`}</nav>`;
  }
  function el(html) { const d = document.createElement("div"); d.innerHTML = html.trim(); return d.firstElementChild; }

  /* ---------- reusable: code block with copy ---------- */
  function codeBlock(text, label, expect) {
    const box = el(`<div class="code ${expect ? "expect" : ""}">${label ? `<div class="label">${esc(label)}</div>` : ""}<pre><code></code></pre>${expect ? "" : '<button type="button" class="copy">Copy</button>'}</div>`);
    $("code", box).textContent = text;
    const btn = $(".copy", box);
    if (btn) btn.addEventListener("click", () => {
      const done = () => { btn.textContent = "Copied"; setTimeout(() => (btn.textContent = "Copy"), 1500); };
      const fallback = () => { const r = document.createRange(); r.selectNodeContents($("code", box)); const s = getSelection(); s.removeAllRanges(); s.addRange(r); btn.textContent = "Selected — press Ctrl+C"; };
      try { navigator.clipboard.writeText(text).then(done, fallback); } catch (e) { fallback(); }
    });
    return box;
  }

  /* ---------- reusable: quiz ---------- */
  function quiz(id, questions, title, drill) {
    const wrap = el(`<section class="quiz" aria-labelledby="qz-${id}"><h3 id="qz-${id}">${esc(title)}</h3><div class="score" aria-live="polite"></div></section>`);
    const ans = (state.quiz[id] = state.quiz[id] || {});
    const scoreEl = $(".score", wrap);
    function updateScore() {
      const s = quizScore(id);
      scoreEl.textContent = s.answered ? `${s.right} of ${s.total} correct${s.answered < s.total ? ` · ${s.total - s.answered} to go` : ""}` : `${s.total} questions. Your answers are checked as you pick them.`;
      renderNav(id);
    }
    questions.forEach((q, i) => {
      const box = el(`<div class="q ${drill ? "drill" : ""}"><fieldset><legend>${drill ? "" : `${i + 1}. `}${esc(drill ? "What is the most likely cause?" : q.q)}</legend></fieldset></div>`);
      const fs = $("fieldset", box);
      if (drill) fs.insertBefore(el(`<div class="symptom">${esc(q.symptom)}</div>`), fs.firstChild.nextSibling);
      q.a.forEach((opt, j) => {
        const lab = el(`<label class="opt"><input type="radio" name="${id}-${i}" id="${id}-${i}-${j}" value="${j}"><span>${esc(opt)}</span></label>`);
        fs.appendChild(lab);
      });
      const why = el(`<div class="why" hidden></div>`);
      fs.appendChild(why);
      function show() {
        const pick = ans[i];
        fs.querySelectorAll("input").forEach((inp) => { inp.disabled = pick !== undefined; inp.checked = Number(inp.value) === pick; });
        fs.querySelectorAll(".opt").forEach((o, j) => { o.classList.toggle("correct", pick !== undefined && j === q.c); o.classList.toggle("incorrect", pick !== undefined && j === pick && j !== q.c); });
        if (pick !== undefined) {
          why.hidden = false;
          why.innerHTML = `<b>${pick === q.c ? "Correct." : "Not quite."}</b> ${esc(drill ? q.fix : q.why)}`;
        } else why.hidden = true;
      }
      fs.addEventListener("change", (e) => { if (e.target.name === `${id}-${i}`) { ans[i] = Number(e.target.value); save(); show(); updateScore(); } });
      show();
      wrap.appendChild(box);
    });
    const reset = el(`<div><button class="btn ghost" type="button">Reset these answers</button></div>`);
    $("button", reset).addEventListener("click", () => { state.quiz[id] = {}; save(); go(id); });
    wrap.appendChild(reset);
    updateScore();
    return wrap;
  }

  /* ---------- reusable: lab steps ---------- */
  function labSteps(steps) {
    const wrap = el(`<div class="lab"></div>`);
    steps.forEach((s) => {
      const card = el(`<article class="labstep ${state.lab[s.id] ? "done" : ""}"><header>${s.n ? `<span class="sn">${esc(s.n)}</span>` : ""}<h4>${esc(s.title)}</h4>${s.where ? `<span class="where ${s.where}">${s.where === "online" ? "online machine" : "offline laptop"}</span>` : ""}</header></article>`);
      card.appendChild(codeBlock(s.cmd, "Run"));
      card.appendChild(codeBlock(s.expect, "You should see", true));
      if (s.note) card.appendChild(el(`<p class="tip">${esc(s.note)}</p>`));
      const ck = el(`<label class="check"><input type="checkbox" id="lab-${s.id}"> Done: my output matched</label>`);
      const box = $("input", ck); box.checked = !!state.lab[s.id];
      box.addEventListener("change", () => { state.lab[s.id] = box.checked; card.classList.toggle("done", box.checked); save(); renderNav(state.last); });
      card.appendChild(ck);
      wrap.appendChild(card);
    });
    return wrap;
  }

  /* ================= views ================= */
  const RENDER = {};

  RENDER.home = (v) => {
    v.appendChild(el(`<header class="head"><div class="eyebrow">Self-paced course</div><h2>Learn private Sigstore by doing it</h2>
      <p>Nine modules take you from "what is keyless signing" to running your own offline stack and designing it for a whole organisation on AWS. Concepts come with interactive diagrams; labs come with the exact commands and the output you should see.</p>
      <div class="meta"><span class="chip">About 2.5 hours</span><span class="chip">35 questions + 6 drills</span><span class="chip">Labs use the sigstore-offline kit</span></div></header>`));
    const cards = el(`<div class="cards"></div>`);
    MODULES.forEach((m) => {
      const s = quizScore(m.id), done = moduleDone(m.id);
      cards.appendChild(el(`<button type="button" class="mcard" data-go="${m.id}"><span class="mn">Module ${m.n} · ${esc(m.kind)} · ${m.minutes} min</span><span class="mt">${esc(m.title)}</span><span class="ms">${esc(m.summary)}</span>
        ${done ? '<span class="mst">✓ Complete</span>' : s.answered ? `<span class="mst" style="color:var(--amber)">In progress · ${s.right}/${s.total}</span>` : ""}</button>`));
    });
    v.appendChild(cards);
    v.appendChild(el(`<section class="prose"><h3>How this course works</h3>
      <p>A module is complete when you answer all its questions with at most one wrong. The two labs also need every step ticked. Wrong answers explain why, so guessing is a fine way to learn.</p>
      <p>Labs 4 and 5 assume the <code>sigstore-offline</code> kit on a Linux or WSL2 laptop with Docker. Everything else works in the browser alone.</p></section>`));
    if (state.last && state.last !== "home") {
      const m = MODULES.find((x) => x.id === state.last);
      if (m) v.appendChild(el(`<div><button class="btn" type="button" data-go="${m.id}">Continue: ${esc(m.title)} →</button></div>`));
    }
  };

  /* ---- Module 1 ---- */
  RENDER.flow = (v) => {
    const m = MODULES.find((x) => x.id === "flow");
    v.appendChild(el(header(m)));
    const sec = el(`<section><h3>One signature, eight steps</h3><div class="steps" role="group" aria-label="Steps"></div>
      <div class="flow"><div class="panel diagram">${FLOW_SVG}</div><div class="panel stepcard" aria-live="polite"></div></div></section>`);
    v.appendChild(sec);
    const stepsBar = $(".steps", sec), card = $(".stepcard", sec), svg = $("svg", sec);
    let cur = 0;
    FLOW_STEPS.forEach((s, i) => { const b = el(`<button type="button" aria-pressed="false">${i + 1}. ${esc(s.title)}</button>`); b.addEventListener("click", () => show(i)); stepsBar.appendChild(b); });
    function show(i) {
      cur = i; const s = FLOW_STEPS[i];
      stepsBar.querySelectorAll("button").forEach((b, j) => b.setAttribute("aria-pressed", String(j === i)));
      svg.querySelectorAll(".node").forEach((n) => n.classList.toggle("on", s.nodes.includes(n.id)));
      svg.querySelectorAll(".edge").forEach((e) => e.classList.toggle("on", s.edges.includes(e.id)));
      card.innerHTML = `<h4>${i + 1}. ${esc(s.title)}</h4><div class="tool">${esc(s.tool)}</div><p>${s.body}</p><p class="detail">${s.detail}</p>
        <div class="stepnav"><button class="btn ghost" type="button" ${i === 0 ? "disabled" : ""} data-d="-1">Previous</button><button class="btn" type="button" ${i === FLOW_STEPS.length - 1 ? "disabled" : ""} data-d="1">Next step</button></div>`;
      card.querySelectorAll("[data-d]").forEach((b) => b.addEventListener("click", () => show(cur + Number(b.dataset.d))));
    }
    show(0);
    v.appendChild(el(`<section class="prose"><h3>Why "keyless" is safer</h3>
      <p>Classic signing needs a long-lived private key that someone must protect, rotate and eventually revoke. Keyless signing replaces that key with an identity you already manage: a person's corporate login or a CI pipeline's workflow identity. The key that does the signing exists for a few seconds.</p>
      <p>Trust then rests on three things you control: your CA (Fulcio), your transparency logs (CT log and Rekor) and your identity provider. A verifier checks all three using one file, <code>trusted_root.json</code>.</p></section>`));
    v.appendChild(quiz("flow", QUIZ.flow, "Check your understanding"));
    v.appendChild(el(pager("flow")));
  };

  /* ---- Module 2 ---- */
  RENDER.tools = (v) => {
    const m = MODULES.find((x) => x.id === "tools");
    v.appendChild(el(header(m)));
    const sec = el(`<section><h3>Tool explorer</h3><div class="panel" style="display:grid;gap:12px">
      <input class="search" id="toolsearch" type="search" placeholder="Search tools, e.g. crane, CoreDNS, KMS" aria-label="Search tools">
      <div class="filters" role="group" aria-label="Filter by group"></div>
      <div class="chip" id="seen" style="justify-self:start"></div>
      <div class="explorer"><div class="toollist" role="listbox" aria-label="Tools"></div><div class="tooldetail" aria-live="polite"></div></div></div></section>`);
    v.appendChild(sec);
    const filters = $(".filters", sec), list = $(".toollist", sec), detail = $(".tooldetail", sec), search = $("#toolsearch", sec);
    let group = "all", selected = TOOLS[0].name;
    const groups = [{ id: "all", name: "All" }].concat(TOOLS_DATA.categories.map((c) => ({ id: c.id, name: c.name })));
    groups.forEach((g) => { const b = el(`<button type="button" aria-pressed="${g.id === group}">${esc(g.name)}</button>`); b.addEventListener("click", () => { group = g.id; filters.querySelectorAll("button").forEach((x) => x.setAttribute("aria-pressed", String(x === b))); draw(); }); filters.appendChild(b); });
    search.addEventListener("input", draw);
    function draw() {
      const q = search.value.trim().toLowerCase();
      const items = TOOLS.filter((t) => (group === "all" || t.gid === group) && (!q || (t.name + " " + t.what + " " + t.why).toLowerCase().includes(q)));
      list.innerHTML = items.length ? "" : `<p class="tip">No tool matches "${esc(q)}".</p>`;
      items.forEach((t) => {
        const b = el(`<button type="button" role="option" aria-selected="${t.name === selected}"><span class="tname">${state.seen[t.name] ? "✓ " : ""}${esc(t.name)}</span><span class="tgroup">${esc(t.group)}</span></button>`);
        b.addEventListener("click", () => { selected = t.name; draw(); });
        list.appendChild(b);
      });
      const t = TOOLS.find((x) => x.name === selected) || items[0];
      if (!t) { detail.innerHTML = ""; return; }
      state.seen[t.name] = true; save();
      detail.innerHTML = `<div class="panel"><h4>${esc(t.name)}</h4><div class="ver">${esc(t.version)}</div><dl class="kv">
        <dt>What it is</dt><dd>${esc(t.what)}</dd><dt>Why we use it</dt><dd>${esc(t.why)}</dd>
        <dt>Without it</dt><dd class="breaks">${esc(BREAKS[t.name] || "Only used to build or test the kit. The running stack does not depend on it.")}</dd>
        <dt>Used in</dt><dd>${esc(t.where)}</dd><dt>Offline source</dt><dd>${esc(t.offline)}</dd></dl></div>`;
      if (t.cmd && t.cmd !== "—") detail.firstElementChild.appendChild(codeBlock(t.cmd, "Example"));
      const n = Object.keys(state.seen).length;
      $("#seen", sec).textContent = `You have opened ${Math.min(n, TOOLS.length)} of ${TOOLS.length} tools`;
    }
    draw();
    v.appendChild(quiz("tools", QUIZ.tools, "Check your understanding"));
    v.appendChild(el(pager("tools")));
  };

  /* ---- Module 3 ---- */
  RENDER.pki = (v) => {
    const m = MODULES.find((x) => x.id === "pki");
    v.appendChild(el(header(m)));
    v.appendChild(el(`<section class="prose"><h3>Two hierarchies, three log keys, one trust root</h3>
      <p>The TLS hierarchy protects connections. The code-signing hierarchy decides whose signatures count. The Rekor and CT keys sign the logs' evidence, and the TUF root controls how all of this reaches clients. Keeping them apart limits what any one leak can do.</p></section>`));
    const sec = el(`<section><h3>Match each key to its job</h3><p class="prose" style="color:var(--muted);margin:0 0 12px">Pick the job for each key. Correct answers turn green and reveal the key's details.</p>
      <div class="trees"></div><div style="margin-top:12px;display:flex;gap:10px;align-items:center;flex-wrap:wrap"><span class="chip" id="mscore"></span><button class="btn ghost" type="button" id="reveal">Show all answers</button></div></section>`);
    v.appendChild(sec);
    const trees = $(".trees", sec);
    const order = ["j-rekor", "j-wildcard", "j-tuf", "j-ephemeral", "j-tlsroot", "j-ct", "j-fulciointer", "j-fulcioroot"];
    const picks = state.quiz.pkimatch = state.quiz.pkimatch || {};
    const cols = [["tls", "TLS (transport)"], ["cs", "Code signing"], ["logs", "Logs and distribution"]];
    cols.forEach(([tid, name]) => {
      const col = el(`<div class="tree"><h4>${esc(name)}</h4></div>`);
      KEYS.filter((k) => k.tree === tid).forEach((k, idx) => {
        const indent = (tid === "tls" || tid === "cs") && idx > 0;
        const card = el(`<div class="keycard ${indent ? "indent" : ""}"><span class="kl">${esc(k.label)}</span>
          <select id="match-${k.id}" aria-label="Job for ${esc(k.label)}"><option value="">Choose its job…</option>${order.map((j) => `<option value="${j}">${esc(JOBS.find((x) => x.id === j).text)}</option>`).join("")}</select><span class="ki" hidden>${esc(k.info)}</span></div>`);
        const sel = $("select", card);
        function mark() {
          const p = picks[k.id]; sel.value = p || "";
          card.classList.toggle("right", p === k.job); card.classList.toggle("wrong", !!p && p !== k.job);
          $(".ki", card).hidden = p !== k.job;
        }
        sel.addEventListener("change", () => { picks[k.id] = sel.value; save(); mark(); score(); });
        mark(); col.appendChild(card);
      });
      trees.appendChild(col);
    });
    function score() { const r = KEYS.filter((k) => picks[k.id] === k.job).length; $("#mscore", sec).textContent = `${r} of ${KEYS.length} matched`; }
    $("#reveal", sec).addEventListener("click", () => { KEYS.forEach((k) => (picks[k.id] = k.job)); save(); go("pki"); });
    score();
    v.appendChild(el(`<div class="note">Fulcio's issuing certificate must carry <b>extendedKeyUsage = codeSigning</b>, and the chain file lists it first with the root last. Both were checked against Fulcio's source; getting either wrong stops Fulcio from starting.</div>`));
    v.appendChild(quiz("pki", QUIZ.pki, "Check your understanding"));
    v.appendChild(el(pager("pki")));
  };

  /* ---- Module 4 ---- */
  RENDER.install = (v) => {
    const m = MODULES.find((x) => x.id === "install");
    v.appendChild(el(header(m)));
    v.appendChild(el(`<section class="prose"><h3>Before you start</h3>
      <p>You need Linux or Windows with WSL2, Docker with 8 GB of memory and 4 CPUs, and ports 80, 443, 5000 and 6443 free on 127.0.0.1. Work from the kit folder in a bash shell. Tick each step once your output matches; the shortcut <code>scripts/install-all.sh</code> runs them all.</p></section>`));
    v.appendChild(labSteps(INSTALL_STEPS));
    v.appendChild(quiz("install", QUIZ.install, "Check your understanding"));
    v.appendChild(el(pager("install")));
  };

  /* ---- Module 5 ---- */
  RENDER.sign = (v) => {
    const m = MODULES.find((x) => x.id === "sign");
    v.appendChild(el(header(m)));
    v.appendChild(el(`<section class="prose"><h3>Set up your shell</h3></section>`));
    v.appendChild(codeBlock('cd ~/sigstore-offline\nexport PATH="$PWD/bundle/bin:$PATH"\nsource out/cosign.env', "Run once per shell"));
    v.appendChild(labSteps(SIGN_STEPS));
    const sec = el(`<section><h3>Read a Rekor entry</h3><p class="prose" style="color:var(--muted);margin:0 0 12px">An entry from the kit's integration test, shortened. Click a field to see what it proves.</p>
      <div class="anatomy"><div class="yaml" role="group" aria-label="Rekor entry fields"></div><div class="panel explain" aria-live="polite"><h4>Pick a field</h4><p>Each field on the left is part of the evidence a verifier checks.</p></div></div></section>`);
    v.appendChild(sec);
    const box = $(".yaml", sec), ex = $(".explain", sec);
    box.appendChild(el(`<button type="button" tabindex="-1">{</button>`));
    REKOR_FIELDS.forEach(([k, val, why], i) => {
      const b = el(`<button type="button" class="has">  "${esc(k)}": ${esc(val)}${i < REKOR_FIELDS.length - 1 ? "," : ""}</button>`);
      b.addEventListener("click", () => { box.querySelectorAll(".sel").forEach((x) => x.classList.remove("sel")); b.classList.add("sel"); ex.innerHTML = `<h4>${esc(k)}</h4><p>${esc(why)}</p>`; });
      box.appendChild(b);
    });
    box.appendChild(el(`<button type="button" tabindex="-1">}</button>`));
    v.appendChild(quiz("sign", QUIZ.sign, "Check your understanding"));
    v.appendChild(el(pager("sign")));
  };

  /* ---- Module 6 ---- */
  RENDER.gitsign = (v) => {
    const m = MODULES.find((x) => x.id === "gitsign");
    v.appendChild(el(header(m)));
    v.appendChild(el(`<section class="prose"><h3>Same login, same CA, for your commits</h3>
      <p>cosign signs images; <b>gitsign</b> signs git commits and tags with the same keyless flow. git calls gitsign instead of GPG, gitsign gets a 10-minute certificate from your private Fulcio after a Keycloak login, signs the commit with a throw-away key, and records it in your private Rekor. There is no key to create, store or revoke.</p>
      <p>The stack from module 4 must be running and the TUF mirror published. Work from the kit folder.</p></section>`));
    v.appendChild(labSteps(GITSIGN_STEPS));
    v.appendChild(el(`<div class="note">In the enterprise design (enterprise/docs/11-gitsign.md) engineers sign through the Keycloak <code>staff</code> realm brokered from Entra ID or AD FS, and <code>verify-commits.yml</code> runs on every pull request, required by an organisation ruleset ("Require workflows to pass before merging", pinned to a central copy), so a pull request cannot edit the check away. GitHub's own badge stays "Unverified" because it only trusts public CAs.</div>`));
    v.appendChild(quiz("gitsign", QUIZ.gitsign, "Check your understanding"));
    v.appendChild(el(pager("gitsign")));
  };

  /* ---- Module 7 ---- */
  RENDER.policy = (v) => {
    const m = MODULES.find((x) => x.id === "policy");
    v.appendChild(el(header(m)));
    const an = el(`<section><h3>Anatomy of the policy</h3><div class="anatomy"><div class="yaml" role="group" aria-label="Kyverno policy lines"></div>
      <div class="panel explain" aria-live="polite"><h4>Click a highlighted line</h4><p>Every line that changes behaviour has an explanation.</p></div></div></section>`);
    v.appendChild(an);
    const yb = $(".yaml", an), ex = $(".explain", an);
    POLICY_LINES.forEach(([line, why]) => {
      const b = el(`<button type="button" class="${why ? "has" : ""}" ${why ? "" : 'tabindex="-1"'}></button>`); b.textContent = line;
      if (why) b.addEventListener("click", () => { yb.querySelectorAll(".sel").forEach((x) => x.classList.remove("sel")); b.classList.add("sel"); ex.innerHTML = `<h4>${esc(line.trim())}</h4><p>${esc(why)}</p>`; });
      yb.appendChild(b);
    });

    const sim = el(`<section class="sim"><h3>Policy simulator</h3>
      <p class="prose" style="color:var(--muted);margin:0">Seven images with real certificate identities. Change the policy and watch admission decisions change. Switch to OpenShift's native check to see why the enterprise design keeps Kyverno on OpenShift.</p>
      <div class="panel" style="display:grid;gap:14px">
        <div style="display:flex;gap:10px;flex-wrap:wrap;align-items:center"><div class="seg" role="group" aria-label="Enforcer"><button type="button" data-mode="kyverno" aria-pressed="true">Kyverno</button><button type="button" data-mode="openshift" aria-pressed="false">OpenShift native</button></div>
          <span class="ui" style="font-size:.82rem;color:var(--muted)">Presets:</span><button class="btn ghost" type="button" data-preset="enterprise">GitHub workflows</button><button class="btn ghost" type="button" data-preset="lab">Laptop lab</button></div>
        <div class="simform" id="kyvform">
          <label class="field wide">Issuer (exact match)<input id="sim-issuer" type="text" spellcheck="false"></label>
          <label class="field wide">subjectRegExp<input id="sim-regex" type="text" spellcheck="false"></label>
          <div class="field">Validation action<div class="seg" role="group" aria-label="Validation action"><button type="button" data-act="Deny" aria-pressed="true">Deny</button><button type="button" data-act="Audit" aria-pressed="false">Audit</button></div></div>
          <div class="field" id="regexerr" style="color:var(--bad)" aria-live="polite"></div>
        </div>
        <div class="simform" id="osform" hidden>
          <label class="field wide">fulcioSubject.oidcIssuer<input id="sim-osissuer" type="text" spellcheck="false"></label>
          <label class="field wide">fulcioSubject.signedEmail<input id="sim-email" type="text" spellcheck="false"></label>
        </div>
      </div><div class="results" aria-live="polite"></div></section>`);
    v.appendChild(sim);
    let mode = "kyverno", act = "Deny";
    const iss = $("#sim-issuer", sim), rx = $("#sim-regex", sim), osi = $("#sim-osissuer", sim), em = $("#sim-email", sim);
    iss.value = SIM_PRESETS.enterprise.issuer; rx.value = SIM_PRESETS.enterprise.regex;
    osi.value = SIM_PRESETS.openshift.issuer; em.value = SIM_PRESETS.openshift.email;
    sim.querySelectorAll("[data-mode]").forEach((b) => b.addEventListener("click", () => { mode = b.dataset.mode; sim.querySelectorAll("[data-mode]").forEach((x) => x.setAttribute("aria-pressed", String(x === b))); $("#kyvform", sim).hidden = mode !== "kyverno"; $("#osform", sim).hidden = mode !== "openshift"; run(); }));
    sim.querySelectorAll("[data-act]").forEach((b) => b.addEventListener("click", () => { act = b.dataset.act; sim.querySelectorAll("[data-act]").forEach((x) => x.setAttribute("aria-pressed", String(x === b))); run(); }));
    sim.querySelectorAll("[data-preset]").forEach((b) => b.addEventListener("click", () => { const p = SIM_PRESETS[b.dataset.preset]; iss.value = p.issuer; rx.value = p.regex; if (mode !== "kyverno") sim.querySelector('[data-mode="kyverno"]').click(); else run(); }));
    [iss, rx, osi, em].forEach((i) => i.addEventListener("input", run));
    function run() {
      const out = $(".results", sim); out.innerHTML = "";
      let re = null; $("#regexerr", sim).textContent = "";
      if (mode === "kyverno") { try { re = new RegExp(rx.value); } catch (e) { $("#regexerr", sim).textContent = "That regular expression does not parse: " + e.message; return; } }
      SIM_IMAGES.forEach((img) => {
        let ok, reason;
        if (img.never) { ok = false; reason = img.never; }
        else if (mode === "kyverno") {
          if (!img.signed) { ok = false; reason = "No signatures found for this digest."; }
          else if (img.issuer !== iss.value.trim()) { ok = false; reason = `Issuer mismatch: the certificate says ${img.issuer}.`; }
          else if (!re.test(img.san)) { ok = false; reason = "The certificate identity does not match subjectRegExp."; }
          else { ok = true; reason = "Chain, SCT and Rekor proof verified; identity and issuer match."; }
        } else {
          if (!img.signed) { ok = false; reason = "No signatures found."; }
          else if (img.format === "bundle") { ok = false; reason = "CRI-O looks for a sha256-<digest>.sig tag and finds none: cosign v3 stores bundles as OCI referrers."; }
          else if (img.sanType !== "email") { ok = false; reason = "The certificate has a URI identity; the native policy can match only signedEmail."; }
          else if (img.issuer !== osi.value.trim()) { ok = false; reason = `oidcIssuer mismatch: the certificate says ${img.issuer}.`; }
          else if (img.san !== em.value.trim()) { ok = false; reason = "signedEmail does not exactly match the certificate's e-mail."; }
          else { ok = true; reason = "Legacy signature found; e-mail and issuer match exactly."; }
        }
        const verdict = ok ? "admit" : img.never ? "deny" : mode === "kyverno" && act === "Audit" ? "audit" : "deny";
        const label = img.never ? "NO IMAGE" : verdict === "admit" ? "ADMIT" : verdict === "audit" ? "AUDIT" : "DENY";
        const r = el(`<div class="result"><span class="verdict ${verdict}">${label}</span><div><div class="rl">${esc(img.label)}</div><div class="rs">${img.signed ? esc(img.san) : img.never ? "would carry " + esc(img.san) : "no certificate"}</div><div class="rr">${esc(reason)}${verdict === "audit" ? " Admitted, and reported as a policy violation." : ""}</div></div></div>`);
        out.appendChild(r);
      });
    }
    run();
    v.appendChild(el(`<div class="note">OpenShift's native <code>ClusterImagePolicy</code> was checked against the openshift/api and containers/container-libs source in October 2026: <code>fulcioSubject</code> has only <code>oidcIssuer</code> and <code>signedEmail</code>, and CRI-O fetches signatures from the <code>sha256-&lt;digest&gt;.sig</code> tag. Use it as an extra layer for e-mail-signed images that are also signed in the legacy format, not as the main control.</div>`));
    v.appendChild(quiz("policy", QUIZ.policy, "Check your understanding"));
    v.appendChild(el(pager("policy")));
  };

  /* ---- Module 8 ---- */
  RENDER.enterprise = (v) => {
    const m = MODULES.find((x) => x.id === "enterprise");
    v.appendChild(el(header(m)));
    v.appendChild(el(`<section class="prose"><h3>Same design, production custody</h3>
      <p>The laptop and production run the same services with the same trust model. Production changes three things: who holds the keys (AWS KMS, with your corporate root anchoring the chain), who signs (GitHub workflow identities and federated staff logins), and where verification happens (every cluster in every cloud, from a replicated trust root).</p></section>`));
    const zs = el(`<section><h3>Explore the platform</h3><div class="zones"></div></section>`);
    v.appendChild(zs);
    ENT_ZONES.forEach((z) => {
      const zone = el(`<div class="zone"><h4>${esc(z.title)}</h4></div>`);
      z.items.forEach(([t, d]) => {
        const b = el(`<button type="button" aria-expanded="false">${esc(t)}</button>`); const p = el(`<div class="zd" hidden>${esc(d)}</div>`);
        b.addEventListener("click", () => { const open = b.getAttribute("aria-expanded") === "true"; b.setAttribute("aria-expanded", String(!open)); p.hidden = open; });
        zone.appendChild(b); zone.appendChild(p);
      });
      $(".zones", zs).appendChild(zone);
    });
    const tr = el(`<section><h3>Trace one release to production</h3><div class="panel"><ol class="trace"></ol><div class="stepnav"><button class="btn ghost" type="button" id="trprev">Back</button><button class="btn" type="button" id="trnext">Next</button></div></div></section>`);
    v.appendChild(tr);
    const ol = $(".trace", tr); let k = 0;
    TRACE.forEach((t) => ol.appendChild(el(`<li><span>${esc(t)}</span></li>`)));
    function trace() { ol.querySelectorAll("li").forEach((li, i) => li.classList.toggle("on", i <= k)); $("#trprev", tr).disabled = k === 0; $("#trnext", tr).disabled = k === TRACE.length - 1; }
    $("#trprev", tr).addEventListener("click", () => { k = Math.max(0, k - 1); trace(); });
    $("#trnext", tr).addEventListener("click", () => { k = Math.min(TRACE.length - 1, k + 1); trace(); });
    trace();
    v.appendChild(quiz("enterprise", QUIZ.enterprise, "Check your understanding"));
    v.appendChild(el(pager("enterprise")));
  };

  /* ---- Module 9 ---- */
  RENDER.trouble = (v) => {
    const m = MODULES.find((x) => x.id === "trouble");
    v.appendChild(el(header(m)));
    v.appendChild(el(`<section class="prose"><p>Each drill is a real symptom from building and testing this kit. Pick the most likely cause to see the fix. The full list is in <code>docs/08-troubleshooting.md</code>.</p></section>`));
    v.appendChild(quiz("trouble", DRILLS, "Six drills", true));
    v.appendChild(el(pager("trouble")));
  };

  /* ---------- start ---------- */
  const fromHash = (location.hash || "").replace(/^#/, "");
  go(MODULES.some((m) => m.id === fromHash) ? fromHash : state.last || "home");
})();
