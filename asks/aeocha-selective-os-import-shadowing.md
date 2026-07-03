# Ask: selective `import std.os (x)` shadows whole-module `os.foo()` → breaks aeocha

**Status:** root-caused + workaround in hand. Not an aeocha bug — an Aether
import-resolution behaviour. Filed for the ae/aeocha maintainer (aeb-sibling) to
decide whether the compiler should change, or aeocha should document the constraint.

## Symptom

A spec that `import aeocha` AND `import std.os (getenv)` (selective) fails to build
against ae 0.351 (and 0.341) the moment it uses any aeocha HTTP/timing helper:

```
error[E0301]: Undefined function 'os.now_monotonic_ns'
  --> spec.ae:343:38     (inside aeocha.ae, the qualified os.now_monotonic_ns() calls)
```

aeocha (aeocha.ae:53) does whole-module `import std.os` and calls
`os.now_monotonic_ns()`, `os.now_monotonic_ms()` etc. qualified.

## Root cause (minimal repro)

Whole-module qualified access works alone:

```aether
import std.os
import std.string (string_from_int)
main() { println("${string_from_int(os.now_monotonic_ns())}") }   // BUILDS
```

But add a SELECTIVE import of the same module in the SAME compilation unit:

```aether
import aeocha                 // does `import std.os` + calls os.now_monotonic_ns()
import std.os (getenv)        // <-- selective import of std.os
...
```
→ `os.now_monotonic_ns` is now Undefined. The selective `import std.os (getenv)`
appears to REBIND the `os` namespace in the unit to ONLY the selected name
(`getenv`), so every other `os.*` qualified call (aeocha's) no longer resolves.

## Workaround (spec-side, applied to aeo's example checks)

Do NOT selectively import a module you also use whole. Either:
- `import std.os` (whole) + call `os.getenv(...)` qualified, OR
- avoid the selective form entirely in any file that imports aeocha.

```aether
import aeocha
import std.os                 // whole — coexists with aeocha's os.* calls
_base() -> string { return os.getenv("AEO_APP_HOST") }   // qualified
```

## The real question (for the maintainer)

Should the compiler MERGE a selective import into the existing whole-module binding
(so `import std.os` + `import std.os (getenv)` = whole + a convenience unqualified
`getenv`), rather than REPLACING it? That'd make the two forms composable. Until
then, aeocha users must avoid selective imports of `std.os` (and likely any module
aeocha imports whole). Worth a one-line note in aeocha's README either way.
