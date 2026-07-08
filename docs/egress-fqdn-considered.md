# Egress FQDN filtering in aeo — considered (design, not yet built)

**STATUS: DESIGN.** Nothing here is built yet. This note records the reasoning
for a layer-7 egress control (`egress_fqdn(...)`), what to build, what to reject
and *why*, and the trust invariants that make the hierarchical (agent-relayed)
form sound. Written 2026-07-08 after a design conversation prompted by Jeroen
Soeters' "Towards the dark factory" (Formae's autonomous-agent setup), which
locks agent containers to *"a firewall with an explicit FQDN allowlist … and
nothing else. Everything else is dropped and logged."*

The motivating threat: an agent container feeds attacker-influenceable text
(issue bodies, PR comments) through an LLM **that holds live credentials**. A
prompt injection then tries to **exfiltrate those credentials**. aeo already
enforces the layer-3/4 boundary (`constrain{ egress / ingress_from /
deny_egress }` → pf anchor / iptables). This note is about the **layer-7 name
seam** aeo doesn't express yet.

---

## 1. Why a packet filter cannot do this (the "how is that even possible")

A classic firewall (pf, iptables, a security group, a NACL) sees **IP + port**,
not names. By the time a SYN reaches it, DNS already resolved and the FQDN is
gone. You cannot pin the allowlist to IPs either: `github.com`,
`api.anthropic.com`, `*.amazonaws.com` sit behind **CDNs / cloud LBs** whose IP
sets are enormous, shared with unrelated origins, and rotate constantly. An IP
allowlist is both **leaky** (whitelisting a Fastly/CloudFront range admits a
million other sites) and **brittle** (breaks on rotation).

So "FQDN allowlist" necessarily means one of:

1. **An egress proxy the node is forced through** (the primary, high-value form).
   The node has **no route to the open internet**; its only pinhole is a forward
   proxy. The name survives to the proxy in cleartext:
   - **HTTP `CONNECT`** — for HTTPS the client sends `CONNECT github.com:443`
     *before* the TLS handshake. The proxy reads the host, checks the allowlist,
     opens or refuses the tunnel. (Note Formae's list is all HTTPS API
     endpoints — GitHub, Anthropic, Codex, Linear, the Go module proxy, AWS.)
   - **TLS SNI** — even without terminating TLS, the `ClientHello` carries the
     Server Name in cleartext; an inline device allows/denies on it.
2. **A DNS-firewall** — the node is forced onto a controlled resolver; only
   allowlisted names resolve (else NXDOMAIN), or the firewall watches DNS answers
   and briefly permits egress to *the IP that name just resolved to* (AWS Network
   Firewall stateful domain lists; Cilium FQDN policies; Squid `dstdomain`).

Both terminate at a control the **node cannot reach** — that is the property
that makes the allowlist enforceable rather than advisory, exactly like a pf
anchor the node can't flush.

---

## 2. What to BUILD: `egress_fqdn(...)`

A `constrain{}` modifier that names the permitted destinations:

```
constrain {
    egress_fqdn("api.github.com", "api.anthropic.com",
                "proxy.golang.org", "linear.app")
}
```

Lowers to: **a CONNECT/SNI-allowlist forward proxy** (Squid/Envoy) on the node's
network, the node's default route black-holed, and the node's egress pointed at
the proxy (route + `http_proxy`/`https_proxy`). Everything not on the list is
**dropped and logged**. This enforces the **destination** — the control with
teeth — at low cost (no TLS interception needed for CONNECT/SNI).

This is the 90%. Build this first.

---

## 3. What to REJECT: HTTP-method limiting ("GET-only for select FQDNs")

Tempting middle option; **rejected as security theater.** Two independent
reasons, either fatal:

**(a) It forces TLS MITM.** For HTTPS the method is *inside* the TLS stream. To
allow `GET` and drop `POST` per-FQDN the proxy must **terminate TLS** (hold a CA
the node trusts, decrypt, inspect, re-encrypt). That's heavy, fragile
(cert-pinning clients break), trust-laden (a decrypt point that now sees every
token), and a per-image CA-distribution burden.

**(b) The premise is false — GET is not read-only.** HTTP defines GET as *safe*
and *idempotent*, but those are **semantic promises the server makes**, not
properties the method **enforces**. As an exfil channel a GET is a fine pipe:
- **GET carries a body** (RFC 9110 permits it; curl `--data`, fetch-with-body
  send the bytes regardless). The secret rides in the body of a "GET."
- **GET carries a query string** — kilobytes of attacker-chosen data in the URL:
  `GET https://allowed-host/?x=<base64-token>`. The method filter waves it
  through because the *verb* is allowed; the *payload* is the point and it never
  looked.
- **Even a bodyless GET to an allowed host exfiltrates** via that host's access
  logs / analytics if the attacker can read them.

The verb was a **proxy for "this request only reads,"** and that proxy doesn't
hold. A prompt-injected agent isn't bound by REST etiquette — "make it a GET" is
one flag. Worse, the hosts you'd most want to restrict are exactly the ones that
**require** the dangerous verb: GitHub push and the Anthropic/Codex APIs are
`POST`; GraphQL is *all* `POST`. Method is a useless discriminator where it
matters.

**General principle (worth stating once):** you cannot enforce a *data-flow*
property ("don't leak") with a *metadata* filter (method — and only partly even
host). The controls that actually bind exfil are: **deny the destination**
(§2, the allowlist — teeth), **content inspection** (DLP; real but an arms race,
needs MITM, defense-in-depth only), and **deprive the secret of value**
(credential scoping — §5).

---

## 4. WHERE it is enforced: parent-provisioned, node-immutable

The agent is **the untrusted thing in the blast radius** (it's what the injection
runs inside). So the enforcement point must be something the agent **cannot
reach at runtime**. Two shapes of the same rule:

- ✅ **The agent PROVISIONS the boundary at bring-up.** aeo-agent's role is
  *"bring my node up locally … acts inside, reports outward."* Standing up the
  egress proxy + drop-route is part of bringing a node up *securely* — the same
  category as `_enforce_netpolicy` / `_enforce_limits` in `lib/aeo/runner.ae`. The
  agent does it from **outside** the node, with the authority it holds *as the
  parent-of-this-node*, then reports the boundary established outward. Fine.
- ❌ **The agent IS the proxy / owns the filter at runtime.** Then a compromised
  agent owns its own henhouse door: rewrite the allowlist, disable the drop,
  `curl` around itself. Never do this. The proxy is a **sidecar the parent
  controls**; the node sees only "my egress goes to this address" and can no more
  turn it off than a jail can grant itself more rctl.

Because the runner and every nested agent **share the driver path** (the header
of `bin/aeo-agent.ae`: *"the driver calls are the SAME ones the runner uses"*),
this is built **once** at the driver + enforcement-hook layer and both the runner
(depth-0) and every agent (depth-N) get it for free. So:

- `lib/confine_linux` — add the `egress_fqdn` lowering (provision the
  CONNECT-allowlist sidecar on the node's network; set the node's egress
  route/`http_proxy`; default-drop the rest).
- `lib/aeo/runner.ae` — add `_enforce_egress_fqdn(bn)` beside
  `_enforce_netpolicy(bn)`, called at the same node-promotion point.
- `bin/aeo-agent.ae` — gains **nothing bespoke**; it inherits via the shared
  driver. (Putting it *in* the agent as a distinct feature would be redundant
  and, if it meant agent-as-proxy, dangerous.)

---

## 5. HIERARCHY: each level's egress is enforced by the level above it

The invariant that makes the recursive (nested-agent) case sound:

> **A compromised agent at depth N can misconfigure the boundaries it provisions
> for its children (below it), but can NEVER widen its own egress.** Its own
> filter is owned by its parent, one level up.

This is the reason the enforcement site is "parent-provisioned": it makes that
invariant **structural** rather than something you carefully arrange each time.

### 5a. Two ways to realize it

**(A) Parent-provisioned LOCAL sidecar (recommended default).** Each node's
proxy runs on its own subnet; the **allowlist is handed DOWN by the parent at
bring-up** and is immutable from inside the node. Fast (no extra hops), no apex
bottleneck, blast radius local. Cost: N sidecar configs, distributed by the
parent.

**(B) Chained relay / egress concentrator.** The node sends a **bare** request;
the agent **tunnels it OUT to its parent**, who relays to *its* parent, up to the
apex, which holds the real allowlist and makes the actual call. Enforcement lives
above the untrusted party by construction; policy centralizes; ancestor-visible
path enables policy a local sidecar can't express. Costs: **latency** (depth-K
hops per request), the **apex is a throughput bottleneck + SPOF**, and fetch-heavy
agent work multiplies both.

They compose: **use (A) for the data path** (enforcement, fast) but let **(B) be
the *policy-distribution* channel** — the parent hands the child its allowlist,
the sidecar logs the verified path outward. Parent-controlled policy without
routing every byte through the apex.

### 5b. Containment-path context — **parent-stamped, never child-asserted**

The richest version annotates each relayed/logged request with the node's
**containment path** (`root/db/app`), its identity, its depth — for path-aware
allow/deny and for audit. This is valuable **only if done safely**, and there is
exactly one safe way:

> **The parent stamps `X-Aeo-Path`; the child never touches the field.**

The child sends a bare `CONNECT host:443` — no self-description. The parent, which
is relaying it, **adds the path itself**, because the parent knows two things the
child cannot forge: (1) *which* child this is — it arrived on this authenticated
connection / per-agent `AEO_TOKEN`, and the parent *launched* that child so it
knows its node name; (2) its *own* path. The parent computes `my_path +
child_segment` and stamps it; the next hop up prepends *its* segment. The full
path **assembles segment-by-segment, each written by the party one level above
the segment it describes.** By the apex, every element was written by someone the
apex trusts more than the child.

Why this beats child-embellishment: it **eliminates** the attacker-controlled-
input problem instead of mitigating it. If the child asserted the header, it
would be a claim the parent must remember to distrust — one forgotten check and
the injection walks through wearing a compliant path (the "trust the JWT claims
without verifying the signature" mistake). Parent-stamped, **the child cannot
even express a false path** — the field isn't in its outbound vocabulary. The
property holds by construction, like a pf anchor the node can't reach.

Two rules keep it honest:

1. **Ground truth from the wire, annotation for narrowing only.** The FQDN
   checked against the allowlist is read from the `CONNECT`/SNI the parent is
   relaying — never from a header. The stamped path may move a decision from
   *allowed* → *denied* (extra restriction) but **never** *denied* → *allowed*.
2. **Identity is bound by the channel, not asserted in a header.** The parent
   knows which child is talking by the authenticated connection / token it
   arrived on, not by `X-Aeo-Node`. So the load-bearing requirement is: **each
   agent authenticates to its parent as itself, and the parent stamps against
   that authenticated identity.** This rides on an auth property aeo-agent
   already owes (its header notes the http transport will *"fail-closed —
   single-parent security"*) — it consumes that guarantee, it doesn't add a new
   one. Without it, a child could get itself stamped with a *sibling's* path.

---

## 6. The residual hole (unchanged by any of the above): allowed-host misuse

None of this fixes exfil **through an allowed host**. GitHub is on the list, so an
injected agent can push a branch / open a gist / write a PR comment containing the
secret — all to an *allowed* FQDN, a legitimate-looking `CONNECT github.com:443`.
The allowlist stops **novel** destinations, not misuse of **sanctioned** ones.

The answer is not more network filtering — it is **§5's credential scoping, one
layer up**: per-turn, least-privilege, short-TTL credentials (a `contents:read`
GitHub token, a minimal IAM role, secrets only from a manager). Leaking a token
that is read-only and expires in minutes is *survivable* — which is why Formae's
"per-turn, least-privilege" line is the strongest layer, and why the network wall
is the *outer* ring, not the whole defense. This is arguably **not aeo's job** to
mint (it's the composition author's / the platform's), but it **is** aeo's job to
build the boundary (subnet + drop-route + proxy) that *forces* traffic through the
point where those scoped creds are the only lever.

---

## 7. Summary of the decision

| item | verdict | why |
|---|---|---|
| **`egress_fqdn(...)`** allowlist | **BUILD** | destination control, from the wire; CONNECT/SNI, no MITM; the 90% |
| **HTTP-method limiting** (GET-only) | **REJECT** | forces MITM *and* GET isn't read-only (body + query-string exfil); can't enforce data-flow with a metadata filter |
| **enforcement site** | parent-provisioned, node-immutable | the agent is the untrusted party; it provisions the boundary, is never *in* the data path |
| **hierarchy** | each level enforced by the level above | compromised agent narrows below itself, never widens itself — structural |
| **`X-Aeo-Path` context** | **parent-stamped, never child-asserted; narrow-only** | removes attacker-controlled input by construction; ground truth from the wire, identity from the channel |
| **allowed-host exfil** | out of network scope → **credential scoping** | the outer ring can't stop misuse of a sanctioned host; scoped short-TTL creds make a leak survivable |

## 8. First buildable slice (when we build it)

1. `egress_fqdn(...)` verb in `lib/compose` (records the allowlist per node).
2. `confine_linux` lowering: provision a Squid/Envoy CONNECT-allowlist sidecar on
   the node's podman network; black-hole the node's default route; set
   `http_proxy`/`https_proxy` + route to the sidecar. Default-drop + log.
3. `_enforce_egress_fqdn(bn)` hook in `lib/aeo/runner.ae`, beside
   `_enforce_netpolicy`. The agent inherits it via the shared driver path.
4. Live-prove on CachyOS: a node with `egress_fqdn("api.github.com")` reaches
   GitHub, is dropped+logged reaching anything else; verify the node **cannot**
   alter its own allowlist (immutability check).
5. Hierarchy + parent-stamped path is a later thickening (needs the aeo-agent
   http transport's authenticated single-parent identity first — see §5b rule 2).

See also `docs/aeo-agent.md` (the recursion / acts-inside-reports-outward model),
`docs/aeo-supervisor.md`, and `lib/confine_linux` (where the layer-3/4
confinement already lives).
