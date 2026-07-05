# `aeo extract` / `aeo inventory` — reality → code

Brownfield adoption: point aeo at a host someone else (or ClickOps) set up, and get a
composition you can then `up` / `watch` / `apply-node`. Day 0 is optional.
(Formae-envy item 2; see `docs/formae_vs_aeo.md`.)

## `aeo extract`

Walks the host's LIVE containers (`podman ps` + `inspect`) and prints a valid aeo
composition (`.ae`) to **stdout** that would reproduce them:

```sh
aeo extract > extracted.ae      # capture it
aeo dry-run extracted.ae         # it re-parses + plans (round-trip proven)
```

Each node carries:
- `image(...)` + `command(...)` (the `/bin/sh -c` wrapper aeo adds at up-time is
  stripped, so the command round-trips), `expose(...)` for a published port;
- `limit(){ limit_mem limit_maxproc }` — only for caps actually set (memory rendered
  back to a human string, `134217728` → `128M`; podman's default `PidsLimit=2048` is
  omitted — it's not a declared cap);
- **`attest("sha256:...")` pre-filled with the image's CURRENT digest.** This is the
  containment win Formae has no analog for: extraction doubles as an **attestation
  baseline**. Re-`up` the extracted composition and aeo verifies (fail-closed) that
  the image hasn't drifted from what was running when you extracted.

Diagnostics go to stderr, so `aeo extract > file.ae` yields clean `.ae`. Review before
`up` — extract captures what's running, not intent (no `depends()` edges are inferred;
that's a documented follow-up).

## `aeo inventory`

The same live walk rendered as a **table** (name, image, memory). Given a composition,
it adds a **`DECLARED`** column — which running containers that composition manages vs
which it doesn't. The coexistence story in one screen:

```
$ aeo inventory mystack.ae
NAME                 IMAGE                                    MEM        DECLARED
cache                docker.io/library/alpine:latest          128M       yes
web                  docker.io/library/alpine:latest          0          yes
strayproxy           docker.io/library/nginx:latest           0          no
```

`strayproxy` is running but not in `mystack.ae` — surfaced immediately.

## Round-trip proven

Live on podman 6 (CachyOS): `up` a known 2-node composition → `aeo extract` → the
emitted `.ae` re-parses and `aeo dry-run` plans both nodes back; the `attest()` digests
are the real image shas; caps and expose survive; podman defaults are not fabricated.

## Scope (v1) and follow-ups

- **container kind only** — the walk uses the podman/docker inspect surface. jail
  (`jls`), lxc (`lxc-ls`), bhyve (`virsh`/`vm list`) extract are follow-ups.
- **no `depends()` inference** — edges can't be observed reliably; extract emits nodes
  flat (order is declaration order). A future pass could add `// TODO depends(...)`.
- Pairs naturally with the reconcile work: extract a live tree, then `aeo watch` /
  `aeo apply-node` keep it true.
