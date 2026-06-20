# Upstream Aether bug: heap-string message field retained in actor state corrupts

**Found by:** aeo (first real consumer of the actor model for long-lived
stateful resources), 2026-06-20, against `ae 0.291.0`.

**Status:** worked around in aeo; should be filed/fixed upstream. aeo is
the downstream pressure to land the fix (per aether/LLM.md's "downstream
finds the gaps" dynamic).

## Symptom

An `actor` that stores a **string** message field into a **state field**
and reads it back in a *later* message gets corrupted memory — the state
field dangles after the originating message is freed.

Minimal repro:

```aether
import std.config
message SetN { in_n: string }
message Show {}
actor A {
    state n = ""
    receive {
        SetN(in_n) -> { n = in_n }          // retain message string in state
        Show -> { println("n=${n}") }        // read it in a later message
    }
}
main() {
    a = spawn(A())
    a ! SetN { in_n: "aeo-db" }
    sleep(100)
    a ! Show {}                              // prints garbage, e.g. "C\<bytes>^"
    sleep(100)
    wait_for_idle()
}
```

Expected `n=aeo-db`; actual `n=C\�^` (freed-memory bytes).

## Second bug (the obvious workaround also fails)

The natural fix — a defensive copy `n = string_concat(in_n, "")` — hits a
**separate codegen bug**: the generated C references an undeclared
`_heap_n` inside the actor's receive function:

```
error: '_heap_n' undeclared (first use in this function)
```

So neither "retain directly" nor "retain a copy" works for a string in
actor state today.

## What DOES work (aeo's workaround)

A message string is valid for the **duration of the handler that receives
it**. So: never hold a string in actor state. Stash it into the
process-global KV (`std.config`) inside the receiving handler, key it by a
name the message also carries, and re-read it from config in later
handlers. The actor keeps only **ints** in state.

```aether
message SetN { in_key: string, in_n: string }
message Show  { in_key: string }
actor A {
    receive {
        SetN(in_key, in_n) -> { config.put(in_key, in_n) }   // stash while live
        Show(in_key)       -> { v = config.get(in_key); println("n=${v}") }
    }
}
```

This prints `n=aeo-db` correctly. aeo uses exactly this shape: every
lifecycle message carries the resource name, the actor holds only the
boot/probe int counters, and all per-resource string config lives under
`aeo.cfg.<name>.*` in `std.config`.

## Fix direction (for the upstream patch)

A string message field retained into actor state needs its refcount bumped
on the `state = field` assignment (or the state field needs to own a copy),
and the `string_concat`-into-state codegen path needs the `_heap_<field>`
temp declared. Likely in the actor receive-function codegen + the
heap-string lifetime tracker's handling of state-field assignment.
