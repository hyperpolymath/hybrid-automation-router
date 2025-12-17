;; SPDX-License-Identifier: AGPL-3.0-or-later
;; SPDX-FileCopyrightText: 2025 Jonathan D.A. Jewell
;;
;; hybrid-automation-router - Guix Package Definition
;; Run: guix shell -D -f guix.scm
;;
;; Development shell: guix shell -D -f guix.scm -- mix deps.get
;; Run tests: guix shell -D -f guix.scm -- mix test

(use-modules (guix packages)
             (guix gexp)
             (guix git-download)
             (guix build-system mix)
             ((guix licenses) #:prefix license:)
             (gnu packages base)
             (gnu packages erlang)
             (gnu packages elixir)
             (gnu packages version-control)
             (gnu packages tls))

(define-public hybrid_automation_router
  (package
    (name "hybrid-automation-router")
    (version "0.1.0")
    (source (local-file "." "hybrid-automation-router-checkout"
                        #:recursive? #t
                        #:select? (git-predicate ".")))
    (build-system mix-build-system)
    (native-inputs
     (list erlang
           elixir
           git
           openssl))
    (synopsis "Infrastructure automation router - BGP for IaC")
    (description
     "HAR (Hybrid Automation Router) treats configuration management like
network packet routing. It parses configs from any IaC tool (Ansible, Salt,
Terraform, bash), extracts semantic operations, and routes/transforms them
to any target format. Think BGP for infrastructure automation.")
    (home-page "https://github.com/hyperpolymath/hybrid-automation-router")
    (license license:agpl3+)))

;; Return package for guix shell
hybrid_automation_router
