# test_03_configure

> vasp-configure: round-trip, hand edits survive, nonsense refused

## 1. Definition

Creates a cluster profile from nothing, sets values through flags, regenerates
it, and checks in each case what changed and what did not — including
deliberately invalid input.

## 2. Purpose

The profile is what every generated job script is built from, so a value lost
or corrupted here is a wrong job **everywhere**, silently.

Three specific ways that happens:

1. **A flag that re-detects everything.** `vasp-test` itself tells users to run
   `vasp-configure --debug-max-cores N`. If that regenerated the whole profile
   it would wipe hand-tuned values the user never mentioned.
2. **A regeneration that truncates.** The profile header says *"or edit by hand
   (KEY=value)"*. A wizard that then drops the keys it does not know makes that
   invitation a trap.
3. **A bad value written through.** Covered below; it was real.

## 3. How it is executed

```
tests/run_all.sh test_03_configure
```

Runs `vasp-configure` non-interactively in a scratch `$HOME`, hashing the rest
of the file around each change. Seconds; no VASP, no SLURM.

## 4. Expected results

| check | expected |
|---|---|
| create from nothing | a profile with the expected settings |
| a flag | changes the named value **and nothing else** (hash of the rest unchanged) |
| hand-added key | survives a full regeneration |
| `WP_CHUNK_WALLTIME_MIN` | reachable from the tool (`vasp-relax-loop` reads it) |
| `--show` | reads back what was written |
| empty module list | accepted, and does **not** swallow the next flag as its value |
| `--max-cores 0 / -8 / abc` | refused, profile left at its previous value |

## 5. Obtained results

All twelve as expected; the invalid core caps leave `240` in place.

**One package bug was found here and fixed:** `--max-cores 0`, `--max-cores -8`
and `--max-cores abc` were **written into the profile verbatim**. Followed
downstream, the recommender does not crash on `WP_MAX_CORES="abc"` — it
silently falls back to a default and emits a job script SLURM accepts. So a
mistyped core cap is never applied and **nothing says so**; on a real cluster
that is a job sized outside the allocation. Thirteen numeric flags now refuse
anything that is not a positive whole number, and four fraction flags refuse
anything outside (0, 1].

## 6. Pass / fail criterion

Exact. Any changed byte outside the named key, any lost hand-added key, or any
invalid value reaching the profile, fails the test.

**What is deliberately not validated:** the *values* of physics tags. This
validates cluster parameters — core counts, memory, walltimes — which are
arithmetic, not chemistry. Refusing a physics tag would be this package judging
the user's physics, which it does not do.

## 7. Verdict

**PASSED** — 12 assertions, 0 failed. See `logs/run.log`.

## Sources

None needed: every claim is about this package's own profile format.
