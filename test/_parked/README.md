# Parked tests / scripts

What remains here needs a **real privileged backend** (FreeBSD + root: a live
bhyve VM or jail bring-up) that the in-tree unit/integration suite can't assume.
Everything that runs unprivileged — including the container-tier specs that
boot real podman/docker nodes — has been **revived into `test/`**. Revive any
remaining item with `git mv test/_parked/<x> test/`.

The apex showcase is the all-in-one demo **`examples/silly_addition_cache.ae`**
(`system { bhyve_vm{ db(redis) } ; bhyve_vm{ app } }`), which both declares the
two-tier system AND self-verifies it via its check/up/smoke/suite modes — that
is the integration-class showcase. The `test/` specs cover the tech *underneath*
it module-by-module (compose/ipam/host/driver_linux/driver_bsd/capsicum).

## Still here (need root + FreeBSD — driven separately, not in run-spec.sh)

- `real_bhyve.ae` — boots an ACTUAL bhyve VM via the driver, checks it's alive
  at the hypervisor level, tears it down. Root + a UEFI bootrom/disk image.
  Provision: `sudo sh setup-bhyve.sh`; run: `sudo /tmp/real_bhyve`.

(`real_jail.ae` was REVIVED into `test/` 2026-06-26 — driver_bsd now self-sudos,
so it no longer needs the binary to run as root; it runs unprivileged + a
populated jail root via `../setup-jail-root.sh`.)

## Scripts (superseded; kept as historical reference)

- `converge-loop.sh`, `converge-nested.sh` — superseded by
  `test/soup-to-nuts.sh` (DSL-driven deploy + curl).
- `setup-bhyve.sh`, `setup-guest.sh` — older provisioning helpers; the live
  prereqs are now `../setup-nat.sh` + `../patch-amd-image.sh` (+ `setup-base.sh`,
  `patch-static-ip.sh`, `setup-jail-root.sh`).

## Revived into test/ (2026-06-24 — was parked under the apex-only narrowing)

- `spec_running_nodes.ae`, `spec_dockerfile.ae`, `spec_integration_app.ae` —
  Aeocha specs that boot REAL containers via `driver_linux` (compute,
  communicate, inline-Dockerfile build, container-in-host HTTP). Skip cleanly
  when no container engine is on PATH.
- `smoke_host.ae` — host-profile probe (BSD/Linux + capsicum/casper booleans).
- `smoke_linux.ae` — `driver_linux` up→probe→health→down against a real engine.
- `smoke_bsd.ae` — `driver_bsd` pure-logic + idempotency (no privilege).

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
