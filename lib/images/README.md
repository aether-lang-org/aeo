# lib/images — slim/fast guest recipes (measured)

One recipe per file; the filename names the image. Each is imported + called to
register an `image_recipe`, then a composition just names the logical image:

```
import images.ubuntu_24_04_minimal_podman (ubuntu_24_04_minimal_podman)
aeo_orchestration() {
    ubuntu_24_04_minimal_podman()
    system("x") { bhyve_vm("vm") { guest_image("ubuntu-24.04-minimal+podman") ... } }
}
```

The apex demo `examples/silly_addition_bhyve_podman.ae` reads the guest image from
`AEO_GUEST_IMAGE` (default `ubuntu-24.04-minimal+podman`), so the SAME demo runs
the whole permutation set below — e.g.
`AEO_GUEST_IMAGE=debian-12+podman AEO_MODE=check ae run examples/silly_addition_bhyve_podman.ae`.
`driver_vm` resolves the base-image URL from the part before `+`, so any name in
this table works without importing its recipe (the recipe only adds the
golden-clone fast path + systemd/netplan layers).

## How well each works (measured on the GhostBSD/bhyve box, 2026-06-22)

Cold-provisioned each from its image; checked boot, network (static IP on the
aeonat switch), and ssh reachability. Honest results — not guesses:

```
The slim guest recipe set (all in lib/images/, with measured status)

┌────────────────────────────────┬───────┬──────┬─────┬─────┬─────────────────────────────────────────────────────────┐
│             Recipe             │ Image │ Boot │ Net │ SSH │                         Verdict                         │
├────────────────────────────────┼───────┼──────┼─────┼─────┼─────────────────────────────────────────────────────────┤
│ ubuntu_24_04_minimal_podman    │ 251MB │  ✅  │ ✅  │ ✅  │ BEST — full drop-in, reachable end-to-end               │
├────────────────────────────────┼───────┼──────┼─────┼─────┼─────────────────────────────────────────────────────────┤
│ ubuntu_22_04_minimal_podman    │ 294MB │  ✅  │ ✅  │ ❌  │ works; ssh-key seed gap                                 │
├────────────────────────────────┼───────┼──────┼─────┼─────┼─────────────────────────────────────────────────────────┤
│ debian_12_podman               │ 333MB │  ✅  │ ✅  │ ❌  │ boots+nets (ships netplan!); ssh gap                    │
├────────────────────────────────┼───────┼──────┼─────┼─────┼─────────────────────────────────────────────────────────┤
│ alpine_3_20_podman             │ 194MB │  ✅  │ ❌  │ ❌  │ smallest, but OpenRC → no static IP; needs new realizer │
├────────────────────────────────┼───────┼──────┼─────┼─────┼─────────────────────────────────────────────────────────┤
│ ubuntu_22_04_podman (standard) │ 695MB │  ✅  │ ✅  │ ✅  │ the original, fully working                             │
└────────────────────────────────┴───────┴──────┴─────┴─────┴─────────────────────────────────────────────────────────┘
```

Notes: 24.04-minimal boots in ~6s, debian ~18s. debian-12 genericcloud
unexpectedly ships `/etc/netplan`, so our static-IP netplan applied — the
feared networkd gap didn't bite for networking.

### Takeaways
- **ubuntu-24.04-minimal is the winner**: 64% smaller than standard jammy
  (251 vs 695MB) and the ONLY slim option that's reachable with zero extra work
  — its cloud-init seeded our ssh key where the others didn't.
- The common gap for 22.04-minimal/debian is **cloud-init not installing the
  ssh key** over our bhyve seed path (boot+network are fine). Fix = bake
  authorized_keys into the disk offline, exactly like `patch-static-ip.sh` does
  for the netplan. Then those become full drop-ins too.
- **Alpine** is the smallest but genuinely costs a second init-system realizer
  (OpenRC/ifupdown/apk). ~100MB saved over 24.04-minimal isn't worth that yet.

See memory: aeo-lighter-guest-minimal, aeo-image-recipe-realizer.
