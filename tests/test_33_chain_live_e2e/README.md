# test_33_chain_live_e2e

> vasp-relax-loop for real: the pipeline, a real VASP, a real SLURM; each chunk's estimate against the time it used

## 1. Definition

Relaxes silicon with one atom displaced, twice: once in a single direct VASP run
(the reference), and once through the whole pipeline — `vasp-dry-run`,
`vasp-recommend-slurm`, `vasp-test --full-size`, then `vasp-relax-loop` with
NSW = 2 per chunk on the suite's SLURM testbed, until VASP reports "reached
required accuracy". It compares the two results, checks the plumbing between
chunks, and records how close each chunk's estimate came to what it used.

## 2. Purpose

test_36 proves the chain's decisions against a fake scheduler and a fake VASP.
This proves what those decisions rest on: that a real OUTCAR and OSZICAR say
what the estimator reads, that a real vasp-test leaves the files the chain
needs, that a chunk can submit its successor from inside a real job, and that
chaining changes the answer by nothing.

It also measures the thing the design is for: the walltime each chunk asks for,
against the time it actually took.

## 3. How it is executed

```
bash tests/slurm_testbed.sh start
tests/run_all.sh test_33_chain_live_e2e
```

Needs VASP, the Si POTCAR (`$WP_POTCAR_DIR`) and the testbed; skips without them.
Si, 2 atoms, atom 2 at (0.77, 0.76, 0.75), 6×6×6 k-points, IBRION = 2,
EDIFFG = −0.01, 4 ranks (as the reference; on this 4-core laptop 8 ranks are
5× slower per step). About 20 minutes.

## 4. Expected results

| check | expected |
|---|---|
| the reference | converges in one run |
| stage 2 | a layout (4 ranks) |
| vasp-test --full-size | keeps its OUTCAR and OSZICAR; measured at the production rank count; its start-up time not clamped to 0 |
| the chain | launches, and converges on VASP's "reached required accuracy" |
| plumbing | every chunk starts from the CONTCAR of the one before; the folder's POSCAR is the input, its CONTCAR the last chunk's; no chunk runs out of walltime or memory |
| the estimate | the electronic steps of each chunk's first ionic step never under-estimated by more than the 2-step margin |
| the answer | the chain and the direct run agree: \|ΔE\| < 2 meV, max \|Δr\| < 0.01 Å |

## 5. Obtained results

```
  chunk try NSW  ionic geoms  e-steps/ionic    est.e   estimate  asked      used     energy (eV)  max|F|  result
      1   1   2      2     2  11 6                11    0:02:23   0:08   0:01:48      -10.806882  0.5881  ok
      2   1   2      2     3  11 6                11    0:01:48   0:08   0:01:35      -10.819998  0.1471  ok
      3   1   2      2     4  11 4                11    0:01:35   0:07   0:01:51      -10.820686  0.0490  ok
      4   1   2      2     5  11 3                11    0:01:51   0:08   0:01:30      -10.820764  0.0150  ok
      5   1   2      2     6  11 2                11    0:01:30   0:07   0:00:43      -10.820772  0.0047  CONVERGED
```

- **The answer:** \|ΔE\| = 1×10⁻⁶ eV, max \|Δr\| = 0.0003 Å against the direct run.
- **The cost:** the direct run took 6 ionic steps. The chain computed 6 distinct
  geometries in 5 chunks, 10 SCF runs, because each chunk's first step repeats
  the last geometry. In this case NSW = 2 did not add ionic steps.
- **The electronic-step estimate was exact:** 11 estimated, 11 taken, for every
  chunk's first ionic step.
- **The time estimate** is that count times the seconds per electronic step, and
  this laptop does not repeat itself. VASP's own LOOP lines give **2.5 to 9.4 s
  per electronic step** across the chunks for the same work. Used/estimate went
  from 0.48 to 1.17. The walltime's × 1.15 + 5 min absorbed it: no chunk ran
  out. On an earlier run the spread was 4.4 to 17.1 s and the worst chunk used
  1.55 × its estimate, absorbed the same way. An estimate from the chunk before
  can be no more precise than the machine is repeatable. On a cluster with
  dedicated nodes this should be much tighter, but it was not measured here.
- **vasp-test's start-up: 8.7 s.** It is the benchmark's wall time minus the
  steps VASP timed, so it includes the step VASP was in when it was stopped: an
  upper bound, never below the real start-up.

**A package bug this test found on its second run.** The start-up came out
0.0 s. vasp-test measured the benchmark's wall time with a one-second clock:
90 s, against 90.26 s of steps in the OUTCAR, so the difference was −0.26 s and
was clamped to 0. The first run had passed by luck of the rounding. The
interval is now measured to the nanosecond.

The first version of this test asserted "used ≤ estimate × 1.15". It failed on
chunk 1 because of the machine, not the method, and it now asserts what the
method controls (the electronic-step count) and reports the time.

**A package bug this test found, that the fake harness could not.**
`vasp_relax_loop.sh` was created without its execute bit. The job it renders
ran it with `exec '…/vasp_relax_loop.sh' --chunk-body`, so the first real chunk
died with `Permission denied`, and the chain stalled "queued". The job now
runs it through `bash`, and the file is executable. test_36's harness now runs
the submitted job script itself (it used to call the chain directly). Against
the old line and mode it fails 31 of 49.

## 6. Pass / fail criterion

The plumbing, exactly. The electronic-step estimate, within the 2-step margin
it adds by design. Energy within 2 meV and structure within 0.01 Å of the direct
run: far outside the EDIFF/EDIFFG noise (1e-6 eV, 0.01 eV/Å), far inside any
real difference.

## 7. Verdict

See `logs/run.log`.

## Sources

- EDIFFG < 0: stop when all forces are below |EDIFFG| — <https://vasp.at/wiki/EDIFFG>
- CONTCAR is the last geometry computed: measured here with VASP 6.5.1 (see
  test_36)
- `sbatch --signal`: <https://slurm.schedmd.com/sbatch.html#OPT_signal>
