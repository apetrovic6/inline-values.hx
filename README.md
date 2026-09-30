# inline-values.hx

Debugger values drawn inline in the [Helix](https://helix-editor.com) editor
while stopped — the `fn add(x: f32 = 5, y: f32 = 10.5)` / `let sum = x + y; = 15.5`
rendering popularized by VS Code / IntelliJ, for a codelldb session in Helix.

> **Status: v1.5, still deliberately narrow.** Function parameters and
> single-name `let` bindings, the stopped frame only, the focused buffer
> only, Rust only. Destructuring patterns, parent frames and struct
> expansion come after (see *Out of scope*).

Requires Helix with the experimental Steel plugin system
([mattwparas/helix, `steel-event-system`](https://github.com/mattwparas/helix/tree/steel-event-system))
**plus two local patch sets on top** — this is not loadable on upstream Helix:

- the styled inlay hint / decoration API (`add-styled-inlay-hint`,
  `clear-decorations!`), and
- the DAP Steel API (`dap-current-frame`, `dap-scopes`, `dap-variables`).

Both are vendored as patches 0001–0007 in the magos configuration
(`modules/features/helix/_config/steel-inlay-hints/`). `dap-current-frame`
must return the four-element `(path line column id)` tuple — the frame id is
what makes the refresh gate below sound.

## How it works

**Trigger.** Two hooks:

```scheme
(register-hook 'selection-did-change (lambda (view-id) (inline-values-render)))
(register-hook 'post-command (lambda (command-name) (inline-values-render)))
```

A debugger stop calls `jump_to_stack_frame`, which ends in `doc.set_selection`,
which dispatches `SelectionDidChange`. Stops, steps and frame switches all move
the cursor, so all three fire the first hook. No DAP event hook is needed (and
none exists). **Terminate is the exception**: it moves nothing, so without the
second hook the stale-value clear never runs — the e2e caught hints surviving
`space G t` until an unrelated cursor move. `post-command` fires for the
terminate keypress itself, and for the next keystroke after a debuggee exits
on its own. Both hooks run the same light path, so the gate below is what
every firing costs.

**Refresh gate.** The hook fires on every cursor move; values only change when
the debugger does:

1. `(dap-current-frame)` — reads local client state, no DAP round-trip, free
   per keystroke. `#f` (not stopped) → drop our hints, return.
2. Tuple equal to the stored one and the same buffer focused → return drawing
   nothing. This is the common path.
3. Changed → `(dap-scopes)`, find `"Local"` by name (codelldb's name; debugpy
   says `Locals`), `(dap-variables <ref>)`, redraw, store. Only this step costs
   round-trips: 2 and ~322 bytes, against 5 and ~11.5 KB for every scope —
   registers are ~95% of a codelldb stop's payload and are never drawn.

The tuple's `id` element changes on every stop, even a re-stop on the same
line (one source line can resolve to several breakpoint locations), so
comparing whole tuples cannot keep stale values on screen.

**Placement.** `(document->tree doc)` → walk to the innermost `function_item`
whose line range contains the frame's line (DAP lines are 1-based, rope lines
0-based) → for each `parameter` child of its `parameters` whose pattern is a
plain `identifier` (an optional `mut` is skipped), draw
`(add-styled-inlay-hint <param end char> " = <value>")` — anchored at the
parameter's end byte converted through `text.rope-byte->char`, which is what
keeps hints correct when a comment upstream has an accent in it. Values are
truncated to 40 characters.

**Let placement (v1.5).** The same `function_item` is then walked recursively
for `let_declaration` nodes — through blocks, `if`/`match` arms and loops —
pruning subtrees that open a *different* scope than the stopped frame's
(nested `function_item`, `closure_expression`, `async_block`, `try_block`):
their `let`s are not this frame's locals, and annotating them from the outer
frame's variables could put a confidently wrong value on the line when a
captured name collides. Only patterns binding a single plain name are drawn
(`identifier`, with `mut` handled in both shapes tree-sitter-rust produces —
the `mutable_specifier` sibling slot, which is what `let mut` actually uses
at the pinned grammar rev since `mut_pattern` is `prec(-1)`, and the
`mut_pattern` wrapper); destructuring is skipped silently. The hint anchors
at the declaration's end byte — after the `;` — because a second `= 15.5`
mid-line, in a statement that already has an `=` and an initializer, reads as
part of the expression. Un-executed `let`s below the stop line need no
filtering in the common case: lldb reports a local only once it is in scope,
so `find-var` simply misses.

**Shadowing is bounded, not solved.** lldb can report two locals with the
same name and nothing in the DAP response says which block each belongs to,
so when a name is bound by several `let`s, only the **last binding at or
above the stop line** is annotated and the others stay bare — the binding
most likely in scope, and a blank line rather than a confidently wrong
number for the rest. Scope-aware resolution from tree-sitter replaces this
rule; until then it is the deliberate v1.5 behavior (see the comment on
`dedupe-let-anchors`).

**Clearing.** `clear-decorations!` drops every plugin overlay and styled hint
in the focused view (native LSP inlay hints are separate storage and survive).
It is only ever called in the stopped frame's Rust buffer — the one place
where nothing else in the stack draws (vista renders markdown only,
scopeline draws no decorations) — or in a buffer this plugin itself drew into.

**Decorations do not survive buffer switches.** With `lsp.display-inlay-hints`
off (helix's default), `Editor::_refresh` resets the document's whole
inlay-hint storage — styled plugin hints included — and an `:open` round-trip
in this helix build also resets the view's selection to 1:1. Both facts are
plain editor behavior, not this plugin's. The plugin self-heals: the reset
selection fires `selection-did-change`, and the redraw path runs from
cached variables, so restoring hints after a switch costs zero DAP calls.

**Known adapter hazard (not a plugin bug).** On frames that land
mid-expression inside an inlined callee — a step-over out of a small
`const fn`, a breakpoint resolving inside inlined generic code — codelldb
1.12.2 can die processing *any* client's `variables` request; helix's own
`space G v` picker kills it identically with this plugin disabled. The 0007
guards turn the dead request into `'()`: the plugin draws nothing for that
frame and helix stays up. Established by `/tmp/hx-dap-test/iv-exp-c.sh`
against the counter tui app.

## Commands

| command | what |
|---|---|
| `:inline-values-render` | redraw now (e.g. after a theme change) |
| `:inline-values-enable` | turn on (on by default) |
| `:inline-values-disable` | turn off and remove hints from the focused buffer |
| `:inline-values-toggle` | toggle |

## Out of scope for v1

In rough order of what to add next:

- **destructuring patterns** — `tuple_pattern`, `struct_pattern`,
  `tuple_struct_pattern`, `ref_pattern`, `or_pattern`: each binds several
  names and needs one anchor per name, plus a choice of which end of the
  pattern to hang each on. Skipped silently today.
- **parent frames** — when switching frames with `space G s f` the frame
  tuple changes, so the gate already refetches; drawing a frame from a file
  that is not focused is the missing piece.
- **struct expansion** — the fourth element of each `(name type value
  reference)` variable tuple is the handle; `reference` 0 means leaf.
- **scope-aware shadowing** — replace the last-at-or-above-stop-line rule
  with real scope ranges from tree-sitter; the one genuinely hard piece.
- **non-Rust languages** — per-language node kinds and a different scope name
  than `"Local"`.

## Development

`nix develop` gives a shell with `steel` and a throwaway `STEEL_HOME` under
`.dev/` symlinking this checkout to `$STEEL_HOME/cogs/inline-values.hx`, so
`(require "inline-values.hx/...")` resolves exactly as it will in helix.
`tests/syntax-check.scm` is a bracket-balance check — `inline-values.scm`
cannot be *evaluated* outside the editor (it requires `helix/*`), and an
unbalanced paren there fails silently at helix startup. The nix build runs it
via `doSteelCheck`.

One compiler trap this repo has already paid for: `fn` is Steel's lambda
shorthand, so `(define fn ...)` — or `struct`, or `lambda` as a binding name —
panics Steel's analysis pass (`Option::unwrap` on a desugared non-atom define
name) and takes helix down at startup, before a frame is drawn. Bindings that
hold a function node are called `fnode` here for that reason.

Consumer wiring (magos): flake input `inline-values-hx` (a `path:` input
while developing — pinned by narHash, so `nix flake update inline-values-hx`
after every edit), `selectPlugins` in `modules/features/helix/default.nix`,
and `(require "inline-values.hx/inline-values.scm")` in `_config/init.scm`.

Two traps when iterating against a patched helix, both of which look exactly
like plugin bugs and are not:

- `rm -rf ~/.cache/helix-steel/cogs/helix` after any **helix patch** change —
  helix regenerates its builtin cogs there, and a stale `misc.scm` keeps
  advertising the old bindings, so new ones silently fail to define.
- `nix build` without `--no-link`, or check `readlink -f result` — a stale
  `result` symlink is indistinguishable from "the change did nothing".

Start helix from `devenv shell` when testing: without `rustc` on PATH,
codelldb cannot find the Rust visualizers and every value comes back as
`{len:3}` / `{...}` instead of `size=3` / `"hello"`.

## License

MIT — see [LICENSE](./LICENSE).
