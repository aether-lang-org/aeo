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
