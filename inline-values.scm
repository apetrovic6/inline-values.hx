;;; inline-values.hx -- debugger values drawn inline in the buffer.
;;;
;;; While the debugger is stopped, draws the stopped frame's variable values
;;; after each parameter of the function signature the frame is in, and after
;;; each `let` statement in its body:
;;;
;;;     fn add(x: f32 = 5, y: f32 = 10.5) -> f32 {
;;;         let sum = x + y; = 15.5
;;;         let (a, b) = compute(); a = 1, b = 2
;;;
;;; Parameters are the values you were called with; the lets are the ones you
;;; are building. v1.6 scope, still deliberately narrow: function parameters
;;; (plain identifiers only) and let bindings -- single-name or destructured,
;;; one hint per statement -- the stopped frame only, the focused buffer
;;; only, Rust only. Destructured parameters, parent frames and struct
;;; expansion come after.
;;;
;;; Requires a helix carrying the DAP Steel API (dap-current-frame,
;;; dap-scopes, dap-variables) and the styled inlay hint API
;;; (add-styled-inlay-hint, clear-decorations!) -- mattwparas/helix
;;; `steel-event-system` plus the steel-inlay-hints patch stack, as vendored
;;; in the magos configuration.

(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/components.scm")
(require "helix/treesitter.scm")
(require-builtin helix/core/text as text.)

(provide inline-values-enable
         inline-values-disable
         inline-values-toggle
         inline-values-render)

;; -- settings ---------------------------------------------------------------

(define enabled #t)

;; Which scope to read, matched by name. That name is codelldb's: debugpy
;; says "Locals", delve splits "Locals"/"Arguments". Matching it here rather
;; than in the editor is the point -- the adapter-specific choice stays in
;; the plugin, dap-scopes just reports what the adapter said.
(define local-scope-name "Local")

;; Display cap for one value. A Vec prints size=3, but a struct's rendering
;; is unbounded and the space mid-signature is small.
(define max-value-length 48)

;; How much of the tail to keep when a value is cut. Cutting only the head
;; turns a deep struct into `{backend:{writer:{inner:{mutex:{futex:{v…` --
;; every character spent on nesting and none on content, and no sign of where
;; it ends. Keeping the last few characters puts the closing braces back, so
;; the elision reads as "a big struct" rather than as a truncated word.
(define value-tail-length 8)

;; How many `name = value` pairs one destructured let may show before the
;; rest collapse into `, +N more`. Several values share a single trailing
;; hint here, and each is already capped at max-value-length; a statement
;; binding more than this is better read in the variables picker than
;; inline.
(define max-let-pairs 4)

;; -- refresh gate state -----------------------------------------------------
;;
;; The hook below fires on every cursor move; values only change when the
;; debugger does. So the common path is: (dap-current-frame) -- free, it
;; reads local client state with no DAP round-trip -- compare the tuple to
;; the stored one, return. Only an actual change costs the two round-trips
;; (scopes, then the Local scope's variables: ~322 bytes, against 5 and
;; ~11.5 KB if every scope were read -- registers are 95% of a codelldb
;; stop's payload and are never drawn).
;;
;; The tuple's fourth element, the frame id, is what makes the comparison
;; sound: one source line can resolve to several breakpoint locations, so
;; continuing past a println! can re-stop on the same (path line column)
;; with different values. The id changes on every stop.

(define last-frame #f)    ;; last (path line column id) seen, or #f
(define last-doc #f)      ;; focused doc when it was seen
(define cached-vars '())  ;; Local variables fetched for last-frame
(define drawn-doc #f)     ;; doc currently holding hints we drew, or #f

;; -- small helpers (the rope/tree ones as in vista) -------------------------

(define (focused-doc) (editor->doc-id (editor-focus)))

;; tsnodes speak in byte offsets, add-styled-inlay-hint in char indexes.
;; Converting through the rope is what keeps hints anchored when a comment
;; upstream in the file has an accent in it.
(define (b->c text b) (text.rope-byte->char text b))

(define (node-text text node)
  (text.rope->string (text.rope->slice text
                                       (b->c text (tsnode-start-byte node))
                                       (b->c text (tsnode-end-byte node)))))

(define (node-start-line text node)
  (text.rope-byte->line text (tsnode-start-byte node)))

(define (node-end-line text node)
  (text.rope-byte->line text (max (tsnode-start-byte node)
                                  (- (tsnode-end-byte node) 1))))

(define (find-child node pred)
  (let loop ([cs (tsnode-children node)])
    (cond
      [(null? cs) #f]
      [(pred (car cs)) (car cs)]
      [else (loop (cdr cs))])))

;; first named child, or #f
(define (first-named-child node)
  (let ([cs (tsnode-named-children node)])
    (if (null? cs) #f (car cs))))

(define (rust-doc? doc)
  (define lang (editor-document->language doc))
  (or (equal? lang "rust") (equal? lang 'rust)))

(define (truncate-value s)
  (define len (string-length s))
  (if (<= len max-value-length)
      s
      (let ([head (- max-value-length value-tail-length)])
        (string-append (substring s 0 head)
                       "…"
                       (substring s (- len value-tail-length) len)))))

;; read from the theme on every draw so hints follow theme changes; italics
;; separate debugger output from source text
(define (value-style)
  (style-with-italics (theme-scope-ref "ui.virtual.inlay-hint")))

;; -- tree walk --------------------------------------------------------------

;; The innermost function_item whose line range contains `line` (0-based),
;; or #f. Subtrees that cannot contain the line are pruned, and in pre-order
;; a nested match is found after its parent, so keeping the last match keeps
;; the innermost -- a stop inside a closure draws the enclosing fn's
;; parameters, which are the ones in scope.
(define (find-function-at-line text node line)
  (if (or (< line (node-start-line text node))
          (> line (node-end-line text node)))
      #f
      (let loop ([cs (tsnode-children node)]
                 [best (and (equal? (tsnode-kind node) "function_item") node)])
        (if (null? cs)
            best
            (loop (cdr cs)
                  (or (find-function-at-line text (car cs) line) best))))))

;; (name . anchor-char) per simple parameter of `fn-node`.
;;
;; tree-sitter-rust: parameter = [mutable_specifier] pattern ":" type, so
;; the pattern is the first named child after an optional `mut`. v1 draws
;; Plain identifiers, plus `self`. Tuple and struct patterns are skipped --
;; their names do not match a single Local variable anyway.
;;
;; `self` is its own node kind (a `parameters` node holds `parameter`,
;; `self_parameter` or `variadic_parameter`), which is why it needs a branch
;; rather than falling out of the identifier case. It is also the one that
;; matters most: in a method, every field the code touches hangs off it, and
;; codelldb reports it as a Local named "self" like any other.
;;
;; The anchor is the node's end byte either way: after the type for a normal
;; parameter, after `self` itself for the receiver -- before the comma in
;; both cases.
(define (parameter-anchors text fn-node)
  (define params (find-child fn-node (lambda (n) (equal? (tsnode-kind n) "parameters"))))
  (if (not params)
      '()
      (let loop ([cs (tsnode-named-children params)] [acc '()])
        (if (null? cs)
            (reverse acc)
            (let* ([c (car cs)]
                   [k (tsnode-kind c)]
                   [anchor (b->c text (tsnode-end-byte c))])
              (cond
                [(equal? k "self_parameter")
                 (loop (cdr cs) (cons (cons "self" anchor) acc))]
                [(equal? k "parameter")
                 (let ([pat (find-child c (lambda (n)
                                            (not (equal? (tsnode-kind n) "mutable_specifier"))))])
                   (if (and pat (equal? (tsnode-kind pat) "identifier"))
                       (loop (cdr cs)
                             (cons (cons (node-text text pat) anchor) acc))
                       (loop (cdr cs) acc)))]
                [else (loop (cdr cs) acc)]))))))

;; the (name type value reference) tuple for `name` in the Local scope, or #f
(define (find-var name vars)
  (let loop ([vs vars])
    (cond
      [(null? vs) #f]
      [(equal? (list-ref (car vs) 0) name) (car vs)]
      [else (loop (cdr vs))])))

;; -- let bindings -----------------------------------------------------------

;; Every name a pattern binds, as nodes in source order; '() for the kinds
;; this plugin skips. Recursive over the shapes the pinned tree-sitter-rust
;; grammar (rev 261b2022) gives a let_declaration's `pattern` field:
;;
;;   identifier                      itself
;;   mut_pattern                     the wrapped pattern (named children:
;;                                   mutable_specifier, then the pattern)
;;   ref_pattern, reference_pattern  the wrapped pattern ('ref'/'&' are
;;                                   anonymous children)
;;   tuple_pattern                   each element, recursively
;;   tuple_struct_pattern            each element after the `type` child
;;   struct_pattern                  each field_pattern after the `type`
;;                                   child (no field_pattern_list node at
;;                                   this rev)
;;
;; A field_pattern comes in two shapes: shorthand `{ host }` -- a
;; shorthand_field_identifier, itself the binding -- and rename
;; `{ host: h }` -- a field_identifier followed by the real binding, which
;; recurses (so `{ host: ref h }` and `{ host: (a, b) }` work too). An
;; optional mutable_specifier (`{ mut host }`) is skipped.
;;
;; Skipped silently, per the v1.6 design: `_` (an anonymous node -- binds
;; nothing, and never reaches here as a named child), or_pattern (a name can
;; come from either side, and nothing says which bound), literal and range
;; patterns, slice_pattern (same recursion would cover it -- worth adding
;; later), remaining_field_pattern (`..` binds nothing) and captured_pattern
;; (`x @ pat`). The default is '(), so an unknown kind degrades to no hint
;; rather than to a wrong one.
(define (pattern-names pat)
  (if (not pat)
      '()
      (let ([k (tsnode-kind pat)])
        (cond
          [(equal? k "identifier") (list pat)]
          [(or (equal? k "mut_pattern")
               (equal? k "ref_pattern")
               (equal? k "reference_pattern"))
           (pattern-names (first-pattern-child pat))]
          [(equal? k "tuple_pattern")
           (children-names (tsnode-named-children pat))]
          [(equal? k "tuple_struct_pattern")
           ;; No field-name API in the treesitter cog; the grammar puts
           ;; `type` first among the named children, then the elements.
           (children-names (skip-first-named pat))]
          [(equal? k "struct_pattern")
           (fields-names (skip-first-named pat))]
          [else '()]))))

;; The first named child that is not a mutable_specifier: the wrapped pattern
;; of the mut/reference wrappers.
(define (first-pattern-child node)
  (let loop ([cs (tsnode-named-children node)])
    (cond
      [(null? cs) #f]
      [(equal? (tsnode-kind (car cs)) "mutable_specifier") (loop (cdr cs))]
      [else (car cs)])))

(define (skip-first-named node)
  (let ([cs (tsnode-named-children node)])
    (if (null? cs) '() (cdr cs))))

(define (children-names cs)
  (let loop ([cs cs] [acc '()])
    (if (null? cs)
        acc
        (loop (cdr cs) (append acc (pattern-names (car cs)))))))

;; The field_pattern / remaining_field_pattern children of a struct_pattern.
(define (fields-names cs)
  (let loop ([cs cs] [acc '()])
    (if (null? cs)
        acc
        (loop (cdr cs) (append acc (field-pattern-names (car cs)))))))

(define (field-pattern-names fp)
  (if (equal? (tsnode-kind fp) "field_pattern")
      (let loop ([cs (tsnode-named-children fp)])
        (cond
          [(null? cs) '()]
          [(equal? (tsnode-kind (car cs)) "mutable_specifier") (loop (cdr cs))]
          [(equal? (tsnode-kind (car cs)) "shorthand_field_identifier") (list (car cs))]
          ;; A field_identifier: the pattern after the ':' is the binding
          ;; when there is one. `{ host: _ }` recurses to '() -- the name is
          ;; a field_identifier, which binds nothing.
          [(null? (cdr cs)) '()]
          [else (pattern-names (car (cdr cs)))]))
      ;; remaining_field_pattern and anything else in the braces
      '()))

;; The pattern node of a let_declaration, or #f. Walks ALL children and
;; stops at the first token that can only follow the pattern -- '=', ':',
;; ';', 'else'. The stop matters: '_' is an ANONYMOUS node, so the v1.5
;; named-children walk of `let _ = y;` handed back the value `y` as the
;; pattern, which annotated the wildcard let with y's value. Returning the
;; '_' node instead lets pattern-names skip it like every other non-binding.
(define (let-pattern-node node)
  (let loop ([cs (tsnode-children node)])
    (if (null? cs)
        #f
        (let ([k (tsnode-kind (car cs))])
          (cond
            [(or (equal? k "let") (equal? k "mutable_specifier")) (loop (cdr cs))]
            [(or (equal? k "=") (equal? k ":") (equal? k ";") (equal? k "else")) #f]
            [else (car cs)])))))

;; One (names anchor-char line scope-end-line bare) entry per let_declaration
;; whose pattern binds at least one name, or '(). `names` is the source-order
;; list of bound name strings; `bare` is #t for the single-identifier shape
;; (plain or mut-wrapped), which keeps the v1.5 ` = value` rendering --
;; a destructured statement renders ` a = 1, b = 2` at the same anchor.
;; One hint per statement, not one per name: a hint after each identifier
;; INSIDE the pattern would read as a default (`let (a = 1, b = 2) = ...`),
;; and struct patterns would scatter them across the line.
;;
;; The anchor is the declaration's end byte -- after the `;` -- so the value
;; sits at the end of the statement, where VS Code and IntelliJ put it: a
;; second `= 15.5` in the middle of a line that already has an `=` and an
;; initializer reads as part of the expression.
;;
;; scope-end-line is the last line of the block this binding lives in, handed
;; down by collect-lets. It is what decides whether the binding is still alive
;; where execution stopped -- see dedupe-let-anchors.
(define (let-anchor text node scope-end)
  (define pat (let-pattern-node node))
  (define name-nodes (pattern-names pat))
  (if (null? name-nodes)
      '()
      (let ([k (tsnode-kind pat)])
        (list (list (map (lambda (n) (node-text text n)) name-nodes)
                    (b->c text (tsnode-end-byte node))
                    (node-start-line text node)
                    scope-end
                    (or (equal? k "identifier") (equal? k "mut_pattern")))))))

;; Every name-binding let in fn-node's body, in source order, as
;; (names anchor line scope-end-line bare) entries. A recursive walk, not just named
;; children: lets nest inside blocks, if/match arms and loops. Subtrees that
;; open a DIFFERENT scope than the stopped frame's are pruned -- nested
;; function_item, closure_expression, async_block, try_block: their lets are
;; not this frame's locals, and annotating them from the outer frame's
;; variables would put a confidently wrong value on the line whenever a
;; captured name collides.
;;
;; scope-end tracks the innermost enclosing `block`, which is the only node a
;; let_declaration can sit in -- `if let` and `let ... else` are different node
;; kinds and bind nothing here. The function body is itself a block, so a
;; top-level let picks its end up on the first descent.
(define (collect-lets text node acc scope-end)
  (let loop ([cs (tsnode-children node)] [acc acc])
    (if (null? cs)
        acc
        (let* ([c (car cs)]
               [k (tsnode-kind c)])
          (if (or (equal? k "function_item")
                  (equal? k "closure_expression")
                  (equal? k "async_block")
                  (equal? k "try_block"))
              (loop (cdr cs) acc)
              (let* ([inner (if (equal? k "block") (node-end-line text c) scope-end)]
                     [acc2 (if (equal? k "let_declaration")
                               (append acc (let-anchor text c scope-end))
                               acc)])
                (loop (cdr cs) (collect-lets text c acc2 inner))))))))

(define (name-in-list? xs name)
  (let loop ([xs xs])
    (cond
      [(null? xs) #f]
      [(equal? (car xs) name) #t]
      [else (loop (cdr xs))])))

;; `xs` without every name in `kill`, order preserved.
(define (names-minus xs kill)
  (let loop ([xs xs] [out '()])
    (cond
      [(null? xs) (reverse out)]
      [(name-in-list? kill (car xs)) (loop (cdr xs) out)]
      [else (loop (cdr xs) (cons (car xs) out))])))

;; Drop shadowed names from the entries kept so far; an entry that loses
;; every name is dropped whole. Rebuilds each surviving entry with its
;; remaining names, keeping anchor, line, scope-end and bare flag.
(define (strip-shadowed kept names)
  (let loop ([ks kept] [out '()])
    (if (null? ks)
        (reverse out)
        (let* ([e (car ks)]
               [remaining (names-minus (list-ref e 0) names)])
          (loop (cdr ks)
                (if (null? remaining)
                    out
                    (cons (cons remaining (cdr e)) out)))))))

;; Which bindings may be annotated, and which of a shadowed pair wins.
;;
;; A binding is a candidate only when execution could actually be sitting in
;; it: declared at or above the stop line, AND the block it lives in still
;; contains the stop line. That second test is what keeps an exited block's
;; binding bare. Without it:
;;
;;     let shadowed = "outer";
;;     { let shadowed = "inner"; }
;;     println!(...);              // <- stopped here
;;
;; the inner binding is the last one above the stop, so it got annotated --
;; with the only value lldb still reports, the OUTER one. That is a wrong
;; value on an out-of-scope line, which is worse than the blank line this is
;; supposed to degrade to. Measured before the fix: stopping inside the block
;; rendered `= "inner"` correctly, stopping after it rendered `= "outer"` on
;; the inner line.
;;
;; Among the survivors, a repeated name keeps the LAST one: entries arrive in
;; source order, and nothing in the DAP response says which block a variable
;; belongs to, so when two live bindings really do share a name the innermost
;; declaration is the better guess. Full scope-aware resolution is still the
;; follow-up; this narrows the window where a guess is needed to the case
;; where both candidates are genuinely in scope.
;;
;; With several names per statement the rule applies per NAME: a later
;; `let a = ...` strips `a` from an earlier `let (a, b)` entry, which keeps
;; `b` -- the earlier line shows only what it still owns, and a statement
;; that loses every name drops out. A statement is emitted once, never once
;; per name: two names from the same let must not produce two hints at the
;; same anchor.
;;
;; Lets below the stop line are dropped here too. lldb usually does not report
;; an un-executed binding anyway (measured: a stop ON the let line reports 3
;; locals, one step later 4), but the filter does not lean on that.
;;
;; Returns the surviving (names anchor line scope-end bare) entries.
(define (dedupe-let-anchors entries stop-line)
  (let loop ([ts entries] [kept '()])
    (if (null? ts)
        kept
        (let* ([t (car ts)]
               [declared-above (<= (list-ref t 2) stop-line)]
               [scope-alive (<= stop-line (list-ref t 3))])
          (if (not (and declared-above scope-alive))
              (loop (cdr ts) kept)
              (loop (cdr ts)
                    (append (strip-shadowed kept (list-ref t 0)) (list t))))))))

;; The let entries of fn-node's body, filtered and deduped per the rule
;; above: (names anchor line scope-end bare) per surviving statement.
(define (let-anchors text fn-node stop-line)
  (dedupe-let-anchors (collect-lets text fn-node '() (node-end-line text fn-node))
                      stop-line))

;; -- drawing ----------------------------------------------------------------

;; One hint per (name . anchor-char) whose name the Local scope reports --
;; the parameter pass, which is plain identifiers only and keeps the bare
;; ` = value` shape. Same find-var, truncation and style as the let pass;
;; making lets dimmer than signature values would be a one-token change in
;; value-style.
(define (draw-anchors anchors vars)
  (let loop ([as anchors])
    (when (not (null? as))
      (define binding (car as))
      (define var (find-var (car binding) vars))
      (when var
        (add-styled-inlay-hint (cdr binding)
                               (list (list (string-append " = " (truncate-value (list-ref var 2)))
                                           (value-style)))))
      (loop (cdr as)))))

;; ` n1 = v1, n2 = v2` for the first max-let-pairs of `resolved`, with a
;; `, +N more` tail when there are further pairs.
(define (join-let-pairs resolved)
  (define total (length resolved))
  (define shown (if (> total max-let-pairs) max-let-pairs total))
  (let loop ([ps resolved] [i 0] [out ""])
    (cond
      [(>= i shown)
       (if (> total shown)
           (string-append out ", +" (to-string (- total shown)) " more")
           out)]
      [else
       (loop (cdr ps)
             (+ i 1)
             (string-append out
                            (if (= i 0) " " ", ")
                            (car (car ps))
                            " = "
                            (cdr (car ps))))])))

;; One hint per surviving let statement. Every name is looked up with
;; find-var and the ones lldb does not (yet) report are dropped -- a binding
;; below the stop, a name that never initialised; when nothing resolves,
;; nothing is drawn rather than an empty `=`. A bare entry keeps the v1.5
;; ` = value` shape; a destructured statement joins its pairs.
(define (draw-let-entries entries vars)
  (let loop ([es entries])
    (when (not (null? es))
      (define e (car es))
      (define resolved
        (let rloop ([ns (list-ref e 0)] [acc '()])
          (if (null? ns)
              (reverse acc)
              (let ([v (find-var (car ns) vars)])
                (rloop (cdr ns)
                       (if v
                           (cons (cons (car ns) (truncate-value (list-ref v 2))) acc)
                           acc))))))
      (when (not (null? resolved))
        (add-styled-inlay-hint (list-ref e 1)
                               (list (list (if (list-ref e 4)
                                               (string-append " = " (cdr (car resolved)))
                                               (join-let-pairs resolved))
                                           (value-style)))))
      (loop (cdr es)))))

(define (draw-parameters text fn-node vars)
  (draw-anchors (parameter-anchors text fn-node) vars))

(define (draw-lets text fn-node vars stop-line)
  (draw-let-entries (let-anchors text fn-node stop-line) vars))

;; Fetch the Local scope's variables: (dap-scopes) to find its reference,
;; then (dap-variables). Two DAP round-trips, and the only place this plugin
;; costs any.
(define (fetch-local-vars)
  (define scope
    (let loop ([ss (dap-scopes)])
      (cond
        [(null? ss) #f]
        [(equal? (list-ref (car ss) 0) local-scope-name) (car ss)]
        [else (loop (cdr ss))])))
  (if scope (dap-variables (list-ref scope 1)) '()))

;; Draw (or clear) for the newly relevant state. Assumes `doc` is focused.
(define (redraw doc frame vars)
  (define doc-path (editor-document->path doc))
  (if (and doc-path
           (equal? doc-path (list-ref frame 0))
           (rust-doc? doc))
      (begin
        ;; clear-decorations! drops every plugin overlay and styled hint in
        ;; the focused view, not just ours. That is safe here, and only
        ;; here: this branch runs in the stopped frame's Rust buffer, and
        ;; nothing else in the stack draws into .rs buffers (vista renders
        ;; markdown only; scopeline draws no decorations at all). Native
        ;; LSP inlay hints live in separate storage and are untouched.
        (clear-decorations!)
        (set! drawn-doc doc)
        (define tree (document->tree doc))
        (when tree
          (define text (editor->text doc))
          ;; frame.line is 1-based (DAP); rope and tree lines are 0-based.
          (define stop-line (- (list-ref frame 1) 1))
          ;; The binding is called fnode, not fn: `fn` is Steel's lambda
          ;; shorthand, and (define fn ...) panics the compiler's analysis
          ;; pass (Option::unwrap on a desugared non-atom name) -- which
          ;; takes helix down at startup, before a frame is ever drawn.
          (define fnode (find-function-at-line text
                                               (tstree->root tree)
                                               stop-line))
          (when fnode
            (draw-parameters text fnode vars)
            (draw-lets text fnode vars stop-line))))
      ;; Not the frame's file: never draw. If this buffer still holds hints
      ;; from earlier, drop them so no stale values survive over text the
      ;; debugger has moved away from.
      (when (and drawn-doc (equal? drawn-doc doc))
        (clear-decorations!)
        (set! drawn-doc #f))))

;; -- entry point ------------------------------------------------------------

;;@doc
;; Re-render inline debugger values for the focused buffer. Normally there is
;; no need to call this: the selection-did-change hook runs it, and every
;; debugger stop, step and frame switch moves the cursor (a stop ends in
;; doc.set_selection, which dispatches the event). Useful after a theme
;; change.
(define (inline-values-render)
  (when enabled
    (define frame (dap-current-frame))
    (if (not frame)
        ;; Not stopped: forget the values, and drop our hints -- but only
        ;; when the focused buffer is the one holding them, since
        ;; clear-decorations! would otherwise wipe another plugin's work
        ;; (vista's, in a markdown buffer). Hints in a background buffer are
        ;; cleared when focus returns to it.
        (begin
          (set! last-frame #f)
          (set! last-doc #f)
          (set! cached-vars '())
          (when (and drawn-doc (equal? drawn-doc (focused-doc)))
            (clear-decorations!)
            (set! drawn-doc #f)))
        (let ([doc (focused-doc)])
          ;; The gate. Frame unchanged and same buffer focused: return
          ;; drawing nothing, and fetching nothing -- this is every plain
          ;; cursor move while stopped.
          (when (not (and (equal? frame last-frame) (equal? doc last-doc)))
            (when (not (equal? frame last-frame))
              (set! last-frame frame)
              (set! cached-vars (fetch-local-vars))
              ;; the whole tuple, id included: a re-stop on the same line
              ;; shows the same (path line column) with a new id, which is
              ;; the case the id exists to catch
              (log::info! (string-append "[inline-values] frame -> "
                                         (to-string frame) ", "
                                         (to-string (length cached-vars))
                                         " local(s)")))
            (set! last-doc doc)
            ;; Same frame, different buffer: redraws from cached-vars, still
            ;; zero DAP calls.
            (redraw doc frame cached-vars))))))

;;@doc
;; Draw debugger values inline while stopped (on by default)
(define (inline-values-enable)
  (set! enabled #t)
  (set! last-frame #f) ;; force the fetch path on the next event
  (inline-values-render))

;;@doc
;; Stop drawing and remove the hints from the focused buffer
(define (inline-values-disable)
  (set! enabled #f)
  (when (and drawn-doc (equal? drawn-doc (focused-doc)))
    (clear-decorations!)
    (set! drawn-doc #f)))

;;@doc
;; Toggle inline debugger values
(define (inline-values-toggle)
  (if enabled (inline-values-disable) (inline-values-enable)))

;; A debugger stop already fires this (jump_to_stack_frame ends in
;; doc.set_selection), as do steps and frame switches. When not debugging
;; the callback is the light path: one local-state read and a comparison.
(register-hook 'selection-did-change (lambda (view-id) (inline-values-render)))

;; Terminate is the lifecycle event that does NOT move the cursor: no
;; set_selection, so no selection-did-change. The teardown is also async --
;; dap_terminate sends the request and returns, unset_active_client runs in
;; the response callback, after which NO Steel event fires -- so post-command
;; for the terminate key itself still sees the old frame and early-returns
;; (measured). What saves it: space G is a STICKY menu, so leaving it after
;; `space G t` is a keypress, and that command's post-command runs after the
;; teardown has landed: frame #f, hints cleared. The e2e asserts exactly
;; this (terminate, Escape, gone).
(register-hook 'post-command (lambda (command-name) (inline-values-render)))

;; Not hooked: terminal-focus-gained. The debuggee's tty is an external
;; window here (the debug-start template spawns foot), so terminate closes it
;; and helix regains focus with no keypress -- which looked like a free
;; zero-input clear. Measured against that window, the FocusGained arrives
;; BEFORE the async teardown lands, so the frame still compares equal and
;; nothing clears. It earned nothing and was dropped; the sticky-menu Escape
;; above is what actually does the work.
