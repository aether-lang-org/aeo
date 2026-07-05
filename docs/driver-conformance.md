# Driver conformance kit

Formae ships a plugin-conformance suite so any provider plugin can prove it honors
the plugin contract. aeo's substrates are compiled-in drivers, but they share a
**uniform contract** — every driver exposes `name()` / `up` / `down` / `probe` /
`exec_capture`. This kit turns the `examples/silly_addition_*` substrate grid from a
*showcase* of parity into a **contract** for it: a new driver is "done" only when it
passes here. (Formae-envy item 4; see `docs/formae_vs_aeo.md`.)

## Two layers

### 1. Contract-shape — `test/spec_driver_conformance.ae` (pure, runs anywhere)

Whole-imports all seven substrate drivers + the fail-loud stub and asserts:

- **the shape compiles** — a driver missing `up`/`down`/`probe` would fail to build
  this spec, so a green build IS the shape proof;
- **`name()` is non-empty and DISTINCT** across the fleet (a collision would make the
  kind→driver routing ambiguous);
- **the stub is fail-loud** — `driver_stub.up` returns an error, `driver_stub.probe`
  returns 0 (never falsely "up").

This already earned its keep: it caught `driver_stub.probe` returning a **malformed
tuple** instead of the uniform `-> int` every real driver returns — a latent bug that
had escaped notice because nothing imported the stub until this kit. Fixed to match
the contract.

Run: `sh test/run-spec.sh test/spec_driver_conformance.ae`

### 2. Behavioral — `test/conformance-behavioral.sh` (host-gated, live)

The `create → probe-healthy → confinement-present → stop → VERIFY-GONE` lifecycle,
run **through the real `aeo` front-door** (not raw podman/jail), so it proves the aeo
contract end to end. Parameterized by substrate:

```sh
AEO_HOME=/path/to/aeo sh test/conformance-behavioral.sh <aeo-binary> <substrate>
#   substrate = container | jail
```

Five stages, each PASS/FAIL:
1. **create** — `aeo up` the one-node confined composition;
2. **probe-healthy** — the node is live (podman ps / `jls`);
3. **confinement present** — the declared cap is on the LIVE resource (podman
   `.HostConfig.Memory` = 134217728 for `limit_mem("128M")`; rctl for a jail);
4. **stop** — `aeo down`;
5. **verify-gone** — the node is provably absent (aeo's teardown guarantee).

## Status

- **container arm: PASSES live** on podman 6 (CachyOS): created+running,
  confinement flag present (128M cap), verify-gone — all through `aeo up`/`down`.
- **jail arm: PASSES live** on GhostBSD/FreeBSD 14.3 (2026-07-05): `aeo up` creates
  the zfs dataset + jail, probe reports it running, the rctl `memoryuse` cap aeo
  applied is present (`rctl jail:jnode` → `memoryuse:deny=268435456`), `aeo down`
  removes it and verify-gone confirms absence — all through the real front-door.
  Prereqs on the host: a jail rootfs on the dataset (base.txz-populated, not an empty
  zfs dataset — point `AEO_CONF_JAIL_DATASET` at it), and NOPASSWD sudo for
  `jail`/`jls`/`jexec`/`zfs`/`rctl` (see `bsd-host-setup.md`). Not CI (needs a
  prepared FreeBSD box + the ae toolchain built there — see memory
  `ae-toolchain-build-freebsd`).
- **other substrates** (lxc, bwrap, nspawn, firecracker, bhyve) — the harness pattern
  extends the same way as the drivers gain a testable seam; do a new substrate's
  conformance run as its definition-of-done (the doc's rule: run this before adding a
  sixth substrate).
