# Parked tests / scripts

Set aside while the focus is the apex spec **`test/spec_nested_system.ae`**
(the max-complexity example: `system { bhyve_vm { db(redis) ; app } }`).
Everything here is a strict *subset* of what that spec exercises. Nothing here
is deleted lightly — revive any of it with `git mv test/_parked/<x> test/`.

(Pre-Aeocha hand-rolled `demo_*`/`integration_app` versions and the broken
`spec_capsicum.ae` were DELETED — superseded, see below.)

## Still here (valid Aeocha specs / probes — narrower, not stale)

- `spec_running_nodes.ae`, `spec_dockerfile.ae`, `spec_integration_app.ae` —
  Aeocha specs for simpler tiers (real containers compute/communicate;
  inline-Dockerfile build; container-in-host HTTP). Subsets of the apex.
- `smoke_*.ae`, `real_*.ae` — driver/host smoke + root-required real
  bring-up probes (thin / few assertions).

## Scripts (superseded; kept as historical reference)

- `converge-loop.sh`, `converge-nested.sh` — superseded by
  `test/soup-to-nuts.sh` (DSL-driven deploy + curl).
- `setup-bhyve.sh`, `setup-guest.sh` — older provisioning helpers; the live
  prereqs are now `setup-nat.sh` + `patch-amd-image.sh` (+ `setup-base.sh`,
  `patch-static-ip.sh`, `setup-jail-root.sh`).

## Deleted (superseded — listed so the history is clear)

- `spec_capsicum.ae` — BROKEN (called the removed `get_confined_by()`) and
  superseded by a whole suite of live Capsicum/containment specs:
  `test/spec_capsicum_breakout.ae` (the 4 escape classes x 2 layers),
  `spec_capsicum_bhyve_model.ae` (DSL grant_fd grants -> kernel enforcement),
  `spec_capsicum_jail_selfreport.ae` (self-report from a FreeBSD jail),
  `spec_capsicum_bhyvevm_selfreport.ae` (self-report from a FreeBSD bhyve-VM),
  `spec_containment_linux_vm.ae` (VM-boundary containment of a Linux guest).
- `demo_nested_system.ae`, `demo_running_nodes.ae`, `demo_dockerfile.ae`,
  `demo_agent.ae`, `integration_app.ae` — pre-Aeocha hand-rolled
  (`check()/exit()`) versions, each replaced by an Aeocha BDD `spec_*`.
