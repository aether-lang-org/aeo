# Ask: aeocha `expect_str(<fn returning a freshly-built string>)` is a use-after-free

**Status: RESOLVED + CONFIRMED CONSUMED (aeo side, 2026-07-04).** Fixed in aeocha
`707ab9b` — `expect_str(v)` now captures `string.copy(v)` (aeocha.ae:1224), the exact
fix this ask proposed. aeo-side re-verified: the minimal repro (a built `${d}/vmlinux`
string) now PASSES on `ae 0.353` with the current `../aeocha`. The held string sites
are being re-swept to `expect_str`/`to_equal_str` (the string-half of the fluent
migration this ask blocked). Thanks — clean fix, and the regression guard in
`example_self_test.ae` means it won't regress.

Original status (for context): reproduced minimally on `ae 0.353`; blocked the
fluent-facade spec sweep for string assertions (int/bool assertions were
unaffected).

## Symptom

`expect_str(f()).to_equal_str(want)` where `f()` returns a **freshly constructed**
string (interpolated / concatenated, heap-allocated, freed after the call) reads
GARBAGE at comparison time:

```
FAIL: expected '/srv/mvm/vmlinux', got '޽V'
FAIL: expected '/srv/mvm/rootfs.ext4', got 'uTBV'
```

## Minimal repro (ae 0.353)

```aether
import aeocha
import driver_firecracker (kernel_path)   // kernel_path(d) = "${d}/vmlinux" — a BUILT string
import std.string
main() {
    fw = aeocha.init()
    aeocha.describe(fw, "x") {
        aeocha.it("y") callback {
            aeocha.expect_str(kernel_path("/srv/mvm")).to_equal_str("/srv/mvm/vmlinux")  // FAILS: got garbage
        }
    }
    aeocha.run_summary(fw)
}
```

## What works vs what doesn't (the tell)

- `expect_str("literal").to_equal_str("literal")` — OK (literal lives in rodata).
- `expect_str(list_get_raw(av, 0)).to_equal_str("run")` — OK (ptr into a persistent
  list; the string outlives the assertion).
- `expect_str(kernel_path(...)).to_equal_str(...)` — **FAILS** (the returned string
  is freed after the call; `StrSubject { value: v }` holds a dangling ptr).

So it's specifically: `StrSubject` stores the string BY REFERENCE and does not
copy/retain it, so a caller-owned temporary that's freed before `.to_equal_str`
runs is a UAF. `expect_int` is immune (int is value-copied) — confirmed.

## Likely fix (aeocha side)

`expect_str(v)` should COPY `v` into the `StrSubject` (aeocha already imports
`std.string`; a `copy`/`string_concat(v,"")` at capture time). Compare
`assert_str_eq`, which takes the string and compares immediately in the same call —
no lifetime gap — which is why the verbose form never hit this.

## aeo-side handling meanwhile

The fluent sweep migrates ALL int/bool assertions (`assert_str_eq(string_from_int
(x),…)`, `assert_eq`, `assert_true` → `expect_int(...).to_be_truthy/falsy/equal`) —
those are safe. String-equality sites where the arg is a FUNCTION CALL returning a
built string are LEFT as `assert_str_eq` until this is fixed. (`expect_str` on a
literal or a list_get_raw ptr is safe and may be used.) Re-sweep the held sites once
`expect_str` copies.
