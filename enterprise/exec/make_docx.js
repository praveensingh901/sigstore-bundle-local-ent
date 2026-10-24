// Private Sigstore Platform — Executive Design Summary (Word)
// node make_docx.js  -> Sigstore-Platform-Executive-Summary.docx
const fs = require("fs");
const path = require("path");
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, Table, TableRow, TableCell, ImageRun,
  WidthType, ShadingType, AlignmentType, BorderStyle, PageBreak, Header, Footer, PageNumber,
  TableOfContents, TableLayoutType, LevelFormat,
} = require("docx");

const NAVY = "1E2761", TEAL = "0F7C80", LIGHT = "EAF2F4", GREY = "5B6770";
const FONT = "Calibri";
const PAGE_W = 11906, MARGIN = 1134, CW = PAGE_W - 2 * MARGIN;

const run = (text, o = {}) => new TextRun({ text, font: FONT, size: 21, ...o });
const p = (c, o = {}) => new Paragraph({ children: Array.isArray(c) ? c : [run(c)], spacing: { after: 120 }, ...o });
const h1 = (t, brk = true) => new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun(t)], pageBreakBefore: brk });
const h2 = (t) => new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun(t)], keepNext: true });
const bullet = (t, bold) => new Paragraph({ numbering: { reference: "b", level: 0 }, spacing: { after: 60 },
  children: bold ? [run(bold, { bold: true }), run(" " + t)] : [run(t)] });
const spacer = () => new Paragraph({ children: [], spacing: { after: 120 } });
const bd = { style: BorderStyle.SINGLE, size: 4, color: "C9D3D8" };
const borders = { top: bd, bottom: bd, left: bd, right: bd };
function cell(runs, w, fill) {
  return new TableCell({ width: { size: w, type: WidthType.DXA }, borders, margins: { top: 70, bottom: 70, left: 110, right: 110 },
    shading: fill ? { type: ShadingType.CLEAR, color: "auto", fill } : undefined,
    children: [new Paragraph({ children: runs, spacing: { after: 0 } })] });
}
function table(headers, rows, widths) {
  return new Table({ width: { size: widths.reduce((a, b) => a + b), type: WidthType.DXA }, columnWidths: widths, layout: TableLayoutType.FIXED,
    rows: [new TableRow({ tableHeader: true, children: headers.map((h, i) => cell([run(h, { bold: true, color: "FFFFFF", size: 19 })], widths[i], NAVY)) }),
      ...rows.map((r, ri) => new TableRow({ cantSplit: true, children: r.map((c, i) => cell([run(String(c), { size: 19, bold: i === 0 })], widths[i], ri % 2 ? LIGHT : "FFFFFF")) }))] });
}
const none = { style: BorderStyle.NONE, size: 0, color: "FFFFFF" };
function callout(title, text) {
  return new Table({ width: { size: CW, type: WidthType.DXA }, columnWidths: [CW], layout: TableLayoutType.FIXED,
    rows: [new TableRow({ children: [new TableCell({ width: { size: CW, type: WidthType.DXA }, margins: { top: 140, bottom: 140, left: 200, right: 200 },
      borders: { top: none, bottom: none, right: none, left: { style: BorderStyle.SINGLE, size: 24, color: TEAL } },
      shading: { type: ShadingType.CLEAR, color: "auto", fill: LIGHT },
      children: [new Paragraph({ children: [run(title, { bold: true, color: TEAL })], spacing: { after: 60 } }), new Paragraph({ children: [run(text)], spacing: { after: 0 } })] })] })] });
}
function img(file, wpx, hpx, maxW = 640) {
  const h = Math.round(hpx * (maxW / wpx));
  return new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 160 },
    children: [new ImageRun({ type: "png", data: fs.readFileSync(path.join(__dirname, "diagrams", file)), transformation: { width: maxW, height: h },
      altText: { title: file, description: "Architecture diagram", name: file } })] });
}

const C = [];
C.push(
  new Paragraph({ children: [], spacing: { before: 2200 } }),
  new Paragraph({ children: [run("PRIVATE SIGSTORE PLATFORM", { size: 22, bold: true, color: TEAL, characterSpacing: 40 })], spacing: { after: 200 } }),
  new Paragraph({ children: [run("Executive Design Summary", { size: 60, bold: true, color: NAVY })], spacing: { after: 200 } }),
  new Paragraph({ children: [run("Keyless signing on AWS, anchored in the corporate root CA, verified on EKS, AKS, OpenShift and on-prem clusters", { size: 28, color: GREY })], spacing: { after: 900 } }),
  table(["", ""], [
    ["Status", "Design for approval; validated statically, not yet deployed"],
    ["Date", "24 October 2026"],
    ["Audience", "Head of Cloud, CISO office, PKI, IAM, platform owners, GRC"],
    ["Detail", "enterprise/docs/00–10 and docs/adr/0001–0012 in the sigstore-platform repository"],
  ], [2200, CW - 2200]),
  new Paragraph({ children: [new PageBreak()] }),
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun("Contents")] }),
  new TableOfContents("Contents", { hyperlink: true, headingStyleRange: "1-2" }),
  p([run("If the table above is empty, right-click it and choose Update Field.", { italics: true, color: GREY, size: 18 })]),
);

C.push(h1("1. Summary"),
  callout("In one sentence", "We run our own Sigstore (the signing system used by Kubernetes, npm and PyPI) in dedicated AWS accounts, chained to the bank's offline root CA, so every container image is signed by a named pipeline or person and every cluster, on every cloud, rejects images that are not."),
  spacer(),
  h2("The problem"),
  p("Today a cluster will run an image built on a laptop, pulled from the internet or altered in a registry. For any running workload we cannot prove who built it, from which source, and that it has not changed since. NIST SSDF, SLSA and PCI DSS 4.0 all expect that evidence."),
  h2("What changes"),
  bullet("Pipelines sign with their GitHub workflow identity; engineers with their corporate login. Nobody manages signing keys.", "Keyless signing."),
  bullet("Every certificate and signature is recorded in append-only logs we operate and monitor.", "Transparency."),
  bullet("Clusters verify against trust data replicated next to them. An outage of the signing platform stops new signatures, never deployments.", "Offline verification."),
  bullet("Unsigned or wrongly signed images are denied, after an audit-only period per cluster tier.", "Enforcement everywhere."),
  h2("Target architecture"),
  img("hub.png", 2352, 1134),
  p([run("Figure 1. ", { bold: true }), run("Sign centrally in AWS; verify locally on every platform.", { color: GREY })]),
);

C.push(h1("2. Key design decisions"),
  p("Each decision has an Architecture Decision Record with context, consequences and rejected alternatives."),
  table(["ADR", "Decision", "Why"], [
    ["0001", "Private Sigstore, not public-good", "Identities stay in-house and in-Region; trust anchored in our PKI."],
    ["0002", "Rekor v1 on Trillian now, v2 later", "Mature on AWS with KMS signing today; v2 AWS flavours lack KMS signing."],
    ["0003", "CA, TSA, Rekor and TUF online keys in AWS KMS", "Non-exportable, every use in CloudTrail, multi-Region replicas for DR."],
    ["0004", "Sigstore CA directly under the offline root", "Keeps code-signing trust out of AD CS; root EKU checked at ceremony."],
    ["0005", "Keycloak brokers Entra ID and AD FS", "One issuer for people; verified e-mail claim Fulcio requires."],
    ["0006", "GitHub enterprise-unique OIDC issuer", "Only our enterprise's workflows can obtain certificates."],
    ["0007", "Kyverno on every platform", "One policy language; OpenShift native policy cannot match workflow identities."],
    ["0008", "TUF for trust distribution", "Rotate keys without touching clients; 2-of-3 offline custodians."],
    ["0009", "Self-hosted ARC runners in AWS", "Signing stays on the private network."],
    ["0010", "Build on upstream (RHTAS is the exit path)", "AWS-native keys and GitOps; no OpenShift dependency for signing."],
    ["0011", "IRSA for KMS access", "No static AWS credentials anywhere."],
    ["0012", "TLS from a name-constrained AWS Private CA", "Automated renewal; limited blast radius."],
  ], [800, 3600, CW - 4400]),
);

C.push(h1("3. Trust anchor and identity"),
  h2("PKI"),
  img("pki.png", 2352, 621),
  p([run("Figure 2. ", { bold: true }), run("The offline root signs three new certificates at one recorded ceremony; AD CS is unchanged.", { color: GREY })]),
  table(["Item", "Key custody", "Rotation", "If compromised"], [
    ["Sigstore Code-Signing CA", "AWS KMS P-384, multi-Region, sign-only roles", "5 years, overlap via TUF", "Disable key; new CA with end-time; review CT log"],
    ["Timestamp Authority", "AWS KMS P-384", "5 years", "Disable key; trusted-root update"],
    ["TLS subordinates (2 Regions)", "AWS Private CA", "5 years; leaves automatic", "Endpoint impersonation only, inside the name constraint"],
    ["TUF root / targets", "3 hardware tokens, 2-of-3", "Root yearly; targets ≤ 5 months", "Threshold limits damage"],
    ["TUF snapshot / timestamp", "AWS KMS online key", "Re-signed every 6 h", "Freeze or replay ≤ 7 days; cannot add trust"],
  ], [2300, 2600, 2000, CW - 6900]),
  spacer(),
  h2("Who can sign"),
  table(["Signer", "Identity in the certificate", "Accepted where"], [
    ["Central reusable workflow", "https://github.com/example-bank/platform-workflows/.github/workflows/sign.yml@refs/heads/main (+ calling repository)", "All namespaces (baseline); team policies narrow to repository and branch"],
    ["Third-party import workflow", "…/import-third-party.yml@refs/heads/main", "vendor/ repositories only"],
    ["Engineer via Entra ID / AD FS", "name@example-bank.com, issuer …/realms/staff", "Only namespaces that opt in (break-glass), with an alert"],
  ], [2400, 4300, CW - 6700]),
  spacer(),
  callout("Why the workflow identity is meaningful", "Every production signature names the same reviewed workflow. That is only trustworthy because changes to platform-workflows need platform review, main is protected, actions are SHA-pinned and the signing runner group accepts only that repository's workflows."),
);

C.push(h1("4. Every cluster, every cloud"),
  table(["Platform", "Enforcement", "Trust data from", "Signatures from"], [
    ["Amazon EKS", "Kyverno ImageValidatingPolicy", "tuf.sigstore.corp.example (trust ALB)", "ECR (bundles as OCI referrers)"],
    ["Azure AKS", "Kyverno", "Azure Blob replica (private endpoint)", "ACR, promoted with oras cp -r"],
    ["OpenShift (ARO / on-prem)", "Kyverno; optional native ClusterImagePolicy for e-mail identities", "Nearest replica", "ACR / Harbor / Quay"],
    ["On-prem Kubernetes", "Kyverno", "On-prem replica", "Harbor"],
  ], [2000, 2900, 2400, CW - 7300]),
  spacer(),
  callout("The one operational dependency", "Trust data carries a 7-day timestamp, re-signed every 6 hours. If a replica stops refreshing for 7 days, verification fails closed. Freshness is probed per replica and alerts at 3 days remaining."),
);

C.push(h1("5. Operations, resilience and security"),
  table(["Topic", "Design"], [
    ["Availability", "3 Availability Zones; warm standby in me-south-1; signing SLO 99.9% monthly"],
    ["Recovery", "RPO ≤ 1 minute for logs (Aurora Global Database); signing RTO 1 hour; verification has no dependency on the Region"],
    ["Network", "No internet gateway; egress via Transit Gateway to the central inspection VPC plus a DNS allowlist; org-only VPC endpoints; separate ALBs for signing and trust"],
    ["Access", "No static AWS keys (IRSA); key policies separate admin from use; ceremony signing only inside a time window"],
    ["Monitoring", "rekor-monitor consistency checks; CloudTrail alarms on any key use outside the expected role; TUF freshness per replica"],
    ["Source integrity", "Engineers sign commits and tags with gitsign (same corporate login, CA and log); a required pull-request check verifies them against our trust root"],
    ["Emergency release", "Per-namespace break-glass label settable only by the platform Argo CD; pages security on-call"],
  ], [2200, CW - 2200]),
  spacer(),
  h2("Evidence of quality so far"),
  bullet("Ceremony tooling tested against real Fulcio v1.9.0 and TSA v2.1.4 binaries, including the failure cases."),
  bullet("Terraform: validate, tflint (AWS ruleset) and checkov with 0 failures; every skip has a written reason."),
  bullet("Helm and manifests: strict kubeconform of 647 rendered objects against the real CRD schemas; Kyverno CLI behaviour tests."),
  bullet("Offline end-to-end test on a laptop stack: keyless image signing and verification, TUF bootstrap, Kyverno admission, and gitsign commit and tag signing, including negative tests."),
  bullet("TUF tooling: end-to-end test including threshold enforcement, tamper detection and cosign initialize."),
  bullet("An independent validator reviewed the design against source code and vendor documentation in five rounds (including the gitsign additions); every finding was fixed and the last round was clean."),
  callout("Not yet done", "Nothing has been applied to an AWS account. The deployment runbook starts with a sandbox run and an 11-step smoke test that must pass before any environment."),
);

C.push(h1("6. Plan and decisions needed"),
  table(["Phase", "Weeks", "Outcome"], [
    ["0  Decisions and ceremony prep", "1–2", "D1–D5 signed off; ceremony booked; GitHub issuer change planned with IAM owners"],
    ["1  Foundations", "2–3", "Accounts, network, KMS, Private CA; key ceremony; dev platform smoke test green"],
    ["2  Pilot", "3–4", "Prod platform; 3 pilot repositories signing; Kyverno Audit on one EKS and one AKS cluster"],
    ["3  Adoption", "4–8", "All deploying repositories use the reusable workflow; Audit on every cluster"],
    ["4  Enforcement", "2 per tier", "Deny by tier: dev → staging → non-critical prod → critical prod"],
    ["5  Operate", "ongoing", "Rotation calendar, quarterly DR and access reviews"],
  ], [3000, 1100, CW - 4100]),
  spacer(),
  h2("Decisions requested"),
  bullet("D1 — accept AWS KMS (FIPS 140-3 Level 3) for the CA key, or require CloudHSM."),
  bullet("D2 — enable the GitHub enterprise-unique OIDC issuer (updates existing cloud OIDC trusts)."),
  bullet("D3 — confirm me-south-1 (Bahrain) as DR Region for data residency."),
  bullet("D4 — build on upstream now, with Red Hat Trusted Artifact Signer as the supported exit path."),
  bullet("D5 — no use of public-good Rekor for internal artifacts."),
  bullet("Nominate two root CA custodians and three TUF key holders; approve the enforcement and exception policy."),
);

const doc = new Document({
  features: { updateFields: true }, creator: "Cloud Engineering Platform", title: "Private Sigstore Platform — Executive Design Summary",
  numbering: { config: [{ reference: "b", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 360, hanging: 260 } } } }] }] },
  styles: {
    default: { document: { run: { font: FONT, size: 21 } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true, run: { size: 36, bold: true, color: NAVY, font: FONT }, paragraph: { spacing: { before: 240, after: 200 }, outlineLevel: 0 } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true, run: { size: 26, bold: true, color: TEAL, font: FONT }, paragraph: { spacing: { before: 260, after: 120 }, outlineLevel: 1 } },
    ],
  },
  sections: [{
    properties: { page: { size: { width: PAGE_W, height: 16838 }, margin: { top: MARGIN, bottom: MARGIN, left: MARGIN, right: MARGIN } } },
    headers: { default: new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT, children: [run("Private Sigstore Platform · Executive Design Summary", { size: 16, color: GREY })] })] }) },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER, children: [run("Page ", { size: 16, color: GREY }), new TextRun({ children: [PageNumber.CURRENT], size: 16, color: GREY, font: FONT })] })] }) },
    children: C,
  }],
});
Packer.toBuffer(doc).then((b) => { fs.writeFileSync(path.join(__dirname, "Sigstore-Platform-Executive-Summary.docx"), b); console.log("ok"); });
