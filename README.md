# inline-values.hx

Debugger values drawn inline in the [Helix](https://helix-editor.com) editor
while stopped — the `fn add(x: f32 = 5, y: f32 = 10.5)` / `let sum = x + y; = 15.5`
/ `let (a, b) = compute(); a = 1, b = 2` rendering popularized by VS Code /
IntelliJ, for a codelldb session in Helix.

> **Status: v1.6, still deliberately narrow.** Function parameters (plain
> identifiers only) and `let` bindings — single-name or destructured, one
> hint per statement — the stopped frame only, the focused buffer only,
> Rust only. Destructured parameters, parent frames and struct expansion
> come after (see *Out of scope*).

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
the cursor, so they fire the first hook. No DAP event hook is needed (and none
exists).

**Terminate is the exception, and its semantics are worth stating exactly.**
It moves no cursor, and its teardown is async: `dap_terminate` sends the DAP
request and returns, `unset_active_client` runs in the response callback —
after which *no Steel event fires at all*. So the `post-command` of the
terminate keypress itself still sees the old frame and early-returns
(measured). What makes the hints disappear anyway: `space G` is a **sticky**
menu, so leaving it after `space G t` is necessarily another keypress, and
that command's `post-command` runs after the teardown has landed — frame
`#f`, hints cleared. Net observable behavior: the values vanish together
with the debug menu, with no stale window a user can reach. A debuggee
exiting on its own clears on the next editor event the same way.
A `terminal-focus-gained` hook was tried for this — the debuggee's tty is an
external window, so terminate closes it and focus returns with no keypress —
but measured against the foot window that FocusGained arrives *before* the
teardown lands, so the frame still compares equal and nothing clears. It
earned nothing and was dropped. Both remaining hooks run the same light path,
so the gate below is what every firing costs.

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
truncated to 48 characters.

**Let placement (v1.6).** The same `function_item` is then walked recursively
for `let_declaration` nodes — through blocks, `if`/`match` arms and loops —
pruning subtrees that open a *different* scope than the stopped frame's
(nested `function_item`, `closure_expression`, `async_block`, `try_block`):
their `let`s are not this frame's locals, and annotating them from the outer
frame's variables could put a confidently wrong value on the line when a
captured name collides. `pattern-names` collects every name a pattern binds,
recursively: `identifier`; the `mut_pattern`/`ref_pattern`/
`reference_pattern` wrappers; `tuple_pattern` and `tuple_struct_pattern`
elements; `struct_pattern` fields in both shapes — shorthand `{ host }`
binds the name itself, rename `{ host: h }` binds the pattern after the
colon, so the hint says `h`, not `host`. Skipped silently: `_`,
`or_pattern` (nothing says which side bound), literal and range patterns,
`slice_pattern`, `..` and `x @ pat`. The pattern node itself is found by
walking *all* children up to the first `=`/`:`/`;`/`else` token — `_` is an
anonymous node, and a named-children walk of `let _ = y;` would hand back
the value `y` and annotate the wildcard let with it (v1.5 did).

**One hint per statement, not one per name.** A destructured `let` draws a
single trailing hint with the bound pairs joined — `let (a, b) = compute();
a = 1, b = 2` — capped at four pairs, then `, +N more`. A hint after each
identifier *inside* the pattern would read as a default
(`let (a = 1, b = 2) = …`), and struct patterns would scatter them across
the line; one trailing hint keeps the v1.5 anchor — the declaration's end
byte, after the `;` — because a second `= 15.5` mid-line, in a statement
that already has an `=` and an initializer, reads as part of the
expression. A single plain identifier (with or without `mut`) keeps the
v1.5 ` = value` shape. Names lldb does not (yet) report are dropped from
the hint; when none resolve, nothing is drawn rather than an empty `=`.
Un-executed `let`s below the stop line need no filtering in the common
case: lldb reports a local only once it is in scope, so `find-var` simply
misses.

**Shadowing is bounded, not solved.** lldb can report two locals with the
same name and nothing in the DAP response says which block each belongs to,
so when a name is bound by several `let`s, only the **last binding at or
above the stop line** is annotated and the others stay bare — the binding
most likely in scope, and a blank line rather than a confidently wrong
number for the rest. With several names per statement the rule applies per
name: a later `let sh_x = 99;` strips `sh_x` from an earlier
`let (sh_x, sh_y)`'s hint, which keeps showing `sh_y = 2`, and a statement
that loses every name drops out. Scope-aware resolution from tree-sitter
replaces this rule; until then it is the deliberate v1.6 behavior (see the
comment on `dedupe-let-anchors`).

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

- **destructured parameters** — the parameter path still draws plain
  identifiers and `self` only; `fn f((a, b): (i32, i32))` stays bare. The
  `pattern-names` recursion would carry over, but the anchor choice (one
  hint per parameter vs per statement) is open.
- **`slice_pattern`** — `[first, rest @ ..]`-style patterns are skipped
  silently; the same recursion would cover the binding elements.
- **`or_pattern`** — `Ok(v) | Err(v)` binds `v` from either side; which
  value the hint shows is a design question, not a traversal one.
- **parent frames** — when switching frames with `space G s f` the frame
  tuple changes, so the gate already refetches; drawing a frame from a file
  that is not focused is the missing piece.
- **struct expansion** — the fourth element of each `(name type value
  reference)` variable tuple is the handle; `reference` 0 means leaf.
- **shadowing between two live bindings** — a binding is annotated only when
  its own block still contains the stop line, so an exited block's binding is
  left bare and the live one takes the value. What remains is the case where
  two same-named bindings are *both* in scope at the stop: there the innermost
  declaration is still a guess, since nothing in the DAP response says which
  block a variable belongs to. Narrow, but the genuinely hard piece.
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
