# Parked tests / scripts

Set aside while the focus is the apex spec **`test/spec_nested_system.ae`**
(the max-complexity example: `system { bhyve_vm { db(redis) ; app } }`).
Everything here is a strict *subset* of what that spec exercises, or an
older/superseded form. Nothing is deleted — revive any of it with
`git mv test/_parked/<x> test/` when you circle back.

- `demo_nested_system.ae` — the old hand-rolled (`check()/exit()`) version
  of the apex, superseded by `spec_nested_system.ae` (Aeocha BDD).
- `spec_running_nodes.ae`, `spec_dockerfile.ae`, `spec_integration_app.ae` —
  Aeocha specs for simpler tiers (real containers compute/communicate;
  inline-Dockerfile build; container-in-host HTTP). Subsets of the apex.
- `demo_agent.ae`, `demo_dockerfile.ae`, `demo_running_nodes.ae`,
  `integration_app.ae` — pre-Aeocha hand-rolled versions.
- `smoke_*.ae`, `real_*.ae` — driver/host smoke + root-required real
  bring-up probes (thin / few assertions).
- `converge-loop.sh`, `converge-nested.sh` — superseded by
  `test/soup-to-nuts.sh` (DSL-driven deploy + curl).
- `setup-bhyve.sh`, `setup-guest.sh` — older provisioning helpers; the live
  prereqs are now `setup-nat.sh` + `patch-amd-image.sh` (+ `setup-base.sh`,
  `patch-static-ip.sh`, `setup-jail-root.sh`).
