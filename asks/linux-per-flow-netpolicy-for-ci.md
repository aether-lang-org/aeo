# Ask: close the Linux per-flow netpolicy gap (port enforcement + the egress_fqdn tier) — a CI daemon is now consuming the workaround

Filed from Paul's request, 2026-07-17. Consumer: **aeci**
(github.com/aether-lang-org/aeci, private) — the family's CI daemon,
running today. Not blocking (aeci ships a documented workaround); this
de-risks its next phase and retires two hand-rolled network paths that
belong on aeo's side of the seam.

## First, what this ask is NOT claiming

aeo's netpolicy grammar is **complete** and this ask adds **no new
composition surface**. `egress(peer, port)`, `ingress(port)`,
`egress_fqdn(host)`, `deny_egress()` already express everything the
consumer needs, and on FreeBSD pf enforces them per-flow (live-proven,
14.3). On Linux, `confine_linux.net_kind`/`net_flags` already classify
into three sound tiers (proven on Bazzite):

| netpolicy | Linux today |
|---|---|
| `deny_egress()` | `--network none` — nothing |
| any `egress->peer:port` flow | `--network <internal>` — peers by name, no host/internet |
| `egress_fqdn:HOST` | `--network <internal>` (recorded; gateway "future" per compose docs) |
| none | shared net |

The gap is **enforcement granularity on Linux**, two specific pieces:

1. **The `internal` tier is all-peers-any-port.** `egress(db, 5432)`
   renders as membership of an `--internal` network: the node can reach
   *every* peer on that network on *every* port. The declared
   `(peer, port)` pair — which pf turns into a real whitelist — is
   dropped on the floor by the Linux renderer. Two co-located sidecars
   (say postgres AND a secrets-bearing fixture) are mutually fully
   reachable even when the policy names only one flow.
2. **`egress_fqdn` is recorded but unenforced everywhere.** The compose
   docs are honest that packet filters can't do DNS names and a
   parent-owned CONNECT gateway is the design. Nothing renders it yet on
   either substrate; on Linux the node lands on `internal` and simply
   cannot reach the host at all — safe-closed, but the declared flow
   doesn't work, so consumers route around the grammar (see census).

## The consumer census (real shipped code, aeci main as of 2026-07-16)

aeci executes attacker-controlled per-branch pipelines; every build step
runs deny-egress by default with aeo's `confine_linux` flag vocabulary.
Three call sites currently hand-roll what this ask asks aeo to own:

- **`lib/services/module.ae`** — sidecars (a postgres next to a test
  stage). aeci itself creates `podman network create --internal <net>`,
  runs sidecars with `--network <net> --network-alias <svc>`, and points
  the build step at the net via ambient config. This is a reimplementation
  of `net_kind`'s middle tier on the wrong side of the seam — and it
  inherits gap (1): the step can reach the sidecar on ANY port, and
  sidecars can reach each other.
- **`lib/warmer/module.ae`** — dependency fetching under deny-egress.
  A once-per-lockfile-hash warmer stage is the only egress-granted step;
  it populates a content-addressed cache volume that offline build steps
  mount. Its header comment names this ask's gap (2) verbatim: *"v0
  grants the warmer the default bridge; scoping it to the named registry
  ALONE is aeo's pf/netpolicy peer."* Today that warmer can reach the
  entire internet when the policy intent is `egress_fqdn("rubygems.org")`
  (etc. per language registry).
- **`lib/executor/module.ae`** — the network-selection comment block
  documents the same compromise for a pipeline's declared
  `allow_egress(host:port)`: *"v0 does not yet scope the bridge to just
  the declared host."*

When the aeci→aeo executor seam lands (aeci's next structural step —
today it drives podman directly with aeo's exact flags), these three
paths want to become plain compose renderings: a sidecar is an
`egress(db, 5432)` flow, a warmer is an `egress_fqdn(registry)` node.
That only holds if the rendering enforces what the grammar declares.

## What's being asked, in priority order

### 1. Per-flow port enforcement inside the Linux `internal` tier

When a node's netpolicy declares `egress->peer:port` flows, back the
`--internal` network membership with per-flow rules so only the declared
(source, dest, port) tuples pass — the pf semantics, rendered to the
Linux substrate. Candidate mechanisms (aeo's call, not the consumer's):
nftables rules on the netavark bridge (netavark is nft-native on current
podman; rootless reachability of the bridge hooks needs a spike — if
rootless can't install them, a root-helper under the existing
self-sudo/NOPASSWD driver convention matches how drivers already
escalate), or netavark plugin/firewall driver configuration if podman's
surface allows expressing it declaratively. Deny-default within the
net: an undeclared peer→peer flow is dropped, exactly as pf does it.

Acceptance shape (mirrors the pf live-proof discipline): a 3-node
composition — `step`, `db`, `other` — where policy declares only
`egress(step→db, 5432)`. Prove on a real box: step→db:5432 completes;
step→db:OTHER-PORT blocked; step→other blocked entirely; db→step
blocked (no reverse implication); nothing reaches host/internet.
Recorded proven-vs-modeled per house rule (which box, which date, what
ran).

### 2. First enforcement tier for `egress_fqdn` (the registry case)

The full parent-owned CONNECT gateway is designed and stays the end
state; this asks only for a minimal first tier that makes the declared
flow WORK instead of safe-closed-but-dead: an aeo-owned forward-proxy
node (the gateway in embryo) that the fqdn-declaring node reaches over
the internal net, which CONNECTs onward only to the declared host list
(deny otherwise, decisions audit-logged). That turns the warmer's
"default bridge, whole internet" workaround into
`egress_fqdn("rubygems.org")` with real containment. If the gateway
runtime is further off than a proxy-node tier, an honest alternative is
also acceptable: document `egress_fqdn` as unenforced-on-Linux in
`net_kind`'s table and emit a WARN at `aeo up` so a composition author
knows the boundary is intent-only — the consumer can then keep its
workaround knowingly. Preference: the proxy tier; the WARN merely makes
the gap visible.

### 3. (Smallest) expose the tier decision to `aeo dry-run`

`dry-run` (or `status`) should print, per node, the rendered network
tier and — once (1) lands — the flow whitelist. The consumer surfaces
this in its build records/audit chain; today it can only echo the argv
it happened to construct itself.

## What's NOT being asked

- No new compose setters, no grammar change. `egress`/`egress_fqdn`/
  `ingress`/`deny_egress` as-is.
- No Docker parity requirement — podman-rootless is the consumer's
  substrate (and aeo's live-proven one). If the mechanism happens to
  cover docker, fine; not acceptance-gating.
- No FreeBSD work — pf already enforces per-flow there.
- Not the full CONNECT gateway with TLS/SNI inspection — tier (2) is a
  deny-default host-list proxy, nothing cleverer.
- No aeci-specific anything: the three census sites are motivation; the
  feature is substrate-portability by aeo's own definition (one
  `constrain{}` vocabulary, equal enforcement on both substrates).

## Sequencing note

Priority (1) alone retires aeci's `lib/services` hand-rolled network
path at seam-landing time and closes the any-port hole in every
sidecar-bearing composition aeo runs today, CI or not. (2) retires the
warmer's bridge compromise. (3) is an afternoon. Independent — land in
any order.
