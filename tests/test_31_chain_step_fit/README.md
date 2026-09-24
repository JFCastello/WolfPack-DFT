# test_31_chain_step_fit

> the chunk walltime is fixed; a chain that cannot fit one ionic step refuses

## 1. Definition

Launches, runs and resumes chunked relaxations whose ionic steps are too slow
for their chunk walltime, and checks that the chain refuses at the right
moment, with numbers the user can act on.

## 2. Purpose

Every chunk costs a queue wait and a walltime of core-hours. A chunk that
cannot complete one ionic step produces nothing for either, and a chain of
them keeps doing that until someone notices.

The check that was supposed to prevent this could never fire. The launcher
computed the first chunk's step cap, clamped it to at least 1, and only
**then** tested `(( CAP1 < 1 )) && die`. The chain was submitted whatever
the timing said.

The chunk walltime is now chosen once, at launch (from `--walltime`, the queue
study of test_32, or the profile's default), and kept for the whole chain. The
test covers the three moments when one step might no longer fit:

- **at launch**, from the benchmark's estimate;
- **mid-chain**, when a chunk measures its steps growing (for example a cell
  relaxation whose basis grows with the volume);
- **after a walltime kill**, seen by `--resume`.

## 3. How it is executed

```
tests/run_all.sh test_31_chain_step_fit
```

Same harness as test_29 (`tests/chain_harness.sh`). The fake `scontrol`
reports the partition's `MaxTime` from `FAKE_MAXTIME`. The "slow" case edits
the stage-3 state to 200 s per electronic step. About 20 seconds.

## 4. Expected results

The launch estimate of one ionic step, by the chain's own model:

```
CAL   = 200 s × (4/4 ranks) / 0.90 efficiency = 222.2 s per electronic step
T_ION = CAL × 10 electronic steps × 1.15      = 2555.6 s per ionic step
```

A first chunk starts cold, so it must hold `T_ION × 1.5 = 3834 s`. A 60-min
chunk leaves `3600 − 5 min margin − 10 s start-up = 3290 s`. The shortest
walltime that holds the step, `w·60 − max(5, ⌊0.08 w⌋)·60 − 10 ≥ 3834`, is
**70 min**.

| case | expected |
|---|---|
| `--help` | the whole header, including `--no-queue-study` and the last section |
| launch at 60 min | refused; says "not even ONE ionic step"; gives 2555.6 s **and** 3834 s; names `--walltime 70`; nothing rendered, nothing submitted |
| launch at 70 min | accepted: the refusal is exact, not conservative |
| `--walltime 90` on a 60-min `MaxTime` partition | refused, naming MaxTime (a walltime the user asked for is never silently cut) |
| the slow step on that partition, no `--walltime` | refused: no chunk on this partition can hold one step |
| profile default 600 min, `MaxTime` 120 | capped to `02:00:00` (the user did not ask for 600) |
| a chunk measures 4000 s per step (mid-chain) | chain stops with `step_exceeds_chunk`; nothing submitted; the geometry it reached is kept; `STOPPED` gives 4000 and names `--fresh --walltime 83` instead of `--resume` |
| `--resume` tried anyway | refused, naming `--fresh --walltime 83`; nothing submitted |
| walltime kill with **no** step done | `--resume` refuses: "not one ionic step completed" |
| walltime kill after 2 steps of 1500 s | `--resume` continues; walltime unchanged (`01:00:00`); steps per chunk cut to `⌊3290 / (1500 × 1.15)⌋ = 1` |

The 83 min: `4000 s × 1.15 = 4600 s` must fit;
`83·60 − 6·60 − 10 = 4610 ≥ 4600`, while 82 min leaves 4550.

The 1.5 cold-start factor and the 1.15 timing margin are the chain's own
constants (`COLD_FACTOR`, `SAFETY`). The test takes them as given and checks
that the refusals apply them consistently.

## 5. Obtained results

All twenty-three as expected. At launch:

```
[FAIL] not even ONE ionic step fits in a 60-min chunk.
 One step is ~2555.6s (estimated from the benchmark); a first chunk starts cold, so it must hold 1.5 x that: 3834s.
 The chunk leaves 3290s to compute after its 5-min margin and 10s
 start-up, so every chunk would be killed before completing a step.
 The shortest chunk that holds one: 70 min.
 Launch with:   --walltime 70      (or more ranks, for a faster step)
```

After the mid-chain stop, `wolfpack_chain/STOPPED`:

```
reason  : step_exceeds_chunk
detail  : one ionic step now takes 4000.0s; the fixed 60-min chunk leaves 3290s

--resume cannot continue this chain: its chunk walltime (60 min) is
fixed, and one step no longer fits in it. POSCAR holds the geometry reached.
Start a new chain from there, with a chunk that holds one step:
               vasp-relax-loop --fresh --walltime 83
```

Package bugs found and fixed in `vasp_chain.sh`:

1. The one-step check was dead code (above). It is now a real check, done
   before the cap is computed, with the shortest walltime that would work.
2. On a stop about the **next** chunk (`step_exceeds_chunk`,
   `memory_does_not_fit`, the budgets), the chain did not move CONTCAR to
   POSCAR, although **this** chunk had run to completion. The way out of
   such a stop is a new chain (`--fresh`), which starts from POSCAR, so it
   silently redid that chunk's steps. A negative control with the fix removed
   fails the two geometry assertions (here and in test_29).
3. The refusal said "~2555.6s (estimated, with a 1.5x cold-start margin)".
   2555.6 s is the estimate **before** the margin, so the text understated
   what the chunk has to hold by a third. It now prints both numbers.
4. `STOPPED` told the user to `--resume` a chain that `--resume` cannot
   continue.
5. `t_ionic_s` holds the launch estimate until a chunk measures a step. A
   `--resume` before any measurement labelled that estimate "measured" and
   applied the 1.15 margin instead of the cold-start 1.5. A separate
   `t_ionic_measured` flag now records which it is. (Found reading the code
   while fixing 3; no assertion here covers it.)

## 6. Pass / fail criterion

Exact: exit codes, the `#SBATCH --time` line, the step cap, the submission
count, and the walltimes named in the messages (70, 83), each derived by hand
in `check.sh`. No tolerance: every quantity is integer arithmetic on fixed
inputs.

## 7. Verdict

**PASSED** — 23 assertions, 0 failed. See `logs/run.log`.

## Sources

- `MaxTime` is the partition's upper bound on a job's time limit —
  <https://slurm.schedmd.com/slurm.conf.html#OPT_MaxTime>; a job asking for
  more "will be left in a PENDING state (possibly indefinitely)" —
  <https://slurm.schedmd.com/sbatch.html#OPT_time>
- `LSTOP` in STOPCAR ends the run cleanly at the end of the current ionic
  step, which is why a chunk must hold at least one —
  <https://vasp.at/wiki/STOPCAR>
- `LOOP+` in OUTCAR is the time of one ionic step —
  <https://vasp.at/wiki/OUTCAR>
