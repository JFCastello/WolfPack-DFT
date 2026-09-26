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
EDIFFG = −0.01, 4 ranks, as the reference. A few minutes.

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

With the defaults since 2026-09-26 (the WAVECAR carried, × 1.25 + 5 min) and
VASP on 4 real MPI ranks:

```
  chunk try NSW  ionic geoms  e-steps/ionic    est.e   estimate  asked      used     energy (eV)  max|F|  result
      1   1   2      2     2  11 6                11    0:00:30   0:06   0:00:28      -10.806882  0.5881  ok
      2   1   2      2     3  2 6                 11    0:00:29   0:06   0:00:17      -10.819997  0.1471  ok
      3   1   2      2     4  2 4                 11    0:00:32   0:06   0:00:15      -10.820685  0.0491  ok
      4   1   2      2     5  2 3                 11    0:00:34   0:06   0:00:15      -10.820764  0.0151  ok
      5   1   2      2     6  7 2                 11    0:00:30   0:06   0:00:15      -10.820772  0.0048  CONVERGED
```

- **The answer:** \|ΔE\| = 1×10⁻⁶ eV, max \|Δr\| = 0.0003 Å against the direct run.
- **The cost:** the direct run took 6 ionic steps. The chain computed 6 distinct
  geometries in 5 chunks, 10 SCF runs, because each chunk's first step repeats
  the last geometry. In this case NSW = 2 did not add ionic steps.
- **The carried WAVECAR** made a chunk's first ionic step 2 electronic steps,
  three chunks running, then 7 (11 without it). The 7 came from a WAVECAR that
  VASP wrote for the very CONTCAR the chunk started from; reproduced by hand,
  the same 7. So a carried chunk's first step is estimated as a cold start
  (11, chunk 1's): never short, and those chunks used about half their
  estimate. Estimating it from the chunk before, as the first run with the new
  default did, fell 5 steps short at chunk 5.
- **The time:** VASP's LOOP lines give 0.9 to 3.0 s per electronic step across
  the chunks. Chunk 1, the only one estimated from vasp-test, used 0.93 of its
  estimate.
- **vasp-test's start-up: 1.6 s.** It is the benchmark's wall time minus the
  steps VASP timed, so it includes the step VASP was in when it was stopped: an
  upper bound, never below the real start-up.

**What the earlier runs of this test measured was not this.** Until
2026-09-26 the testbed's `slurm.conf` had no `MpiDefault`, and VASP here is
Open MPI with PMIx: `srun` started 4 separate 1-rank copies of VASP, all writing
one OUTCAR. The direct run, launched with `mpirun`, was right; every
`srun`-launched one, vasp-test's benchmark and every chunk, was not. The
answers still agreed, because each copy computed the same thing. But the
"4.4 to 17.1 s per electronic step" once put down to this laptop was four
copies sharing its cores, and a start-up that came out 0 was their interleaved
OUTCAR lines summing to more than the wall time, not the one-second clock first
blamed for it (the clock now reads nanoseconds anyway). The testbed sets
`MpiDefault=pmix` now, and vasp-test fails a benchmark whose OUTCAR reports
fewer ranks than `srun` started (test_28).

**A package bug this test found on 2026-09-26.** The chain's state file
(`chain.env`) lost keys: `chain_carry`, `chain_safety`, `chain_kind` and a
dozen more. A chunk that completes submits the next and goes on writing it; on
the testbed the next chunk starts at once and writes it too, and with no lock
and one shared temporary file, each truncated the other's copy. Two writers in
a test lost all 40 keys of 40. `state_set` now takes a lock (a file created
with noclobber: `mkdir` is not exclusive on this laptop, whose `mkdir` is the
Rust uutils 0.8.0), and each writer has its own temporary file. test_36
checks it.

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
