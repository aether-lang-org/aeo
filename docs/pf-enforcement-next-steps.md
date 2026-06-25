# pf netpolicy enforcement — status & next steps

Tracks the remaining work to make the per-VM `constrain{}` netpolicy *actually
confine* traffic on the GhostBSD box. The mechanism is built + proven; what's
left is one deliberate, higher-blast-radius host change.

## UPDATE 2026-06-25: bite-step APPLIED — confinement now armed

The blanket `pass quick on vm-aeonat all` was REMOVED and the deny-default
bite-step pf.conf applied live (verified: fresh ssh still passes, no blanket
inter-VM pass remains, `anchor "aeo/*"` evaluates). Inter-VM traffic now falls
through to each VM's anchor — a flow passes ONLY if a `constrain{}` whitelist
permits it. **Critical fix during apply:** the naive bite config also dropped
`pass all`, which was the ONLY thing permitting inbound ssh on re0 → would have
locked the box out. The applied config carries an explicit
`pass in quick on re0 proto tcp to port 22` + host-LAN passes, so management
survives; deny-default applies ONLY to the vm-aeonat (guest) switch, never re0.

Backups on the box (console rollback, since Paul has kbd/display there):
- `/etc/pf.conf.aeo-bak`  → original NAT-only (pre-anchor)
- `/etc/pf.conf.pre-bite` → anchor wired + blanket pass present (pre-bite)
- Rollback: `sudo pfctl -f /etc/pf.conf.pre-bite` (or `.aeo-bak`)

Remaining: the BEHAVIORAL acceptance test (deploy apex, prove allowed/denied
flows) — now safe to run since console access makes any misstep recoverable.

## Where we are (verified live 2026-06-25, box `paul@192.168.0.57`)

DONE and proven against real `pfctl` (FreeBSD 15, pf Enabled):

- `lib/pf.resolve/apply/flush` — generate deny-default rules, substitute the
  IP-agnostic `$<name>` tokens with ipam IPs, write `/etc/pf.anchors/aeo-<vm>`,
  load via `sudo -n /sbin/pfctl -a aeo/<vm> -f`, flush on teardown.
- The runner calls `_enforce_netpolicy(nm)` after each VM reaches UP, and flushes
  the anchor on `run_down`.
- Sudoers grants verified: `/sbin/pfctl`, `/usr/bin/tee`, `/bin/mkdir`
  (`/usr/local/etc/sudoers.d/aeo-pf`).
- `/etc/pf.conf` **anchor wired**: one line `anchor "aeo/*"` added (backup at
  `/etc/pf.conf.aeo-bak`). Load + read-back of a resolved python_vm ruleset
  round-trips correctly through the kernel.

So `aeo up` will write + load each VM's anchor, and the main ruleset references
it. **What it does NOT yet do: actually deny.**

## Why confinement doesn't bite yet

The box's `/etc/pf.conf` (from `setup-nat.sh`) still has:

```
anchor "aeo/*"               # ← wired (we added this)
pass quick on $int_if all    # ← THE BLOCKER: passes ALL inter-VM traffic, quick
pass out quick on $ext_if all
pass all                     # ← also re-allows anything an anchor blocked
```

`pass quick on vm-aeonat all` short-circuits — a `quick` match is final, so all
VM↔VM traffic passes BEFORE the `aeo/*` anchor is consulted. And the trailing
non-quick `pass all` would re-allow whatever an anchor `block`ed anyway (pf is
last-match-wins). So the anchor is evaluated but never decides anything.

## The bite-step (deferred — has real blast radius)

Make confinement engage by replacing the blanket inter-VM pass with only the
host-control-plane passes, so un-whitelisted inter-VM flows fall through to each
VM's anchor deny.

### Proposed `/etc/pf.conf` (parse-checked `pfctl -nf` → OK on the box)

```
ext_if = "re0"
int_if = "vm-aeonat"
set skip on lo
scrub in all
nat on $ext_if from 172.16.0.0/24 to any -> ($ext_if)

# host control-plane on the NAT switch — quick, final (DHCP/DNS to the gateway,
# host-originated ssh/anything to guests). NOT a blanket inter-VM pass.
pass quick on $int_if proto udp from any to 172.16.0.1 port { 53 67 }
pass quick on $int_if proto { tcp udp } from 172.16.0.1 to any
pass out quick on $ext_if all

# per-VM netpolicy: each aeo/<vm> anchor whitelists its flows + blocks the rest.
# Evaluated for inter-VM traffic that the control-plane passes above didn't take.
anchor "aeo/*"

# un-confined VMs (no anchor) still reach OUT via NAT; inter-VM defaults to the
# anchor deny. (Tighten further later if desired.)
pass out on $ext_if all
```

### Apply procedure (safe + reversible)

1. **Only when no guests are mid-deploy** (the change can interrupt running
   guest connectivity on the NAT switch; the host's own LAN reachability on
   `re0`/192.168.0.57 is unaffected).
2. `scp` the new file to `/tmp/pf.conf.bite`, then on the box:
   ```
   sudo pfctl -nf /tmp/pf.conf.bite          # parse-check, no apply
   sudo cp /etc/pf.conf /etc/pf.conf.pre-bite # extra backup
   sudo cp /tmp/pf.conf.bite /etc/pf.conf
   sudo pfctl -f /etc/pf.conf
   ```
3. **Rollback (one command):** `sudo pfctl -f /etc/pf.conf.aeo-bak`

### Behavioral acceptance test (the actual proof of confinement)

With the bite-step applied and the apex (`silly_addition_cache`) deployed:

- ✅ ALLOWED: from python_vm, `nc -z db_vm 6379` succeeds (whitelisted egress).
- ❌ DENIED: from python_vm, reach db_vm on a NON-whitelisted port → blocked.
- ❌ DENIED: a THIRD VM hitting db_vm:6379 → blocked (peer-restricted ingress).
- ❌ DENIED: from db_vm (deny_egress), any outbound → blocked (no phone-home).
- ✅ host→guest ssh still works (control-plane pass).

Only when those pass is enforcement "done".

## Open design question (Paul, 2026-06-25): avoid global /etc/pf.conf entirely?

Paul is uneasy about aeo's confinement living in the host's shared `pf.conf`.
Alternatives worth weighing before committing to the bite-step:

- **Dedicated aeo bridge** with its OWN default-deny policy, separate from the
  host NAT switch — aeo owns that bridge's pf entirely; the host pf.conf stays
  untouched.
- **Per-tap filtering** — apply rules at each VM's tap interface rather than a
  shared switch ruleset.
- **Keep the single `anchor "aeo/*"` line** (already done, minimal, permanent)
  but never touch the rest of pf.conf — accept that the operator owns the
  blanket-pass removal as a one-time posture decision.

The current state (anchor wired, blanket pass intact) is a safe resting point:
aeo loads real rules, nothing is broken, and confinement is one deliberate
operator step away — to be taken after the design question is settled.
