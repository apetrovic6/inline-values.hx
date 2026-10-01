# Plan: destructuring patterns (v1.6)

`let` bindings with a single name are annotated. Patterns that bind several
names are skipped silently, which in idiomatic Rust is a lot of blank lines:

```rust
let (a, b) = compute();                      a = 1, b = 2
let Config { host, port } = cfg;             host = "localhost", port = 8080
let Point { x, .. } = p;                     x = 1
```

Scope: `let` bindings only, Rust only, same frame and buffer narrowing as
before. No editor patches. Destructured *parameters* stay out of scope.

## Prerequisite: verify the tokio override on counter-desktop

Do this first; if it fails, it becomes the task instead.

A `type summary add … "tokio::runtime::.*Runtime"` line was added to both rust
templates in magos (`_config/languages.nix`) because the Rust visualizer
crashes codelldb outright on that type — adapter and debuggee both die on any
`variables` or `evaluate` that renders a frame holding one. It was verified on
`counter-tui`, which has since been restructured to `#[tokio::main]` and no
longer holds a runtime anywhere visible.

`counter-desktop` still does, deliberately: `main.rs:164` is
`let runtime = tokio::runtime::Builder::new_multi_thread()…`, a **named local**
in `main`, because gpui drives its own executor and connectrpc's deadline
panics without a tokio context. So that shell is now the only place the
override is load-bearing, and it has never been tested there.

Stop anywhere in `desktop`'s `main` after line 164 and confirm: the session
survives, `runtime` renders as `<tokio runtime>`, and other locals still show
real values. Note the app needs the devshell's `LD_LIBRARY_PATH` for GPUI's
dlopened libraries — starting Helix from `devenv shell` covers it.

## What binds what

From `tree-sitter-rust` at the rev Helix pins (`261b2022`). A `let_declaration`'s
`pattern` field is one `_pattern`; these are the cases that bind names:

| node | shape | binds |
|---|---|---|
| `identifier` | — | itself (already handled) |
| `tuple_pattern` | `_pattern` children | each child, recursively |
| `tuple_struct_pattern` | `type` field + `_pattern` children | each child, recursively |
| `struct_pattern` | `field_pattern` children, plus `remaining_field_pattern` for `..` | see below |
| `ref_pattern`, `reference_pattern` | wrap one `_pattern` | whatever they wrap |
| `mut_pattern` | wraps one `_pattern` | whatever it wraps (already handled) |

`field_pattern` has a required `name` and an **optional** `pattern`:

- shorthand `{ host }` → `name` is a `shorthand_field_identifier`, no `pattern`;
  the binding is the name itself.
- rename `{ host: h }` → `name` is a `field_identifier` and `pattern` is the
  real binding (`h`). Annotate `h`, not `host`.

Skip, silently: `_`, `or_pattern` (a name can come from either side), literal
and range patterns, `slice_pattern` (worth adding later, same recursion),
`remaining_field_pattern` (`..` binds nothing).

## Design

**One hint per statement, not one per name.** Anchor stays where it is — the
declaration's end byte — and the hint is the bound pairs joined with `, `:

```rust
let (a, b) = compute();        a = 1, b = 2
```

Putting a hint after each identifier *inside* the pattern would read as
defaults (`let (a = 1, b = 2) = …`), and struct patterns would scatter them
across the line. One trailing hint also keeps the existing anchor, scope filter
and dedupe untouched.

**Budget the width.** Several values on one line will blow past the single
value cap. Truncate each value as now, and cap how many pairs are shown —
four, then `, +N more`. A line that needs more than that is better read in a
picker than inline.

**Dedupe by statement, not by name.** The existing rule keeps the last binding
of a given name that is still in scope. With several names per statement that
rule still applies per name, but two names from the same `let` must not produce
two hints at the same anchor — collect per declaration, then emit once.

## Implementation

1. **`pattern-names node` → list of name nodes.** Replaces the single-result
   `pattern-name-node` for the let path (leave the parameter path alone).
   Recursive over the table above; returns `'()` for the skipped kinds. This is
   the whole of the new logic.
2. **`let-anchor`** produces one entry per declaration carrying a *list* of
   names rather than one, keeping the existing anchor, line and scope-end.
3. **`dedupe-let-anchors`** filters on scope as now; for a statement whose names
   survive, keep the statement once.
4. **`draw-anchors`** looks each name up with `find-var`, drops the ones with no
   value (a binding lldb does not report yet), and joins what is left. If
   nothing resolves, draw nothing rather than an empty `=`.

## Verifying it

Use the existing harness: a scratch crate, Helix started from `devenv shell` in
`~/programming/rust-app-template`, `space G d` to build and launch. A probe
covering every case in one file:

```rust
#[derive(Debug)]
struct Config { host: String, port: u16 }

fn main() {
    let (a, b) = (1, 2);
    let Config { host, port } = Config { host: "localhost".into(), port: 8080 };
    let Config { host: renamed, .. } = Config { host: "other".into(), port: 1 };
    let (first, (nested_x, nested_y)) = (9, (10, 11));
    let (_, kept) = (99, 100);
    println!("{a}{b}{host}{port}{renamed}{first}{nested_x}{nested_y}{kept}");
    let after = 1;              // below the stop: still nothing
}
```

Breakpoint on the `println!`. The bar:

- `(a, b)` → `a = 1, b = 2`.
- `{ host, port }` → `host = "localhost", port = 8080` (shorthand binds the
  field name).
- `{ host: renamed, .. }` → `renamed = "other"` only; no `host`, no `..`.
- nested tuple → `first = 9, nested_x = 10, nested_y = 11`.
- `(_, kept)` → `kept = 100` only.
- `after` bare.
- Single-name lets and `self` in the signature still annotate as before.
- 50 cursor moves while stopped → **0** refetches, log-counted. Most easily
  broken by this change; assert it, do not assume.
- Step → values update. Terminate → hints gone, no stray processes.

## Traps

- **Stale generated cogs.** `rm -rf ~/.cache/helix-steel/cogs/helix` after any
  editor-patch change; a stale `misc.scm` makes a plugin referencing a new
  binding fail to define *silently* — `Finished loading init.scm!` in the log,
  `no such command` at the call site.
- **`nix flake update inline-values-hx`** in magos before rebuilding, or the
  `path:` input pins the old source. A `result` symlink left in the plugin repo
  changes that input's NAR hash and breaks the build with a mismatch — do not
  leave one.
- **A stale `./result`.** `nix build --no-link` leaves it pointing at the
  previous build; check `readlink -f result`.
- **The sticky `space G` menu eats keystrokes.** After `space G t` you are still
  in it, so a following `j` does nothing and it looks like the hook never fired.
  Escape first. This has produced two wrong conclusions already.
- **`:goto-line` is not a command** — it is `:goto`.
- **`(define fn …)` panics the Steel compiler**; the codebase uses `fnode`.

## After this

Struct expansion is worth less than it was: `self` now renders
`{counter:…, selected:0, …}` inline, which covers most of what it would have
bought. What is left after destructuring: two same-named bindings both live at
one stop (the remaining shadowing guess), parent frames, and other languages.
