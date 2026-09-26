# test_35_steptime

> how long the next chunk takes: an ionic step measured, or extrapolated from a cut-off SCF

## 1. Definition

Feeds `wolfpack_steptime.sh`, the estimator behind `vasp-relax-loop`'s walltimes,
OUTCARs and OSZICARs built from the numbers of real VASP 6.5.1 runs of this suite
(silicon and bcc iron, 4 ranks). It checks the electronic steps it predicts for an
ionic step that was cut off, the cases it refuses to extrapolate, and the
arithmetic of a chunk's estimate.

## 2. Purpose

`vasp-relax-loop` asks for the smallest walltime a chunk needs. If the estimate is
short, the chunk is killed and retried. If it is long, it waits longer in the
queue. Chunk 1 is the hard case: `vasp-test` usually stops inside the first ionic
step, so the steps it still needed are unknown and must be extrapolated.

The traps:

- the first 5 electronic steps (`NELMDL = -5` without a WAVECAR) keep the
  Hamiltonian fixed. Their `dE` falls to 7e-7 and then jumps back to 0.13. Read
  as convergence, they would give a step that is "almost done";
- an SCF that is not converging has no line to follow;
- VASP converges on `|dE|` and `|d eps|` together
  ([EDIFF](https://vasp.at/wiki/index.php/EDIFF)); a fit on one alone stops early;
- a metal's slow tail near EDIFF (iron) makes a straight fit fall short.

## 3. How it is executed

```
tests/run_all.sh test_35_steptime
```

About 1 s. No VASP, no scheduler: the fixtures hold the real runs' numbers
(`dE`, `d eps` per step, `LOOP`/`LOOP+` times), and only those lines.

## 4. Expected results

| case | expected |
|---|---|
| real silicon, first ionic step (11 electronic steps), cut at step 8 | 8 done + 3 to reach EDIFF (the fit over steps 6–8 falls 1.04 decades a step) + 2 margin = **13** |
| cut at step 5, inside the delay (`dE` already 7e-7) | **NELM (60)**, with "too few to extrapolate" |
| cut at 8, 9, 10 | 13, 14, 14: never below the 11 it took |
| real iron (15 steps), cut at 8 … 14 | never more than 2 below 15 |
| an SCF whose `max(|dE|,|d eps|)` does not fall | NELM, "not converging" |
| `NELMDL = 0` (a WAVECAR was read) | no step skipped: 3 + 3 + 2 = 8 |
| `RMM:` and `CG :` lines | read like `DAV:` |
| chunk 1 from vasp-test: 13 steps × 2.0 s + 2.0 s for the forces, NSW = 2, start-up 10 s | 10 + 28 + 28 = **66 s**; walltime 66 × 1.15 → 2 min + 5 = **7 min** |
| the next chunk from the real silicon run (LOOP+ 28.24, 14.93, 14.53, 10.13, 8.21, 5.87 s; wall 84 s) | start-up 84 − 81.91 = 2.1 s; 2.1 + 28.24 + 10.7 = **41.0 s**; "reached required accuracy" seen |
| the same, when the next chunk carries a WAVECAR (a cold start took 11 steps) | the first step as a cold start: 11 × 2.0 + 10.331 (the median of LOOP+ − ΣLOOP) = **32.3 s**; **45.1 s** in all |
| a retry: one step completed (16.8 s), the next cut after 3 | the completed one measured, the cut one extrapolated (3 + 3 + 2 = 8 steps × 2 s + 0.8 s); 5 + 16.8 + 16.8 = **38.6 s** |

## 5. Obtained results

All thirteen as expected. Silicon cut at 8, 9, 10: 13, 14, 14 (it took 11). Iron cut
at 8 … 14: 14, 16, 15, 15, 15, 16, 17 (it took 15): at worst 1 step short.

**Why a margin of 2 steps.** Chosen on 46 cut-off points of 10 real VASP runs in
this suite (Si, Al, Fe, a magnetic case; every ionic step, cut at every point with
at least 3 self-consistent steps):

| extrapolation | fell short | worst | mean overshoot |
|---|---|---|---|
| the fit alone | 14 of 46 | −4 steps (−44 %) | +10 % |
| **+ 2 steps** | **3 of 46** | **−2 steps (−22 %)** | **+24 %** |

The fit window (the last 3, 4, 5 points, or all) changed little; the margin
changed a lot. What is left is covered by the walltime's × 1.25 (the default) and 5 minutes, and
past that by the retry. These are small systems. A hard SCF (a large magnetic
oxide, a slab) may converge less regularly; the live test (test_33) and the
progress file's estimate/used columns are where that would show.

## 6. Pass / fail criterion

Exact: step counts, seconds, minutes. Iron: at most 2 steps under.

## 7. Verdict

**PASSED** — 13 assertions, 0 failed. See `logs/run.log`.

## Sources

- EDIFF: the SCF stops when the total energy change and the band-structure
  energy change are both below it — <https://vasp.at/wiki/index.php/EDIFF>
- NELMDL: non-self-consistent steps at the start, −5 without a WAVECAR, 0 with
  one; negative = first ionic step only — <https://vasp.at/wiki/index.php/NELMDL>
- NELM: the most electronic steps of one ionic step — <https://vasp.at/wiki/index.php/NELM>
- OSZICAR columns (N, E, dE, d eps) — <https://vasp.at/wiki/index.php/OSZICAR>
