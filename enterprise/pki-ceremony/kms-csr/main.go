// Command kms-csr builds a PKCS#10 certificate signing request whose private
// key stays in a KMS (AWS KMS, Azure Key Vault, GCP KMS or HashiCorp Vault,
// through Sigstore's KMS library) or, for testing, in a PEM file.
//
// The request carries the extensions the Sigstore CA or Timestamp Authority
// certificate must have, so the issuing root can copy them and the issued
// certificate can be checked against the same profile.
//
//	kms-csr --key awskms:///arn:aws:kms:me-central-1:111111111111:alias/sigstore/fulcio-ca \
//	        --profile fulcio-ca --subject "CN=Example Bank Sigstore Code-Signing CA,O=Example Bank,C=AE" \
//	        --out fulcio-ca.csr
package main

import (
	"context"
	"crypto"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/sigstore/sigstore/pkg/cryptoutils"
	"github.com/sigstore/sigstore/pkg/signature/kms"

	// KMS providers registered with the kms package.
	_ "github.com/sigstore/sigstore/pkg/signature/kms/aws"
	_ "github.com/sigstore/sigstore/pkg/signature/kms/azure"
	_ "github.com/sigstore/sigstore/pkg/signature/kms/gcp"
	_ "github.com/sigstore/sigstore/pkg/signature/kms/hashivault"
)

var (
	oidBasicConstraints = asn1.ObjectIdentifier{2, 5, 29, 19}
	oidKeyUsage         = asn1.ObjectIdentifier{2, 5, 29, 15}
	oidExtKeyUsage      = asn1.ObjectIdentifier{2, 5, 29, 37}
	oidCodeSigning      = asn1.ObjectIdentifier{1, 3, 6, 1, 5, 5, 7, 3, 3}
	oidTimeStamping     = asn1.ObjectIdentifier{1, 3, 6, 1, 5, 5, 7, 3, 8}
)

// Profile describes the extensions requested for one certificate type.
type Profile struct {
	IsCA        bool
	PathLen     int // only for CAs
	KeyUsage    []int
	EKU         []asn1.ObjectIdentifier
	EKUCritical bool
}

// Key usage bit positions from RFC 5280 §4.2.1.3.
const (
	kuDigitalSignature = 0
	kuKeyCertSign      = 5
	kuCRLSign          = 6
)

var profiles = map[string]Profile{
	// Fulcio requires codeSigning on an issuing CA that is part of a chain.
	"fulcio-ca": {IsCA: true, PathLen: 0, KeyUsage: []int{kuKeyCertSign, kuCRLSign}, EKU: []asn1.ObjectIdentifier{oidCodeSigning}},
	// RFC 3161 §2.3: the TSA certificate has exactly one EKU, timeStamping, marked critical.
	"tsa": {IsCA: false, KeyUsage: []int{kuDigitalSignature}, EKU: []asn1.ObjectIdentifier{oidTimeStamping}, EKUCritical: true},
}

type basicConstraints struct {
	IsCA       bool `asn1:"optional"`
	MaxPathLen int  `asn1:"optional,default:-1"`
}

func keyUsageBits(bits []int) asn1.BitString {
	max := 0
	for _, b := range bits {
		if b > max {
			max = b
		}
	}
	out := make([]byte, max/8+1)
	for _, b := range bits {
		out[b/8] |= 0x80 >> (uint(b) % 8)
	}
	return asn1.BitString{Bytes: out, BitLength: max + 1}
}

func (p Profile) extensions() ([]pkix.Extension, error) {
	bc := basicConstraints{IsCA: p.IsCA, MaxPathLen: -1}
	if p.IsCA {
		bc.MaxPathLen = p.PathLen
	}
	bcDER, err := asn1.Marshal(bc)
	if err != nil {
		return nil, err
	}
	kuDER, err := asn1.Marshal(keyUsageBits(p.KeyUsage))
	if err != nil {
		return nil, err
	}
	ekuDER, err := asn1.Marshal(p.EKU)
	if err != nil {
		return nil, err
	}
	return []pkix.Extension{
		{Id: oidBasicConstraints, Critical: true, Value: bcDER},
		{Id: oidKeyUsage, Critical: true, Value: kuDER},
		{Id: oidExtKeyUsage, Critical: p.EKUCritical, Value: ekuDER},
	}, nil
}

// parseSubject parses "CN=..,O=..,OU=..,C=..,L=..,ST=.." (commas inside values are not supported).
func parseSubject(s string) (pkix.Name, error) {
	var n pkix.Name
	for _, part := range strings.Split(s, ",") {
		kv := strings.SplitN(strings.TrimSpace(part), "=", 2)
		if len(kv) != 2 || kv[1] == "" {
			return n, fmt.Errorf("bad subject component %q", part)
		}
		v := strings.TrimSpace(kv[1])
		switch strings.ToUpper(strings.TrimSpace(kv[0])) {
		case "CN":
			n.CommonName = v
		case "O":
			n.Organization = append(n.Organization, v)
		case "OU":
			n.OrganizationalUnit = append(n.OrganizationalUnit, v)
		case "C":
			n.Country = append(n.Country, v)
		case "L":
			n.Locality = append(n.Locality, v)
		case "ST":
			n.Province = append(n.Province, v)
		default:
			return n, fmt.Errorf("unsupported subject attribute %q", kv[0])
		}
	}
	if n.CommonName == "" {
		return n, errors.New("subject needs a CN")
	}
	return n, nil
}

func signerFromFile(path string) (crypto.Signer, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pass := os.Getenv("KMS_CSR_KEY_PASSWORD")
	k, err := cryptoutils.UnmarshalPEMToPrivateKey(b, cryptoutils.StaticPasswordFunc([]byte(pass)))
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	s, ok := k.(crypto.Signer)
	if !ok {
		return nil, errors.New("key cannot sign")
	}
	return s, nil
}

func signerFromKMS(ctx context.Context, ref string) (crypto.Signer, error) {
	// Hash only affects SignMessage; x509.CreateCertificateRequest passes digests
	// with explicit SignerOpts, which the KMS CryptoSigner honours.
	sv, err := kms.Get(ctx, ref, crypto.SHA384)
	if err != nil {
		return nil, fmt.Errorf("opening %s: %w", ref, err)
	}
	cs, _, err := sv.CryptoSigner(ctx, func(e error) { fmt.Fprintln(os.Stderr, "kms:", e) })
	if err != nil {
		return nil, err
	}
	return cs, nil
}

func run() error {
	keyRef := flag.String("key", "", "KMS key URI (awskms://, azurekms://, gcpkms://, hashivault://)")
	keyFile := flag.String("key-file", "", "PEM private key instead of KMS (testing only; password from KMS_CSR_KEY_PASSWORD)")
	profileName := flag.String("profile", "", "fulcio-ca or tsa")
	subject := flag.String("subject", "", `subject, e.g. "CN=Example Bank Sigstore Code-Signing CA,O=Example Bank,C=AE"`)
	out := flag.String("out", "", "output CSR file (PEM)")
	flag.Parse()

	prof, ok := profiles[*profileName]
	if !ok {
		return fmt.Errorf("--profile must be one of: fulcio-ca, tsa")
	}
	if (*keyRef == "") == (*keyFile == "") {
		return errors.New("give exactly one of --key or --key-file")
	}
	if *out == "" {
		return errors.New("--out is required")
	}
	name, err := parseSubject(*subject)
	if err != nil {
		return err
	}
	ctx := context.Background()
	var signer crypto.Signer
	if *keyRef != "" {
		signer, err = signerFromKMS(ctx, *keyRef)
	} else {
		signer, err = signerFromFile(*keyFile)
	}
	if err != nil {
		return err
	}
	exts, err := prof.extensions()
	if err != nil {
		return err
	}
	tmpl := &x509.CertificateRequest{Subject: name, ExtraExtensions: exts}
	der, err := x509.CreateCertificateRequest(nil, tmpl, signer)
	if err != nil {
		return fmt.Errorf("creating CSR: %w", err)
	}
	csr, err := x509.ParseCertificateRequest(der)
	if err != nil {
		return err
	}
	if err := csr.CheckSignature(); err != nil {
		return fmt.Errorf("CSR self-signature does not verify: %w", err)
	}
	if err := os.WriteFile(*out, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: der}), 0o644); err != nil {
		return err
	}
	pub, _ := cryptoutils.MarshalPublicKeyToPEM(signer.Public())
	fmt.Fprintf(os.Stderr, "wrote %s (profile %s, subject %q)\npublic key:\n%s", *out, *profileName, name.String(), pub)
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
