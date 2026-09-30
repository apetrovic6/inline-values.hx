(define package-name 'inline-values.hx)
(define version "0.0.1")

;; No dependencies: this plugin only talks to the editor (DAP state in,
;; styled inlay hints out). If one is ever added, keep this list in step
;; with `pluginDependencies` in package.nix, as connect.hx's cog.scm says.
(define dependencies '())
