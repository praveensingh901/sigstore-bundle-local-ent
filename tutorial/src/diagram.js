/* Signing-flow diagram. Node and edge ids are referenced by FLOW_STEPS. */
const FLOW_SVG = `
<svg viewBox="0 0 640 380" role="img" aria-labelledby="flowtitle">
  <title id="flowtitle">Components involved in one keyless signature</title>
  <rect class="zone" x="345" y="10" width="288" height="226" rx="10"/>
  <text class="zone-label" x="355" y="226">PRIVATE SIGSTORE SERVICES</text>
  <path class="edge" id="e-login" d="M130 182 C 168 182, 165 53, 200 53"/>
  <path class="edge" id="e-cert" d="M130 190 C 250 190, 300 74, 370 68"/>
  <path class="edge" id="e-jwks" d="M370 42 L320 42"/>
  <path class="edge" id="e-ct" d="M480 53 L515 53"/>
  <path class="edge" id="e-ct-tr" d="M570 76 L570 170"/>
  <path class="edge" id="e-rekor" d="M130 200 L370 196"/>
  <path class="edge" id="e-rk-tr" d="M480 193 L515 193"/>
  <path class="edge" id="e-store" d="M75 222 C 75 300, 130 323, 200 323"/>
  <path class="edge" id="e-kyv-reg" d="M370 323 L320 323"/>
  <path class="edge" id="e-kyv-tuf" d="M480 323 L515 323"/>
  <g class="node" id="dev"><rect x="20" y="166" width="110" height="56" rx="8"/><text x="75" y="190" text-anchor="middle">Developer / CI</text><text x="75" y="208" text-anchor="middle">cosign</text></g>
  <g class="node" id="keycloak"><rect x="200" y="30" width="120" height="46" rx="8"/><text x="260" y="58" text-anchor="middle">Keycloak (OIDC)</text></g>
  <g class="node" id="fulcio"><rect x="370" y="30" width="110" height="46" rx="8"/><text x="425" y="58" text-anchor="middle">Fulcio CA</text></g>
  <g class="node" id="ct"><rect x="515" y="30" width="110" height="46" rx="8"/><text x="570" y="58" text-anchor="middle">CT log</text></g>
  <g class="node" id="rekor"><rect x="370" y="170" width="110" height="46" rx="8"/><text x="425" y="198" text-anchor="middle">Rekor</text></g>
  <g class="node" id="trillian"><rect x="515" y="170" width="110" height="46" rx="8"/><text x="570" y="190" text-anchor="middle">Trillian</text><text x="570" y="206" text-anchor="middle">+ MySQL</text></g>
  <g class="node" id="registry"><rect x="200" y="300" width="120" height="46" rx="8"/><text x="260" y="328" text-anchor="middle">OCI registry</text></g>
  <g class="node" id="kyverno"><rect x="370" y="300" width="110" height="46" rx="8"/><text x="425" y="328" text-anchor="middle">Kyverno</text></g>
  <g class="node" id="tuf"><rect x="515" y="300" width="110" height="46" rx="8"/><text x="570" y="328" text-anchor="middle">TUF mirror</text></g>
</svg>`;

const SEAL_SVG = `<svg class="seal" viewBox="0 0 40 40" aria-hidden="true">
  <circle cx="20" cy="20" r="18" fill="var(--accent)"/>
  <circle cx="20" cy="20" r="13" fill="none" stroke="var(--surface)" stroke-width="1.5" stroke-dasharray="2 2.6"/>
  <path d="M13.5 20.5 L18 25 L27 15.5" fill="none" stroke="var(--surface)" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>
</svg>`;
