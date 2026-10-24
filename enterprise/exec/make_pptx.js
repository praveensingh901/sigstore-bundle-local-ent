// Private Sigstore Platform — executive deck (PowerPoint)
// node make_pptx.js -> Sigstore-Platform-Executive-Overview.pptx
const path = require("path");
const pptxgen = require("pptxgenjs");
const { applyTheme } = require(process.env.PPTX_SKILL + "/scripts/apply_theme.js");

const THEME = {
  name: "Sigstore Navy Teal", headFontFace: "Cambria", bodyFontFace: "Calibri",
  colors: { dk1: "1B2333", lt1: "FFFFFF", dk2: "1E2761", lt2: "EAF2F4", accent1: "0F7C80", accent2: "E0A526",
    accent3: "5B6770", accent4: "3D8B6E", accent5: "B4483A", accent6: "8EA4B8", hlink: "0F7C80", folHlink: "5B6770" },
};
const HEX = THEME.colors;
const pres = new pptxgen();
pres.layout = "LAYOUT_WIDE"; // 13.33 x 7.5
pres.theme = { headFontFace: THEME.headFontFace, bodyFontFace: THEME.bodyFontFace };
pres.title = "Private Sigstore Platform — Executive Overview";
pres.author = "Cloud Engineering Platform";
const C = pres.SchemeColor;
const W = 13.33;

pres.defineSlideMaster({
  title: "TITLE_DARK", background: { color: C.text2 },
  objects: [
    { placeholder: { options: { name: "title", type: "title", x: 0.8, y: 1.6, w: 11.5, h: 1.6, fontSize: 44, bold: true, color: C.background1, fontFace: THEME.headFontFace, valign: "bottom", align: "left" }, text: "" } },
    { placeholder: { options: { name: "body", type: "body", x: 0.8, y: 3.4, w: 11.0, h: 3.4, fontSize: 20, color: C.background2, valign: "top" }, text: "" } },
  ],
});
pres.defineSlideMaster({
  title: "CONTENT", background: { color: C.background1 },
  margin: [0.6, 0.6, 0.6, 0.6],
  objects: [
    { placeholder: { options: { name: "title", type: "title", x: 0.6, y: 0.35, w: 12.1, h: 0.9, fontSize: 32, bold: true, color: C.text2, fontFace: THEME.headFontFace, valign: "middle", align: "left" }, text: "" } },
    { text: { text: "Private Sigstore Platform · Executive overview", options: { x: 0.6, y: 7.0, w: 8, h: 0.3, fontSize: 10, color: C.accent3 } } },
  ],
  slideNumber: { x: 12.2, y: 7.0, w: 0.6, h: 0.3, fontSize: 10, color: C.accent3, align: "right" },
});

const card = (s, x, y, w, h, head, body, opts = {}) => {
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w, h, rectRadius: 0.08, fill: { color: opts.fill || C.background2 }, line: { color: opts.fill || C.background2 }, objectName: "card " + head });
  s.addText(head, { x: x + 0.2, y: y + 0.15, w: w - 0.4, h: 0.45, fontSize: 17, bold: true, color: opts.headColor || C.accent1, margin: 0, isTextBox: true, valign: "top" });
  s.addText(body, { x: x + 0.2, y: y + 0.65, w: w - 0.4, h: h - 0.8, fontSize: 14, color: opts.color || C.text1, margin: 0, isTextBox: true, valign: "top" });
};
const circle = (s, x, y, label) => {
  s.addShape(pres.shapes.OVAL, { x, y, w: 0.55, h: 0.55, fill: { color: C.accent1 }, line: { color: C.accent1 }, objectName: "marker " + label });
  s.addText(label, { x, y, w: 0.55, h: 0.55, fontSize: 16, bold: true, color: C.background1, align: "center", valign: "middle", margin: 0, isTextBox: true });
};

// 1. Title
pres.addSection({ title: "Overview" });
let s = pres.addSlide({ masterName: "TITLE_DARK", sectionTitle: "Overview" });
s.addText("Every image signed. Every cluster checks.", { placeholder: "title" });
s.addText("A private Sigstore on AWS, anchored in the corporate root CA, enforced on EKS, AKS, OpenShift and on-prem", { placeholder: "body" });
s.addNotes("Purpose: approve the design and the five decisions D1–D5 so the key ceremony can be booked.");

// 2. Problem / outcome
s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Overview" });
s.addText("Today we cannot prove where a running image came from", { placeholder: "title" });
card(s, 0.6, 1.5, 5.9, 3.4, "Today", "Any cluster runs any image it can pull: built on a laptop, copied from the internet, or changed in a registry.\n\nFor an incident or an audit we cannot show who built an image, from which source, or that it is unchanged.");
card(s, 6.85, 1.5, 5.9, 3.4, "After this programme", "Pipelines sign images with their GitHub workflow identity; engineers sign images and commits (gitsign) with their corporate login. No signing keys to manage.\n\nEvery signature is in logs we operate. Clusters verify against trust data next to them and deny unsigned images.", { fill: C.accent1, headColor: C.background1, color: C.background1 });
s.addText("Evidence regulators and auditors ask for: NIST SSDF, SLSA, PCI DSS 4.0 software integrity.", { x: 0.6, y: 5.3, w: 12.15, h: 0.6, fontSize: 16, italic: true, color: C.accent3, isTextBox: true, margin: 0 });
s.addNotes("Regulatory drivers: NIST SSDF, SLSA, PCI DSS 4.0 software integrity.");

// 3. Architecture
pres.addSection({ title: "Design" });
s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Design" });
s.addText("Sign centrally in AWS, verify locally everywhere", { placeholder: "title" });
s.addImage({ path: path.join(__dirname, "diagrams", "hub.png"), x: 1.25, y: 1.35, w: 10.8, h: 10.8 * 1134 / 2352, altText: "Architecture: GitHub workflows sign through runners in AWS; trust replicated to EKS, AKS, OpenShift and on-prem" });
s.addNotes("Signing needs the AWS platform; verification never does. A Region outage stops new signatures only.");

// 4. Trust anchor
s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Design" });
s.addText("Trust is anchored in our own root CA", { placeholder: "title" });
s.addImage({ path: path.join(__dirname, "diagrams", "pki.png"), x: 0.6, y: 1.35, w: 8.2, h: 8.2 * 621 / 2352, altText: "PKI hierarchy under the offline corporate root" });
card(s, 9.1, 1.35, 3.65, 4.0, "Key facts", "CA, TSA and log keys live in AWS KMS: non-exportable, every use logged.\n\nAD CS is unchanged.\n\nTrust updates reach every cluster through TUF, signed 2-of-3 by custodians.");
s.addText("One recorded ceremony: the offline root signs the Sigstore CA, the TSA certificate and two TLS subordinates.", { x: 0.6, y: 4.0, w: 8.2, h: 1.0, fontSize: 16, color: C.text1, isTextBox: true, margin: 0 });
s.addText("Ceremony scripts were tested against real Fulcio and TSA binaries, including the certificates they must reject.", { x: 0.6, y: 5.1, w: 8.2, h: 1.0, fontSize: 14, italic: true, color: C.accent3, isTextBox: true, margin: 0 });

// 5. Every platform
s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Design" });
s.addText("One policy pack enforces on every platform", { placeholder: "title" });
const plats = [["EKS", "ECR · TUF mirror in AWS"], ["AKS", "ACR · Azure Blob replica"], ["OpenShift", "ACR / Quay · nearest replica"], ["On-prem", "Harbor · on-prem replica"]];
plats.forEach(([n, d], i) => card(s, 0.6 + i * 3.1, 1.5, 2.85, 1.6, n, "Kyverno 1.19\n" + d));
card(s, 0.6, 3.5, 12.15, 2.0, "How it works", "Kyverno checks each Pod's images against the signer identity and the bank's TUF root, offline, at admission. Rollout goes Audit first, then Deny by tier. A per-namespace break-glass label can be set only by the platform Argo CD and pages security on-call. OpenShift's native image policy cannot match pipeline identities, so it is only an optional second layer.");

// 6. Decisions (table)
s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Design" });
s.addText("Twelve recorded decisions", { placeholder: "title" });
const rows = [["ADR", "Decision"],
  ["0001", "Private Sigstore, not public-good"], ["0002", "Rekor v1 now, v2 when AWS supports KMS signing"], ["0003", "Keys in AWS KMS (multi-Region)"],
  ["0004", "Sigstore CA directly under the offline root"], ["0005", "Keycloak brokers Entra ID and AD FS"], ["0006", "GitHub enterprise-unique OIDC issuer"],
  ["0007", "Kyverno on every platform"], ["0008", "TUF trust distribution, 2-of-3 custodians"], ["0009", "Self-hosted runners in AWS"],
  ["0010", "Build on upstream; RHTAS as exit path"], ["0011", "IRSA, no static AWS keys"], ["0012", "TLS from a name-constrained Private CA"]];
const half = (r) => r.map((row, i) => row.map((t) => ({ text: t, options: i === 0 ? { bold: true, color: HEX.lt1, fill: { color: HEX.dk2 } } : { color: HEX.dk1, fill: { color: i % 2 ? HEX.lt2 : HEX.lt1 } } })));
s.addTable(half([rows[0], ...rows.slice(1, 7)]), { x: 0.6, y: 1.45, w: 5.95, colW: [0.9, 5.05], fontSize: 14, border: { type: "solid", pt: 0.5, color: "C9D3D8" }, rowH: 0.62 });
s.addTable(half([rows[0], ...rows.slice(7)]), { x: 6.8, y: 1.45, w: 5.95, colW: [0.9, 5.05], fontSize: 14, border: { type: "solid", pt: 0.5, color: "C9D3D8" }, rowH: 0.62 });

// 7. Resilience & quality
pres.addSection({ title: "Readiness" });
s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Readiness" });
s.addText("Built to fail safe, checked before it ships", { placeholder: "title" });
const stats = [["≤ 1 min", "log data loss on Region failure"], ["1 h", "to restore signing in me-south-1"], ["7 days", "clusters keep verifying if publishing stops"], ["0", "static AWS keys"]];
stats.forEach(([v, l], i) => {
  s.addText(v, { x: 0.6 + i * 3.1, y: 1.5, w: 2.85, h: 1.0, fontSize: 40, bold: true, color: C.accent1, fontFace: THEME.headFontFace, isTextBox: true, margin: 0 });
  s.addText(l, { x: 0.6 + i * 3.1, y: 2.5, w: 2.85, h: 0.8, fontSize: 14, color: C.accent3, isTextBox: true, margin: 0, valign: "top" });
});
card(s, 0.6, 3.7, 12.15, 2.3, "Validation so far (static; nothing deployed yet)", "Terraform validate, tflint and checkov with 0 failures · 647 Kubernetes objects valid against real CRD schemas · Kyverno policy tests · TUF tooling end to end with tamper detection · offline laptop stack end to end, including gitsign · an independent reviewer checked the design against source code and vendor docs, and every finding was fixed.\n\nFirst deployment goes to a sandbox account set and must pass an 11-step smoke test.");

// 8. Plan
s = pres.addSlide({ masterName: "CONTENT", sectionTitle: "Readiness" });
s.addText("Eight weeks to adoption, then enforcement by tier", { placeholder: "title" });
const ph = [["0", "Decisions", "Weeks 1–2"], ["1", "Foundations + ceremony", "Weeks 2–3"], ["2", "Pilot: 3 repos, 2 clusters", "Weeks 3–4"], ["3", "Adoption, Audit everywhere", "Weeks 4–8"], ["4", "Deny by tier", "2 weeks per tier"]];
ph.forEach(([n, t, w], i) => {
  const x = 0.6 + i * 2.45;
  circle(s, x, 1.7, n);
  s.addText(t, { x, y: 2.45, w: 2.2, h: 0.9, fontSize: 15, bold: true, color: C.text2, isTextBox: true, margin: 0, valign: "top" });
  s.addText(w, { x, y: 3.3, w: 2.2, h: 0.4, fontSize: 13, color: C.accent3, isTextBox: true, margin: 0 });
  if (i < ph.length - 1) s.addShape(pres.shapes.LINE, { x: x + 0.65, y: 1.97, w: 1.7, h: 0, line: { color: HEX.accent6, width: 1.5 }, objectName: "connector " + i });
});
card(s, 0.6, 4.3, 12.15, 1.5, "Exit criteria", "Pilot: 100% of pilot images signed for two weeks and no false positives. Each enforcement tier: two weeks without unplanned denials and a tested break-glass.");

// 9. Asks
s = pres.addSlide({ masterName: "TITLE_DARK", sectionTitle: "Readiness" });
s.addText("Decisions needed to book the ceremony", { placeholder: "title" });
s.addText([
  { text: "D1  AWS KMS (FIPS 140-3 L3) for the CA key, or CloudHSM", options: { bullet: true, breakLine: true } },
  { text: "D2  Enable the GitHub enterprise-unique OIDC issuer", options: { bullet: true, breakLine: true } },
  { text: "D3  me-south-1 (Bahrain) as the DR Region", options: { bullet: true, breakLine: true } },
  { text: "D4  Build on upstream; RHTAS as the exit path", options: { bullet: true, breakLine: true } },
  { text: "D5  No public-good Rekor for internal artifacts", options: { bullet: true, breakLine: true } },
  { text: "Name 2 root custodians and 3 TUF key holders", options: { bullet: true } },
], { placeholder: "body", fontSize: 18, paraSpaceAfter: 6 });

(async () => {
  const out = path.join(__dirname, "Sigstore-Platform-Executive-Overview.pptx");
  await pres.writeFile({ fileName: out });
  await applyTheme(out, THEME);
  console.log("ok");
})();
