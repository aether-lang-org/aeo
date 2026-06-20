# aeo

**Infrastructure orchestrator** — stand up and tear down a deliberate tree of
VMs and containers (FreeBSD jails + bhyve, Linux LXC/Docker + KVM) from a
single Aether composition script:

```
aeo compose.ae
```

aeo is **not** a build system and **not** an aeb SDK. It is a third sibling to
[`aether`](https://github.com/aether-lang-org/aether) (the language) and
[`aeb`](https://github.com/aether-lang-org/aeb) (the build runner). aeo is
*built by* aeb and can shell *to* aeb at runtime, across a plain artifact + CLI
seam. Its DSL philosophy is inherited from the ecosystem — **config IS code**,
closure-with-setters, no YAML — applied to live infrastructure.

> Status: **design phase.** No implementation yet. See
> [`aeo-design.md`](./aeo-design.md) for the full design, the division of
> labor vs aeb, host-adaptation / capability-gating (Capsicum fast-fail), and
> the open decisions (front-door model, resource-handle model).

## The one-line distinction

| | does | invocation |
|---|---|---|
| **aeb** | build the tree (static DAG of artifacts) | `aeb target:name` |
| **aeo** | stand the tree up and keep it coherent (live lifecycle) | `aeo compose.ae` |

## Host adaptation

aeo adapts to whether the host is BSD or Linux, and **fast-fails** when grammar
can't be honored — e.g. requesting Capsicum enforcement on a host without it.
It consumes Aether's `std.capsicum` / `std.casper` `available()`-probe contract
(the `feat/freebsd-sandbox-parity` branch) rather than reinventing host
detection. See the design doc.
