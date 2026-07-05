# The FreeBSD `if_bridge` + pf delivery bug — RESOLVED (it was ipfw, not pf)

> ## ✅ RESOLVED 2026-07-05 on GhostBSD/FreeBSD **14.3-RELEASE-p2** (paul@192.168.0.204)
>
> **The root cause was never `if_bridge`+pf. It was GhostBSD's default-enabled
> `ipfw`.** pf's per-member inter-VM confinement works correctly; the "red axis" was
> a mis-attribution. The whole prior investigation (below) had an unseen confound: a
> second firewall in the pfil path.
>
> **The airtight isolation (minimal 2-vnet-jail repro on a shared `if_bridge`,
> jailA .10 / jailB .20, whitelist .10→.20:6379):**
>
> | pf | ipfw | `pfil_member` | whitelisted flow |
> |----|------|---------------|------------------|
> | ON (whitelist) | **ON** (GhostBSD default) | 1 | ❌ FAILS (SYN never crosses the bridge) |
> | OFF | **OFF** | 1 | ✅ WORKS |
> | **ON (whitelist)** | **OFF** | 1 | ✅ **WORKS** |
> | OFF | ON | 1 | ❌ FAILS (fails even with pf off → proves it's NOT pf) |
>
> The decisive test: **`pfil_member=1` with pf DISABLED still dropped the packet** —
> so pf was never the culprit. GhostBSD ships `ipfw` enabled (`net.inet.ip.fw.enable=1`)
> with a default ruleset that knows nothing about the jail/guest subnet; once
> `pfil_member=1` routes bridged L3 packets through pfil, **ipfw silently drops them**
> (pf counters show zero drops; bridge shows zero Idrop — the packet is passed by pf
> and lost by ipfw). Even a pf `pass all` failed while ipfw was on — ruling out the
> pf ruleset entirely.
>
> **Full acceptance suite PASSES with ipfw off the bridge path + pf per-member whitelist:**
> whitelisted .10→.20:6379 completes ✅; non-whitelisted :9999 blocked (block counter
> Packets:2) ✅; explicitly-passed ICMP works ✅. **The red containment axis is GREEN.**
>
> **The fix aeo needs (not a topology rebuild):** ensure `ipfw` is not filtering the
> guest bridge path. Options, cheapest first: (a) the driver disables ipfw
> (`net.inet.ip.fw.enable=0`) or unloads it when it owns host networking; (b) add an
> ipfw pass rule for the guest subnet; (c) document ipfw-off as a host prereq in
> `bsd-host-setup.md`. NO L3-epair rebuild is required — the shared-bridge + pf
> per-member design works once ipfw is out of the pfil path.
>
> **Corrects the prior FreeBSD-15 (.57) finding**, which reported the same symptom and
> hypothesized an if_bridge return-path bug. That box almost certainly had the SAME
> confound (an active ipfw in the pfil path) — the SYN-ACK-drop / dual-member
> return-path theory below is superseded. Repro versions: FreeBSD 14.3-RELEASE-p2
> GENERIC amd64, pf.ko + if_bridge.ko + ipfw.ko all loaded, `net.link.bridge.pfil_onlyip=1`.

---

_Original investigation (SUPERSEDED — kept for the trail; the "if_bridge return-path"
diagnosis was wrong, confounded by ipfw). Read the RESOLVED banner above first._

A pre-existing aeo networking bug on the GhostBSD box: pf decides correctly but
`if_bridge` fails to carry the verdict onto a bridge member. This is the **one red
containment axis** (LLM.md status table) — host-pf inter-VM confinement does not
bite on FreeBSD. **Directive (Paul): solve it at the host, do not side-step it.**

This plan lives next to the two investigation docs it builds on:
`docs/pf-enforcement-next-steps.md` (the inter-VM filtering symptom) and
`docs/bhyve-networking-journey.md` §"Still open" (the NAT-egress symptom).
Nothing here is connected to the *Beyond Procedure Calls* paper read — that was a
mis-filing; this is plain aeo infra work.

## Why not side-step it (the rejected option)

`pf-enforcement-next-steps.md` line 44 floats "drive confinement at the guest
(resident aeo-agent + guest firewall)." **Rejected.** aeo's premise is *the host
contains the guest*; guest-side enforcement inverts the trust boundary — a
compromised guest could disable its own confinement. Host-pf must do the denying,
the way the Linux per-flow netpolicy already does. (The agent's directionality
reversal is a *containment* property; it is NOT a license to move enforcement
into the guest.)

## 1. The root cause is almost certainly ONE bug, not two

Two symptoms have been chased separately; both docs converge on a single root:
**pf and `if_bridge` do not compose on this FreeBSD 15 box.** Both failures are a
packet pf has correctly *decided on* never being *re-delivered onto a bridge
member*:

- **Inter-VM filtering** (`pf-enforcement-next-steps.md`, behavioral test): with
  `pfil_member=1`, the forward SYN's pass rule matches and creates state, but the
  SYN-ACK is dropped — stateful return-path matching across two bridge members is
  fragile, so even *whitelisted* flows die.
- **NAT egress** (`bhyve-networking-journey.md` lines 149-187): pf holds a correct
  bidirectional NAT state, the reply arrives back at `re0`, but the de-NAT'd reply
  "vanishes between re0-inbound and vm-aeonat-outbound" — never re-routed onto the
  bridge.

Same shape: pf decides correctly, `if_bridge` fails to carry the verdict. Treat
them as one bug; a fix for one is expected to fix the other (that's the
confirmation signal — see §4).

**Ruled out already (don't re-try):** stale kernel (persists on p8), NIC offloads
(TSO/LRO/RXCSUM/TXCSUM), `scrub`, and the pf *rules* themselves (rulegen in
`lib/pf` is unit-tested and correct — the host *delivery* mechanism is broken,
not the ruleset).

## 2. Instrument first — make the drop visible before re-architecting

`pflog0` was never created, so the actual drop has never been *seen*. Don't
rebuild on a hypothesis; prove it:

1. Create a `pflog` interface; add `block log` (and `pass log` on the whitelist)
   so `tcpdump -i pflog0` shows the exact rule + interface at the drop.
2. Discriminate: is the SYN-ACK / de-NAT'd reply **dropped by a pf rule** (→ a
   rulegen bug, fix in `lib/pf`) or **silently lost by `if_bridge` re-delivery**
   (→ the topology bug, fix in §3)? The fix differs; this test decides which.
3. Cheap discriminators to try before the full rebuild:
   - `route-to` / `reply-to` on the per-tap rules (force the return path);
   - `pfil_bridge=1` (filter once on the bridge interface, not per-member).
   If either lets a whitelisted flow complete, the bug is narrowed precisely and
   the fix may be far smaller than a topology rebuild.

## 3. The leading fix — routed / per-VM-epair topology

The single candidate that resolves BOTH symptoms, named independently by both
investigation docs: **stop sharing one L2 `if_bridge` switch; route at L3.**

- Give each VM its **own `epair` + point-to-point link** to the host (or its own
  small bridge), so the host *routes* between guests rather than L2-bridging them.
- pf then filters and NATs on **routed** traffic, where `keep state` works
  normally — no dual-member return-path evaluation, no NAT-reinjection-onto-a-
  bridge step. The two fragile `if_bridge` behaviors are simply off the path.

Scope: this is an aeo **networking-topology** change — the bhyve driver's switch
model (`lib/driver_vm`) + `test/setup-nat.sh`. The pf rulegen (`lib/pf`,
`lib/compose`) stays as-is; what changes is the interface fabric the rules run
on.

## 4. Acceptance — the behavioral suite, unchanged

"Done" only when `pf-enforcement-next-steps.md`'s behavioral suite passes on the
GhostBSD box:

- ✅ allowed whitelisted flow completes (`.51→.50:6379`);
- ❌ non-whitelisted port blocked;
- ❌ third-VM ingress to a peer-restricted port blocked;
- ❌ `deny_egress` node cannot phone home;
- ✅ host→guest ssh survives (control-plane pass).

**Confirmation of the one-bug hypothesis:** if §1 is right, NAT egress (in-guest
`apt`/pull) should start working as a *free side effect* of the topology fix. If
filtering works but egress still fails, they were two bugs after all — keep
digging on egress separately.

## 5. Where this ranks

This is the credibility gap — it turns the honest scorecard from "five of six
axes" to "six of six," and it's the first thing a skeptic attacks. It is
independent of the aeo-agent feature work (that's protocol/recursion; this is
host-FreeBSD-networking), so the two can proceed in parallel — but this is the
higher-priority of the two.
