# `aeo watch` / `aeo reconcile` — drift detection between up and down

aeo's purpose is "stands up, **keeps coherent**, tears down." Bring-up and teardown
were always rigorous; *keeps coherent* was the thin part — between `up` and `down`,
aeo was absent. A node OOM-killed, a container hand-restarted with different flags,
a memory cap externally relaxed: aeo wouldn't notice until an operator re-ran it.

`aeo reconcile` / `aeo watch` close that gap. (Formae-envy item 1; see
`docs/formae_vs_aeo.md`.)

## Model — no state, no datastore

Desired state = **the composition**. Actual state = **live substrate probes**. There
is no persisted state file and no bookkeeping datastore — aeo's statelessness is
preserved. Each pass reads a node's actual rendered properties off the substrate
(`podman inspect`), renders what the composition now declares, and diffs them.

## Commands

```sh
aeo reconcile compose.ae            # one-shot: probe + diff every node, report, exit 1 on drift
aeo reconcile compose.ae --converge # ...and FIX detected drift
aeo watch     compose.ae            # reconcile on a loop (default every 30s) until Ctrl-C
aeo watch     compose.ae --converge 15   # loop every 15s AND converge
```

`AEO_CONVERGE=1` and `AEO_WATCH_INTERVAL=<seconds>` are the env equivalents.

## Default is ALERT, not mutate

A containment tool must not silently mutate. So the default is **detect + audit
only** — drift is printed and written to the `lib/audit` hash chain, and `reconcile`
exits non-zero (a CI-usable coherence gate). Convergence happens **only** with
`--converge`.

## What it detects (the confinement envelope)

Per node, in declaration (dependency) order:

1. **Liveness** — is the node running and healthy? (down / unhealthy = drift.)
2. **The security-critical envelope** — a field-by-field diff of:
   - **image** — a swapped image underneath a running node
   - **mem** (`--memory`) — a relaxed/tightened memory cap
   - **pids** (`--pids-limit`) — a hand-relaxed fork-bomb ceiling
   - **nanocpus** (`--cpus`)

   Memory is **canonicalised before diffing** — aeo declares `128M`, podman reports
   `134217728` bytes; without normalisation every capped node would show false drift.
   (The canonicaliser uses 64-bit math — a 2G cap overflows a 32-bit int.)

**A confined node drifting out of its declared envelope is a security event** — every
drift detection and every convergence action is hash-chained into the audit trail, so
it's provable after the fact. This is the containment angle Formae has no analog for.

## Convergence

With `--converge`:

- **Not running** → restart (bring the node back up, re-attesting fail-closed).
- **Envelope drift** → recreate to the declared envelope. aeo's `up` is idempotent
  (it no-ops a running node), so converge downs the drifted node first, then ups it —
  the recreate goes through the same confined bring-up path (and same attest gate) as
  a fresh `up`.

## `aeo apply-node` — small blast radius on a standing tree

`aeo apply-node <compose.ae> <node>` patches ONE node: re-render that node's flags
from the (edited) composition, diff against the live node, and apply only if it
drifted — recreating just that node, touching nothing else. The on-call "change one
property at 3am without owning the whole tree" workflow. It is a single-node,
always-converge reconcile; a coherent node is a clean no-op, not an error.

```sh
aeo apply-node compose.ae db   # recreate db to the declared envelope if it drifted; app untouched
```

Proven live: on a 2-node tree with `db` externally drifted, `apply-node db`
recreated only `db` (its container id changed, mem restored) while `app`'s container
was left running untouched (id unchanged).

## `aeo dry-run` grows a live diff

When the tree is already up, `aeo dry-run` now also shows the property-level diff of
each container node against live state (below the plan preview) — so you see what an
edited composition WOULD change before applying. On a host where nothing is running,
dry-run reads exactly as before (plan only).

## `policy{}` — per-node reconcile policy as data

A node can declare HOW it wants to be kept coherent, and the reconcile loop reads it
(Formae-envy item 5; the DSL companion to `watch`). Same closure-with-setters shape
as `health_retry{}`:

```
app = container("app") { image("...") }
policy(app) {
    reprobe_every(15s)          // this node's own watch cadence
    on_drift("converge")        // act on drift (default: "alert" only)
    restart_after_failures(3)   // restart->recreate escalation threshold (advisory)
    reattest_every(24h)         // re-verify the image digest periodically
}
```

- **`on_drift`** defaults to **`"alert"`** — a node converges from its own policy only
  when it declares `on_drift("converge")`. This is the composition expressing intent;
  the global `--converge` flag is the operator's tree-wide override. Either arms a
  node; the safe default (no policy, no flag) stays detect-only.
- **`reprobe_every`** sets the watch cadence. `aeo watch` runs at `AEO_WATCH_INTERVAL`
  if set, else the SMALLEST declared `reprobe_every` across nodes (so an eager node
  isn't starved by the 30s default), else 30s. Every node is reconciled each pass;
  true per-node independent scheduling is a follow-up.
- Purely **additive**: a composition with no `policy{}` behaves exactly as before.
  `up`/`down` are unaffected — only `watch`/`reconcile` read the policy.
- `describe_tree` surfaces a non-default policy (`policy{on_drift=converge}` /
  `policy{reprobe=5000ms}`); a default node adds no noise.

## Scope (v1) and follow-ups

- **container kind only** — the one kind with an inspect surface today. Other kinds
  report "reconcile not yet supported for kind=X" (honest, not silent).
- **net membership is not diffed** — it renders differently across the netpolicy
  tiers (bridge shows the aeo net, pasta-default empty, `deny_egress` none), so a
  naive net diff cries wolf. Per-tier net reconciliation is a follow-up.
- The desired-vs-actual **property diff** (`lib/reconcile`) is a shared primitive —
  a future `aeo apply-node` (Formae-envy item 3) reuses it for single-node patching.

## Proven live

On a real podman 6.0.0 host (CachyOS N100): `up` a confined container, externally
`podman kill` it → reconcile reports "not running"; externally `podman update
--memory` it → reconcile reports `mem: 536870912 -> 134217728`; `--converge` recreates
it and the cap returns to the declared value; every event is in the audit chain.
