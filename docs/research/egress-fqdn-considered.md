# Egress FQDN filtering in aeo — considered (design, partially built)

**STATUS: PARTIAL BUILD.** The compose/model surface (`egress_fqdn(...)`), the
CONNECT parser/decision core, and the length-aware relay helpers
(`lib/egress_relay`) are built. Runtime gateway enforcement now has the Aether
primitives it needed: length-aware TCP I/O (aether#1079, from aether#1078) and
std.http server tunnel handoff (`http.response_accept_tunnel`, aether#1086).
`lib/egress_gateway` provides std.http-facing CONNECT decision helpers, and
`bin/aeo-egress-gateway.ae` accepts an allowed `CONNECT`, takes ownership of the
accepted connection, opens the upstream socket, and pumps opaque bytes. The
remaining work is integrating that gateway into node networking so
`egress_fqdn(...)` is enforced rather than just available as a standalone
executable.
This note records the reasoning for a layer-7 egress control, what to build, what
to reject and *why*, and the trust invariants that make the hierarchical
(agent-relayed) form sound. Written 2026-07-08 after a design conversation prompted by Jeroen
Soeters' "Towards the dark factory" (Formae's autonomous-agent setup), which
locks agent containers to *"a firewall with an explicit FQDN allowlist … and
nothing else. Everything else is dropped and logged."*

**The realization (§6.5):** the control lowers to a **minimal CONNECT gateway in
aeo-agent, built over `std.tcp`** — decide on the name at the CONNECT line
(fail-closed, no MITM), then splice — which **complements** aeo's already-coded
`allow_egress(ip)` (the L3 floor that makes the gateway unbypassable). The name
decision is built in pure Aether; the opaque byte pump now uses length-aware
`std.tcp.read_n`/`write_n`. The std.http-facing gateway now uses
`http.response_accept_tunnel` from Aether #1086 for the accepted-tunnel handoff.
Concrete build in §8.

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
    egress_fqdn("api.github.com")
    egress_fqdn("api.anthropic.com")
    egress_fqdn("proxy.golang.org")
    egress_fqdn("linear.app")
}
```

Lowers to: **a CONNECT-allowlist gateway** on the parent side of the node's
boundary, the node's default route black-holed, and the node's egress pointed at
the gateway (route + `http_proxy`/`https_proxy`). Everything not on the list is
**dropped and logged**. This enforces the **destination** — the control with
teeth — at low cost (no TLS interception needed for CONNECT).

Early notes assumed Squid/Envoy as a sidecar. §6.5 supersedes that: the first
implementation should be a minimal aeo-agent gateway over `std.tcp`, because the
needed behavior is just CONNECT-line decision + opaque splice.

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
- ❌ **The node, or the node's own child-side agent, owns the filter at runtime.**
  Then a compromised node owns its own door: rewrite the allowlist, disable the
  drop, `curl` around itself. Never do this.
- ✅ **The parent agent may be the gateway for its child.** That gateway is
  outside the child's boundary and controlled by the parent; the child sees only
  "my egress goes to this address" and can no more turn it off than a jail can
  grant itself more rctl. This is the §6.5 realization.

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

## 6.5. The realization: a CONNECT gateway in aeo-agent, over `std.tcp`

The `egress_fqdn` proxy does NOT have to be a Squid/Envoy sidecar, and it does
NOT have to be a full HTTP proxy. The threat model needs exactly one behavior — a
**CONNECT gateway**: read the `CONNECT host:port` line, decide on the *name*
before any bytes flow, then splice the opaque stream. That is buildable **today in
pure Aether**, and it lands the enforcement in aeo-agent itself (the brain,
per §4) without importing a general HTTP-proxy's attack surface (per the
mitmproxy analysis — adopt the *tunnel* behavior, not the MITM stack).

### 6.5a. Why the agent-as-proxy is sound here (and node-as-proxy is not)

Whose agent matters. The **parent's** agent proxying for the **child** node sits
*outside* the node's boundary, on the trusted side — that is the same trust
gradient aeo-agent already runs on ("acts inside, reports outward"). The node's
own in-container process being the proxy would put the filter *inside* the
boundary a compromised node owns → rejected (see §4). So: the gateway is the
**parent-agent's** listener; the node is routed to it and cannot reach around it.

Agent-as-**brain** (owns the name decision + path stamp — its knowledge is
unique) but a **minimal CONNECT relay for the bloodstream** (no HTTP/2/3, no
TLS interception, no content views) — a deliberately dumb, auditable data plane.

### 6.5b. It is NOT `java.exe` that opens the true-endpoint socket

The containment hinges on this. With `https_proxy=http://<agent>:PORT` in the
node, a process (`java.exe`) does **not** connect to `github.com`. It connects to
the **gateway** and sends `CONNECT github.com:443`. The **gateway** (trusted side)
opens the socket to `github.com`, replies `200 Connection Established`, and
splices bytes. The node's processes have **no route to the internet at all** —
their only reachable thing is the gateway. That is *why* it contains, and why the
node never needs (or gets) `allow_egress(githubIP)`.

```
java.exe  --CONNECT github.com:443-->  aeo-agent gateway (parent side)
                                         │ 1. read CONNECT line
                                         │ 2. relay UP to parent, parent STAMPS X-Aeo-Path
                                         │ 3. DECIDE on the name — deny here = fail-closed,
                                         │    BEFORE 200, before a single payload byte
                                         │ 4. resolve github.com -> 140.82.x.x
                                         │ 5. allow_egress(140.82.x.x) on the GATEWAY's egress
                                         │ 6. tcp.connect(140.82.x.x, 443); 200 Established
                                         └ 7. splice opaque bytes both ways (no MITM)
```

The deny is made **on the CONNECT line, before `200`, before the splice** — the
only enforcement moment (post-`200` bytes are opaque TLS, uninspectable by
design, and that is fine: the name decision at connect-time is the whole control
surface because the node has no other route out). At each level up the tree the
relaying parent re-decides on the CONNECT and may deny a host its child approved
(narrow-only, §5b) — the denial lands at CONNECT, so nothing leaks.

### 6.5c. Primitives — length-aware TCP and std.http handoff present

`std.tcp` (aka `std.net`) exposes the control-plane set: `connect`,
`listen`/`accept`, `read`/`write`, `close`, and `fd()`/`server_fd()` (the raw OS
descriptor — its own doc-comment anticipates confined-relay use:
"connect through the stdlib, then narrow the descriptor with `capsicum.rights_limit`
before `capsicum.enter()`"). Since aether#1079, it also exposes length-aware
`std.tcp.write_n(sock, bytes, len)` and `std.tcp.read_n(sock, max) -> (bytes,
len, err)`.

**Empirical gap found during Cut 2, fixed upstream in aether#1079:** legacy raw
TCP was C-string shaped: `tcp_send_raw(sock, data)` sent `strlen(data)`, and
`tcp_receive_raw(sock, n)` returned a NUL-terminated string. That was not a safe
opaque TLS splice: any embedded NUL could truncate the relay. The needed
primitive was length-aware TCP I/O. `lib/egress_relay` now uses those primitives
for `relay_once`/`write_all`.

**std.http runtime path:** `lib/egress_gateway` maps std.http
`request_method` + `request_path` into the relay decision, and
`bin/aeo-egress-gateway.ae` registers a `CONNECT *` std.http route. Rejected
requests still return ordinary 400/403 responses. Allowed requests connect to
the upstream host, call `http.response_accept_tunnel(res)`, and hand both
sockets to a length-aware relay. This is the aether#1086 closure: the gateway no
longer stops at an advisory `200`.

### 6.5d. How this COMPLEMENTS the already-coded `allow_egress(ip)`

They are **stacked layers of one boundary**, not competitors — `allow_egress`
(L3/L4, IP-subject, kernel-enforced) appears at BOTH ends, doing two jobs:

- **On the NODE — the black-hole floor:** `allow_egress(<gateway_ip>)` and nothing
  else. `java.exe` *cannot* open TCP to `github.com` — no route. **This is what
  makes the gateway unbypassable** (kills raw-TCP / QUIC / DNS-tunnel bypass too).
  Existing primitive, doing the hard containment.
- **On the GATEWAY — the resolved-IP pin:** after the name is approved,
  `allow_egress(<resolved_ip>)` on the gateway's own egress — the name→IP bridge
  the DNS-firewall idea in §1 called for.

Neither replaces the other: `allow_egress` alone can't express "github.com" (CDN
IPs are huge/rotating); the gateway alone is bypassed if the node keeps a direct
route. **Together:** the node has no route except the gateway (L3 floor), and the
gateway enforces *names* (L7 decision at CONNECT). The kernel floor makes the
gateway unbypassable; the gateway makes the floor name-aware. Full seal.

---

## 7. Summary of the decision

| item | verdict | why |
|---|---|---|
| **`egress_fqdn(...)`** allowlist | **BUILD** | destination control, from the wire; CONNECT first, no MITM; the 90% |
| **HTTP-method limiting** (GET-only) | **REJECT** | forces MITM *and* GET isn't read-only (body + query-string exfil); can't enforce data-flow with a metadata filter |
| **enforcement site** | parent-owned, node-immutable | the child is untrusted; its parent provisions the boundary and may run the CONNECT gateway outside the child |
| **hierarchy** | each level enforced by the level above | compromised agent narrows below itself, never widens itself — structural |
| **`X-Aeo-Path` context** | **parent-stamped, never child-asserted; narrow-only** | removes attacker-controlled input by construction; ground truth from the wire, identity from the channel |
| **allowed-host exfil** | out of network scope → **credential scoping** | the outer ring can't stop misuse of a sanctioned host; scoped short-TTL creds make a leak survivable |
| **proxy shape** | **minimal CONNECT gateway in aeo-agent over `std.tcp`** | not a Squid sidecar, not a full HTTP proxy; agent = brain (name decision + path stamp), a dumb 2-actor splice = bloodstream; deny at CONNECT, fail-closed, no MITM |
| **relation to `allow_egress(ip)`** | **complements — stacked layers** | node floor `allow_egress(gateway)` makes the gateway unbypassable; gateway pins `allow_egress(resolved_ip)` after approving the name; kernel floor + name-aware gateway = full seal |
| **`tcp_splice` upstream ask** | **filed/fixed as length-aware TCP I/O (aether#1078/#1079)** | not a proxy ask; `lib/egress_relay` now has the small library pump |
| **std.http tunnel handoff** | **built via Aether #1086** | `bin/aeo-egress-gateway.ae` takes ownership with `http.response_accept_tunnel` and pumps bytes with `std.tcp.read_n`/`write_n` |

## 8. First buildable slice (the concrete build)

The proxy is a **CONNECT gateway in aeo-agent over `std.tcp`** (§6.5), not a
sidecar. Build it in cuts that keep every intermediate state testable:

### 8a. Cut 1 — model the declaration, no enforcement yet

Goal: make the operator surface real and inspectable without pretending the
runtime boundary exists.

1. **`lib/compose` grammar.** Add `egress_fqdn(_ctx, host)` as a single-arg
   setter inside `constrain{}`. Aether is fixed-arity, so multiple names are
   repeated calls:

   ```aether
   constrain("agent") {
       egress_fqdn("api.github.com")
       egress_fqdn("api.anthropic.com")
   }
   ```

   Store as netpolicy entries, e.g. `egress_fqdn:api.github.com`, so it rides the
   existing `get_netpolicy()` / status / audit surface.
2. **Parser helpers.** Add cheap helpers in `compose`, not ad hoc downstream:
   `has_egress_fqdn(nm)` and `egress_fqdn_csv(nm)` (or equivalent count/at
   helpers if list iteration is cleaner in Aether). The rule is exact host match
   first; wildcard suffixes are a later explicit design, not implicit globbing.
3. **Renderers stay conservative.** `pf_rules_for()` must not emit a pass rule
   for `egress_fqdn:*`; packet filters cannot enforce it. For now it should still
   emit deny-default blocks, and runner output should say FQDN policy is declared
   but not yet enforced.
4. **Tests.** Add a pure model spec:
   - repeated `egress_fqdn()` calls append stable entries;
   - `describe_tree()` surfaces `net{...}`;
   - `pf_rules_for()` does not turn FQDN names into fake IP rules;
   - Linux `confine_linux.net_kind()` treats FQDN egress as not-open-internet.

This cut is worth landing alone because it fixes the DSL shape and prevents
future runtime code from inventing a second policy store.

### 8b. Cut 2 — gateway library, still not wired to containers

1. **`lib/egress_relay` — DONE for control-plane core and length-aware pump
   helpers.** CONNECT parser and decision helpers exist: extract host/port from
   the first line, exact-match the allowlist, return 200/403/400, and expose
   `relay_once`/`write_all` over `std.tcp.read_n`/`write_n`. Covered by
   `test/spec_egress_relay.ae`.
2. **`lib/egress_gateway` + `bin/aeo-egress-gateway.ae` — DONE for std.http
   CONNECT gateway.** The library maps std.http request fields into the relay
   decision; the executable registers a `CONNECT *` route with `std.http.server`,
   rejects malformed/denied requests with ordinary HTTP responses, and uses
   `http.response_accept_tunnel` for allowed tunnels. Covered by
   `test/spec_egress_gateway.ae` for the std.http decision edge; a local
   embedded-NUL smoke test has also proven the standalone tunnel path.
3. **Wire the gateway into node enforcement.** The standalone gateway exists;
   the next aeo work is provisioning it on the parent side of a node, routing
   `http_proxy`/`https_proxy` to it, and making direct raw egress impossible.
4. **Audit callback.** Log both allow and deny decisions into the aeo audit trail.

### 8c. Cut 3 — rootless Linux container enforcement

1. **Gateway placement.** Start one parent-owned gateway per constrained node, or
   one parent-owned gateway per system with per-node allowlist keyed by source.
   The per-node form is simpler and avoids source-identification ambiguity; the
   per-system form is cheaper later.
2. **Container environment.** Inject `http_proxy`/`https_proxy`/`HTTP_PROXY`/
   `HTTPS_PROXY` pointing at the gateway. Also set `no_proxy` for declared
   peer-only traffic so `egress("db", 6379)` does not accidentally go through an
   HTTP proxy.
3. **L3 floor.** The node must have no direct internet path. For podman this means
   the current `internal` network tier, plus exactly one reachable gateway address.
   Do not ship a gateway-only implementation while the node remains on the shared
   internet-capable network; that is advisory, not containment.
4. **Runner hook.** Add `_enforce_egress_fqdn(nm)` beside `_enforce_netpolicy`.
   The hook should fail closed for `container` nodes once enforcement exists, and
   warn loudly for non-container kinds until their substrate path exists.
5. **Live proof.** On CachyOS/Bazzite: a node with
   `egress_fqdn("api.github.com")` reaches GitHub through the gateway; is denied
   at CONNECT for another host; cannot open a direct socket to GitHub's IP; and
   cannot mutate its own allowlist.

### 8d. Later thickening

Hierarchy + parent-stamped path waits for the aeo-agent http transport's
authenticated single-parent identity (§5b rule 2). Wildcards, DNS-firewall/SNI
modes, non-HTTP raw TCP proxying, and FreeBSD pf table integration are separate
follow-ups. The single-node CONNECT gateway stands without them.

See also `docs/aeo-agent.md` (the recursion / acts-inside-reports-outward model),
`docs/aeo-supervisor.md`, `lib/confine_linux` (where the layer-3/4 confinement
already lives), and `std/tcp` in the aether repo (the relay's primitives).
