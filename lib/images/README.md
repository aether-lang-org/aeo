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

## How well each works (measured on the GhostBSD/bhyve box, 2026-06-22)

Cold-provisioned each from its image; checked boot, network (static IP on the
aeonat switch), and ssh reachability. Honest results — not guesses:

| Recipe | Image | Boot | Network | SSH | Verdict |
|---|---:|:---:|:---:|:---:|---|
| **ubuntu_24_04_minimal_podman** | **251MB** | ✅ ~6s | ✅ netplan | ✅ | **BEST — full drop-in, reachable end-to-end. Recommended slim default.** |
| ubuntu_22_04_minimal_podman | 294MB | ✅ ~6s | ✅ netplan | ❌ | works; cloud-init didn't seed ssh key (needs offline key injection) |
| debian_12_podman | 333MB | ✅ ~18s | ✅ netplan* | ❌ | boots+nets (genericcloud ships netplan!); same ssh-seed gap; heavier |
| alpine_3_20_podman | **194MB** | ✅ | ❌ | ❌ | smallest, but OpenRC/ifupdown — no netplan, never gets static IP. Needs a new realizer branch. Deferred. |
| ubuntu_22_04_podman (standard) | 695MB | ✅ | ✅ | ✅ | the original full base; works fully (has a repaired golden) |

\* debian-12 genericcloud unexpectedly ships `/etc/netplan`, so our static-IP
netplan applied — the feared networkd gap didn't bite for networking.

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
