;; SPDX-License-Identifier: PMPL-1.0-or-later
;; ECOSYSTEM.scm - Ecosystem positioning

(ecosystem
  ((version . "1.0.0")
   (name . "hybrid-automation-router")
   (type . "application")
   (purpose . "Hyperpolymath project")
   (position-in-ecosystem . "supporting")
   (related-projects
     ((palimpsest-license . "license-framework")))
   (what-this-is . ("Hyperpolymath project"))
   (what-this-is-not . ()))
  (opsm-integration
    (relationship "core")
    (description "automation routing for OPSM operations.")
    (direction "opsm -> hybrid-automation-router"))
)
