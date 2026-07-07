// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Integrity material for a tier-1 artifact.
//!
//! The defining pain of tier 1 (ADR-0003) is that most manager-less installs
//! ship *no* integrity story at all — hence [`Integrity::None`] is a
//! first-class, honestly-recorded state rather than an omission. Where
//! material does exist (a release `checksums.txt`, a minisign/sigstore
//! signature) it is captured so tier 2 can make verification mandatory.
//!
//! Only SHA-256 and stronger are modelled: MD5 and SHA-1 are excluded by the
//! estate security policy, so there is deliberately no variant for them.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Integrity material recorded against an artifact.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Integrity {
    /// No integrity material exists. The acute tier-1 case: recorded honestly
    /// so audits can see which artefacts are unverifiable.
    None,
    /// A SHA-256 checksum (lowercase hex).
    Sha256 {
        /// 64-char lowercase hex digest.
        hex: String,
    },
    /// A detached signature (minisign, sigstore, GPG …). The bytes are not
    /// verified here — the record carries scheme + locator so a tier-2
    /// provider can verify against the acquired asset.
    Signature {
        /// Signature scheme, e.g. `minisign`, `sigstore`, `gpg`.
        scheme: String,
        /// Where the signature material lives (URL or asset name).
        locator: String,
    },
}

impl Integrity {
    /// Compute the lowercase-hex SHA-256 of `bytes`.
    pub fn sha256_of(bytes: &[u8]) -> String {
        let mut h = Sha256::new();
        h.update(bytes);
        let digest = h.finalize();
        let mut s = String::with_capacity(64);
        for b in digest {
            s.push_str(&format!("{b:02x}"));
        }
        s
    }

    /// Whether `bytes` satisfy this integrity record.
    ///
    /// [`Integrity::None`] verifies vacuously (there is nothing to check — the
    /// artefact is unverifiable by construction). [`Integrity::Signature`]
    /// also returns `true`: signature verification is deferred to a provider
    /// with the verification keys (tier 2), and this crate only records the
    /// material.
    pub fn verify(&self, bytes: &[u8]) -> bool {
        match self {
            Self::None => true,
            Self::Sha256 { hex } => Self::sha256_of(bytes).eq_ignore_ascii_case(hex),
            Self::Signature { .. } => true,
        }
    }

    /// Stable kebab-case tag for the meta-model `integrity.kind` attribute.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Sha256 { .. } => "sha256",
            Self::Signature { .. } => "signature",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_matches_known_vector() {
        // SHA-256 of the empty string.
        assert_eq!(
            Integrity::sha256_of(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn verify_checksum() {
        let good = Integrity::Sha256 {
            hex: Integrity::sha256_of(b"payload"),
        };
        assert!(good.verify(b"payload"));
        assert!(!good.verify(b"tampered"));
    }

    #[test]
    fn none_and_signature_verify_vacuously() {
        assert!(Integrity::None.verify(b"anything"));
        assert!(Integrity::Signature {
            scheme: "minisign".into(),
            locator: "sig".into()
        }
        .verify(b"anything"));
    }
}
