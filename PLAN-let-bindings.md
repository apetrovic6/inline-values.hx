# Plan: `let` bindings (v1.5)

v1 annotates function parameters. This adds the other half of what you look at
while stepping — local `let` bindings:

```rust
fn add_nums(x: f32 = 5, y: f32 = 10.5) -> f32 {
    let sum = x + y;                        sum = 15.5
    println!("{sum}");
}
```

Parameters are the values you were *called* with; `let`s are the ones you are
building. Stepping through a function without them means reaching for
`space G v` on every line, which is the thing this plugin exists to avoid.

Scope: Rust, the stopped frame, the focused buffer — same narrowing as v1. No
new editor patches are needed; everything below is plugin-side.

## What you are building on

`inline-values.scm` already has the shape this reuses. Read these three first:

| thing | what it does |
|---|---|
| `parameter-anchors` | walks a `function_item`'s `parameters`, returns `((name . char-index) ...)` |
| `find-var` | first variable whose name matches, out of the `(name type value reference)` tuples |
| `draw-parameters` | loops the anchors, looks each up, emits one `add-styled-inlay-hint` |

`let` support is the same three steps against a different node kind:
`let-anchors`, reusing `find-var`, and `draw-lets` called from `redraw`
alongside `draw-parameters`.

The frame gate, the fetch, the truncation, the byte→char conversion
(`text.rope-byte->char`) and the clearing all stay exactly as they are. Do not
touch them.

## Design decisions

**Draw at the end of the `let_declaration`, not mid-line.** A parameter ends
cleanly after its type, so `x: f32 = 5` reads naturally. A `let` line already
contains an `=` and an initializer; a second `= 15.5` in the middle of it reads
as part of the expression. Anchor on the node's end byte — after the `;` — so
the value sits at the end of the statement, which is also where VS Code and
IntelliJ put it.

**Handle `identifier` and `mut_pattern`; skip every other pattern.** From the
grammar (`tree-sitter-rust` at the rev Helix pins, `261b2022`), a
`let_declaration` has fields `pattern`, `type`, `value` and `alternative`, and
`pattern` is a `_pattern` — one of 18 subtypes. Only two matter for v1:

- `identifier` → the name, directly.
- `mut_pattern` → wraps a `_pattern` plus a `mutable_specifier`; descend to the
  inner pattern, which is normally an `identifier`. `parameter-anchors` already
  does this dance for `mutable_specifier`, so copy that.

`tuple_pattern`, `struct_pattern`, `tuple_struct_pattern`, `ref_pattern`,
`or_pattern`, `_` and the rest bind zero or several names and each needs its own
anchor per name. Skip them — silently, not as an error. They become a follow-up
once the simple case is solid.

**No line filtering is needed, and this is worth knowing before you write one.**
A `let` below the stop point should obviously not show a value, but you do not
have to compare line numbers to get that: lldb only reports a local once it is
actually in scope. Measured on a real stop — breakpoint *on* `let sum = x + y;`
gave 3 locals (`x`, `y`, `label`, no `sum`); one step later, 4. So an
un-executed `let` simply finds no match in `find-var` and draws nothing. Let the
data do it.

**Shadowing is where this gets genuinely wrong, so bound it deliberately.**

```rust
let x = 1;
{
    let x = 2;      // lldb may report two locals both named "x"
}
```

`find-var` takes the *first* match by name, and nothing in the DAP response says
which block a variable belongs to. So with a shadowed name the plugin cannot
know which `let` a value belongs to, and a confidently wrong number is worse
than a blank line.

v1.5 rule: when a name is bound by more than one `let` in the function, annotate
**only the last one at or above the stop line** and leave the others bare. That
is the binding most likely in scope, and the others visibly get nothing rather
than something false. Write the rule down in a comment next to the code, because
it is the thing the scope-aware follow-up replaces.

## Implementation

1. **`let-anchors text fn-node stop-line`** — walk the `function_item`'s body
   for `let_declaration` nodes. This is a recursive walk, not just named
   children: `let`s nest inside blocks, `if`/`match` arms and loops. For each,
   take the `pattern` field, resolve it per the rules above, and produce
   `(name . char-index)` with the index from `(b->c text (tsnode-end-byte node))`.

2. **Dedupe by name** before drawing: keep the last entry at or above the stop
   line for each name, drop the rest.

3. **`draw-lets`** — the body of `draw-parameters` with the anchors swapped.
   Same `find-var`, same `truncate-value`, same style. If you want the `let`
   values dimmer than the signature ones, that is a one-token change in
   `value-style`; consistency is a reasonable default, so start identical.

4. Call it from `redraw`, right after `draw-parameters`, inside the same
   `clear-decorations!` cycle. No changes to the gate, the fetch, or the cache.

## Verifying it

Use the harness that already exists: `space G d` in a scratch crate, Helix
started from `devenv shell` in `~/programming/rust-app-template` (without it the
values read `{len:3}` and `{...}` instead of `size=3` and `"hello"` — that is
codelldb missing the Rust visualizers, not a plugin bug).

A probe that covers the cases in one file:

```rust
fn main() {
    let plain = 41 + 1;
    let mut counter = 0;
    counter += 1;
    let shadowed = "outer";
    {
        let shadowed = "inner";
        println!("{shadowed}");
    }
    let (a, b) = (1, 2);           // destructuring: must be skipped, not crash
    println!("{plain} {counter} {a} {b}");
    let after = 99;                // below the stop: must show nothing
}
```

Breakpoint on the `println!`, then check:

- `plain` and `counter` show their values at end of line; `counter` shows the
  value *after* `+= 1`.
- `after` shows nothing.
- `(a, b)` shows nothing and nothing errors.
- `shadowed` annotates one binding, not both, and does not show `"inner"` on the
  outer line.
- 50 cursor moves while stopped → **0** refetches, same as v1. Count it in the
  log rather than assuming; this is the property most easily broken by a change
  in `redraw`.
- Step → values update. Terminate → hints gone.

## Traps

Each of these cost a debugging round-trip during the v1 and patch work.

- **Stale generated cogs.** Helix regenerates its builtin cogs into
  `~/.cache/helix-steel/cogs/helix/`; a stale `misc.scm` there keeps advertising
  the old bindings and a plugin referencing a new one fails to define
  *silently* — `Finished loading init.scm!` in the log, `no such command` at the
  call site. `rm -rf` it after any editor-patch change. Not needed for
  plugin-only edits, but free.
- **`nix flake update inline-values-hx`** in magos before rebuilding, or the
  `path:` input's narHash pins the old source and you test the previous plugin.
- **A stale `./result`.** `nix build --no-link` leaves it pointing at the
  previous build. Check `readlink -f result`.
- **The sticky `space G` menu eats keystrokes.** After `space G t` you are still
  in the submenu, so a following `j` does nothing and it looks like the hook
  never fired. Press Escape first. This produced one wrong conclusion already.
- **`:goto-line` is not a command** — it is `:goto`. `:goto-line 9` silently
  leaves the cursor at 1:1 and the breakpoint lands on the wrong line.
- **`(define fn ...)` panics the Steel compiler** (`fn` is Steel's lambda
  shorthand). Any binding named `fn` kills Helix at startup; the codebase uses
  `fnode` for this reason.

## After this

In order: scope-aware name resolution, which replaces the shadowing rule above
and is the one genuinely hard piece left; struct expansion, using the
`reference` already in every variable tuple; parent frames when switching with
`space G s f`; then other languages, each needing its own node kinds and its own
scope name in place of `"Local"`.
