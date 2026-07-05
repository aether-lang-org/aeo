# Formae vs aeo — comparison and envy list

Written 2026-07-05, from a read of the Formae repo (`~/scm/formae`, upstream
`github.com/platform-engineering-labs/formae`) at a point where its recent
commits were about plan-diff canonicalization and drift absorption. Audience:
a future LLM session (or human) deciding what aeo should build next, with
enough behavioural detail to reproduce the ideas **clean-room** — see the
licensing section for why that constraint is load-bearing.

---

## Licensing boundary (read first)

Formae is **FSL-1.1-ALv2** (Functional Source License 1.1, Apache-2.0 future
grant): source-available, non-compete, each release converting to Apache 2.0
two years after it ships. It is **not** OSI open source today, and
contributions there require a CLA. aeo and its siblings lean permissive (MIT).

Consequence: **do not copy Formae code, comments, or file structure into aeo.
Do not paraphrase its source line-by-line.** Everything below is a
*behavioural* description — what the feature does as observed from the outside
(CLI surface, package names, doc comments read for comprehension, README
claims) — which is the raw material for an independent implementation in aeo's
own idiom. If you find yourself with a Formae file open in one pane and an aeo
file in the other, stop.

---

## What Formae is

An "agentic IaC" tool from Platform Engineering Labs. One-paragraph model:

- **Go** codebase; config language is **Pkl** (Apple's; evaluated via a forked
  `pkl-go`). Infrastructure is declared as Pkl code with an enforced schema.
- **No state file** (their headline anti-Terraform pitch). Instead, a
  long-running **agent** (`formae agent start` + thin client CLI) continuously
  *discovers* reality and **merges external drift back into the infrastructure
  code**. Reality is the source of truth; the code is kept in sync with it,
  not the other way round.
- **Erlang-style actors in Go**: built on `ergo.services` (OTP-alike —
  supervisors, statemachines, typed messages). The core engine
  (`internal/metastructure/`) is an actor tree: auto-reconciler, synchronizer,
  discovery, changeset executor, plugin coordinator, per-concern persisters.
- **Out-of-process provider plugins** (AWS first), process-supervised, with a
  published **conformance test suite** (`pkg/plugin-conformance-tests`) so
  third parties can validate a plugin against the contract.
- CLI surface (from `internal/cli/`): `apply`, `destroy`, `extract`,
  `inventory`, `status`, `plan`-ish display, `eval`, `plugin`, `agent`,
  `cancel`, `clean`, plus profile/project/config plumbing. HTTP API with
  swagger; otel instrumentation; an embedded datastore.
- Positioning: coexists with Terraform/ClickOps rather than replacing them —
  it discovers resources it didn't create and folds them into versioned code.
  Marketed for "small blast radius" patch workflows (on-call engineer changes
  one property at 3 a.m. without owning the whole codebase).

## How the overlap with the ae* family shakes out

- **aeo is the true sibling.** Both stand up dependency-ordered infrastructure
  from a single code artifact. But the domains barely touch: aeo does local
  substrates (jails/bhyve, podman/LXC/KVM) with *containment* as the point;
  Formae does cloud-provider CRUD with *reconciliation* as the point.
- **Aether overlap is philosophical.** Both stacks independently concluded
  YAML/HCL can't compute and Pulumi/CDK reads like glue, and planted a flag in
  the middle — Aether with the closure-DSL ("config IS code — a program you
  run"), Formae with Pkl (a config *language*, evaluated by the tool). Same
  critique, opposite mechanisms. Formae is, structurally, the thing aeo's
  "never add a config parser" rule forbids — that's their philosophy, not a
  gap in ours.
- **Actor convergence is the striking one.** Formae chose OTP-style
  supervision (via ergo) for exactly the role aeo's resource actor plays.
  Independent validation that Erlang-shaped actors are the right concurrency
  backbone for infra orchestration.
- **aeb overlap ≈ none.** Formae's dependency graph is runtime and
  reconciliation-driven — firmly on aeo's side of the declare-then-schedule /
  imperative-runtime line.
- **State philosophy:** both refuse a Terraform state file, differently.
  Formae: standing agent + discovery + merge-into-code. aeo: ephemeral live
  handles, verify-gone teardown, no persistence at all. Note for item 1 below:
  aeo can get drift detection **without** adopting Formae's datastore, because
  the composition file + live substrate probes already constitute
  desired-vs-actual.

---

## The envy list (ranked)

The through-line: **Formae's edge is everything that happens after first
deployment.** aeo beats it on bring-up rigor and containment; items 1–3 are
one theme — giving aeo a life between `up` and `down`.

### 1. The reconcile loop — "keeps coherent" is aeo's thinnest claim

**STATUS: BUILT + live-proven 2026-07-05.** `aeo reconcile` (one-shot) +
`aeo watch` (loop) + the shared `lib/reconcile` property-diff. Detects liveness +
confinement-envelope drift (image/mem/pids/cpus), audits every drift as a security
event, converges with `--converge` (default is alert-only). Container kind (v1);
net-membership diff + apply-node (item 3) reuse the same diff primitive. See
`docs/reconcile.md`. The rest of this section is the original clean-room design.

aeo's purpose statement is "stands up, *keeps coherent*, tears down" — but
between `up` and `down`, aeo is absent. A node OOM-killed, a jail restarted by
hand with different flags, an image rebuilt underneath a running container:
aeo won't know until an operator reruns it.

**What Formae does (behaviourally):** an auto-reconciler actor implemented as
a two-state statemachine (idle ⇄ reconciling), with per-stack reconcile
intervals scheduled via the actor runtime's send-after primitive, driven by
*policies attached to stacks as data*. A separate discovery subsystem
periodically re-arms and sweeps for external changes; found drift is absorbed
into the code rather than reverted (with a recent refinement: resources whose
*target* was deleted get forgotten rather than endlessly re-discovered).

**Clean-room notes for aeo:**
- New verb: `aeo watch <compose.ae>` (or `aeo reconcile` for one shot).
  Long-running mode of the existing runner — NOT a new daemon architecture.
- Loop shape: for each node in dependency order, re-run the driver's probe
  (existence + health), re-read the rendered confinement envelope
  (`limit{}`/`constrain{}`) from the substrate (podman inspect / rctl / lxc
  info equivalents, via the existing drivers), diff against the composition.
- Convergence actions, in escalating order: re-probe → restart node →
  recreate node (respecting `depends` order for anything downstream).
  Re-attest on recreate (fail-closed, as `up` already does).
- **Containment angle Formae doesn't have:** a confined node drifting out of
  its declared envelope is a *security event*. Write every drift detection and
  every convergence action to the existing `lib/audit` hash chain.
- State: none. Desired = the composition; actual = live probes. Do NOT add a
  datastore for this. The one allowance: an in-memory generation counter per
  node inside the watch process.
- Timing knobs reuse the existing `health_retry{}` grammar — add a sibling
  block (see item 5) rather than inventing new syntax.
- This is imperative-runtime work — aeo's grain. It is not a static DAG, so
  the "you're becoming aeb" alarm does not apply.

### 2. Extract — reality → code (brownfield adoption)

**STATUS: BUILT + live-proven 2026-07-05.** `aeo extract` walks live containers and
emits a valid composition (image/command/expose/limit + `attest()` pre-filled with the
CURRENT image digest — the instant attestation baseline). `aeo inventory` is the same
walk as a table with a `DECLARED?` column vs a given composition (the coexistence
story). Round-trip proven: up → extract → the emitted `.ae` re-parses and `dry-run`
plans it back; `/bin/sh -c` wrapper stripped, bytes→human (`128M`), podman default
PidsLimit omitted. `lib/extract` (pure emitter, spec_extract.ae 7). Container kind v1;
no `depends()` inference (edges unobservable — a follow-up). See `docs/extract.md`.

**What Formae does:** `extract` generates infrastructure code from live cloud
resources; `inventory` lists what exists, managed or not. This is what makes
its "coexist with Terraform and ClickOps" pitch credible — Day 0 is optional.

**Clean-room notes for aeo:**
- New verb: `aeo extract [--substrate containers|lxc|kvm|jail] > compose.ae`.
  Walk the host's live state via the existing drivers (podman ps + inspect,
  jls, lxc-ls, virsh list equivalents — the probe primitives mostly exist),
  emit a valid composition: `system("extracted") { container("name") {
  image("…") … } }`.
- Emit `attest()` lines pre-filled with the *current* image digests — turning
  extraction into an instant attestation baseline is a containment win Formae
  has no analog for.
- Dependency edges can't be observed reliably; emit nodes flat with a
  `// TODO depends(…)` comment convention rather than guessing.
- `aeo inventory` = the same walk, rendered as a table instead of code; add a
  column for "declared in <compose.ae>? yes/no" when given a composition —
  that's the coexistence story in one screen.
- Round-trip test shape: `up` a known composition → `extract` → the output
  re-parses and its nodes match the original's names/images/limits (aeocha
  spec, per substrate, slots straight into the substrate grid).

### 3. Patch semantics — small blast radius on a standing tree

**STATUS: BUILT + live-proven 2026-07-05.** `aeo apply-node <compose> <node>` (a
single-node, always-converge reconcile reusing `lib/reconcile`) + `aeo dry-run` grown
to show a live property diff when the tree is up. Proven: applying one drifted node
recreated only it, left its sibling untouched. See `docs/reconcile.md`. Rate limiting
skipped (cloud-API concern, per the notes). The rest is the original clean-room design.

**What Formae does:** targeted changes travel as patch documents; a changeset
executor computes the minimal delta (with rate limiting toward cloud APIs) so
an on-call engineer can change one property of one resource without touching
or understanding the whole tree. Their recent plan-UX work shows *only
genuinely changed properties*, after canonicalizing representational noise
(e.g. serialized-JSON string fields) so cosmetic differences don't show as
drift.

**Clean-room notes for aeo:**
- New verb: `aeo apply-node <compose.ae> <node>` — re-render that one node's
  flags from the (edited) composition, diff against the live node, apply only
  the delta; restart only that node and (only if a changed property requires
  it) its dependents.
- Prerequisite: a per-node desired-vs-actual **property diff**, which is the
  same primitive item 1 needs — build once, use twice.
- `aeo dry-run` should grow the same property-level diff against *live* state
  when the tree is already up (today dry-run only previews the plan).
  Canonicalize before diffing: normalize digest forms, whitespace in command
  strings, list ordering where the substrate doesn't preserve it — otherwise
  the diff cries wolf and operators stop reading it.
- Rate limiting is a cloud-API concern; skip it. Local substrates don't need
  it and it's complexity with no payoff here.

### 4. Driver conformance-test kit (cheapest item, pure test code)

**STATUS: BUILT 2026-07-05.** Two layers: `test/spec_driver_conformance.ae` (pure —
every driver's name() non-empty + distinct; the shape compiles or the build fails; the
stub is fail-loud) and `test/conformance-behavioral.sh` (the create→probe→confinement→
stop→verify-gone lifecycle, driven through the real `aeo` front-door, per substrate).
Container arm PASSES live on podman 6; jail arm ready + host-gated (needs a prepared
FreeBSD box + a real jail rootfs). Already caught a real bug — driver_stub.probe had a
malformed tuple return instead of the uniform `-> int`; fixed. See
`docs/driver-conformance.md`. Turns the substrate grid from showcase to contract.

**What Formae does:** ships `pkg/plugin-conformance-tests` so any third-party
provider plugin can prove it honors the plugin contract.

**Clean-room notes for aeo:**
- One aeocha spec suite, parameterized by driver, that every substrate driver
  (`driver_linux`, `driver_lxc`, `driver_vm`, `driver_bsd`) must pass:
  create → start → probe-healthy → confinement-flags-present →
  attest-mismatch-refused (fail-closed) → stop → **verify-gone**.
- This turns the `examples/silly_addition_*` substrate grid from a *showcase*
  of parity into a *contract* for it. Host-gate per suite (skip jail specs on
  Linux etc.) using the existing `lib/host` probe.
- Do it before adding any sixth substrate; the sixth driver then arrives with
  its conformance run as the definition of done.

### 5. Continuous policy attachment (DSL companion to item 1)

**STATUS: BUILT 2026-07-05.** `policy(node){ reprobe_every(d) on_drift("alert"|
"converge") restart_after_failures(n) reattest_every(d) }` — compose grammar,
closure-with-setters like `health_retry{}`. `aeo watch`/`reconcile` read it: a node's
`on_drift("converge")` arms just that node (the global `--converge` is the operator
override); the watch cadence floors at the smallest declared `reprobe_every`. Default
`on_drift` = "alert" (never silently mutate). Purely additive — no `policy{}` = today's
behavior. test/spec_policy.ae (6). See `docs/reconcile.md`. The rest is the clean-room design.

**What Formae does:** reconcile policies are attached to stacks *as data*, and
the runtime enforces them on a schedule; policies are updatable independently
of the resources they govern.

**Clean-room notes for aeo:**
- A `policy{}` block per node (or per `system{}`), closure-with-setters,
  single-arg, same shape as `health_retry{}`:
  `policy() { reprobe_every(30s) restart_after_failures(3)
  reattest_every(24h) on_drift("converge")  // or "alert" }`
- Pure accumulation into the compose KV; only `aeo watch` (item 1) reads it.
  `up`/`down` semantics unchanged — a composition with no `policy{}` behaves
  exactly as today, so this is additive.
- `on_drift("alert")` = audit-log + nonzero status only; `"converge"` = act.
  Default should be `"alert"` — containment tools should not silently mutate.

### 6. Out-of-process plugin supervision — envy *with reservations*

**What Formae does:** providers run as supervised external processes
(spawn, monitor, restart), discovered/managed by a plugin manager, so third
parties add providers without touching core.

**aeo position:** compiled-in drivers are simpler and correct at five
substrates. This becomes worth revisiting only if the driver count grows or
outsiders want to contribute substrates without forking. If that day comes,
aeo already owns the right seam: an out-of-process driver is just the
resident-deputy/agent protocol (`boot/halt/probe/announce/report`,
`lib/protocol/`) spoken by a local process instead of an in-node one. Do not
build this speculatively.

---

## What NOT to envy

- **Pkl / any external config language.** "Config IS code, never a config
  parser" is aeo's genuine differentiator. Formae evaluating Pkl is their
  philosophy, not our gap.
- **The datastore / persisted state.** aeo's statelessness is a feature, and
  item 1 works without it (composition + probes = desired vs actual). The
  moment someone proposes "just a small SQLite for reconcile bookkeeping,"
  re-read this line.
- **A persisted resource dependency graph.** That direction is the "second
  aeb" trap (see LLM.md, "The one thing to never get wrong").
- **HTTP API + swagger surface.** Formae needs it (client/agent split,
  multi-user). aeo's operator surface is the CLI + compositions; an API is a
  solution looking for a problem until aeo-agent's transport_http work makes
  one exist naturally.
- **CLA / non-compete licensing posture.** Obviously.

## Suggested build order

1 and 3 share the desired-vs-actual property-diff primitive — build that
first, then: **4 (conformance kit) → diff primitive → 3 (apply-node +
dry-run-vs-live) → 1 (watch/reconcile) → 5 (policy block) → 2 (extract)**.
Item 4 first because it's pure test code, hardens the drivers the other items
lean on, and costs an afternoon per substrate. Item 2 last because it's
independent of the diff work and shines brightest once reconcile exists (an
extracted composition can then be *kept* true, not just generated once).
