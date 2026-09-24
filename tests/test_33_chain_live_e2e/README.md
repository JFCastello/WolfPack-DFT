# test_33_chain_live_e2e

> a real chunked cell relaxation: real VASP, real scheduler, memory measured per chunk

## 1. Definition

Runs a short chunked relaxation of silicon, with a real VASP, on the suite's
real SLURM testbed, from launch to convergence. Then checks that the chain
crossed a chunk boundary, that every chunk measured its own memory, and that
the next chunk's request was rewritten from that measurement.

## 2. Purpose

Tests 29–32 prove the chain's **decisions**, against a fake scheduler and a
fake VASP that say exactly what the test tells them to. This test proves the
**plumbing** those decisions depend on:

- that a real OUTCAR contains the memory line the chain reads;
- that a real `sacct` answers the way the chain expects, or fails in a way it
  handles;
- that a chunk can edit its successor's job script and submit it from inside
  a running job, on a real scheduler.

A fake cannot catch a wrong assumption about any of those, because the fake
was written with the same assumption.

## 3. How it is executed

```
bash tests/slurm_testbed.sh start
export SLURM_CONF=/tmp/wpslurm/slurm.conf
tests/run_all.sh test_33_chain_live_e2e
```

Needs VASP (`$WP_VASP`), the Si POTCAR from `$WP_POTCAR_DIR`, and the
testbed's `slurmctld`; it skips cleanly without any of them. It takes about two
minutes.

The input is Si in the diamond cell, strained 3 % and with one atom displaced,
so there is something to relax. The INCAR is `ISIF = 3`, `IBRION = 2`,
`EDIFFG = −0.01`, `ENCUT = 400`, and `ISYM = 0`: as the atom returns, the
symmetry would rise and change NKPTS between chunks, which the chain rightly
refuses to restart across. The run uses 4 ranks and starts at 1000 MB/cpu.
Chunks are 8 min long, which leaves 3 min of VASP after the 5-min margin: short
enough that the relaxation needs more than one chunk.

## 4. Expected results

| check | expected |
|---|---|
| launch | exit 0 |
| outcome | `wolfpack_chain/FINISHED` (converged), within 15 min |
| chunk boundaries | at least 2 chunks in `chain.log` |
| memory measured | the `peakMB` column filled for every chunk |
| where it came from | a real source (`sacct` or OUTCAR), not "not measured" |
| request rewritten | `chain_mem_per_cpu ≠ 1000` |
| never below the peak | `chain_mem_per_cpu ≥ mem_peak_max_mb` |
| structure record | `chunk-001/POSCAR.in.gz` (the whole-chain diff of `vasp-check` reads it) |

What the memory should come down *to* is not asserted: it depends on the VASP
build, the MPI library and the machine. The rule itself is exercised with exact
numbers in test_29.

## 5. Obtained results

All eight as expected, on 2026-09-24:

```
# idx  jobid  kind   cap  used  t_step  elapsed  frac  peakMB  reqMB verdict    detail
  1    1562   RELAX    3     3    15.7       52  0.29      72   1000 CONTINUE   3/3 ionic steps, max|F|=0.2218
  2    1563   RELAX    6     5    10.1       52  0.29      72    300 CONVERGED  reached required accuracy after 5 ionic step(s)
```

- **Memory source: OUTCAR (rank 0).** The testbed's `sacct` lists the job
  steps as `COMPLETED` but with `MaxRSS` and `AveRSS` empty, so the chain fell
  back to VASP's own figure: 72 MB for rank 0. Why the testbed records no RSS
  was not established. Its `slurm.conf` does set
  `JobAcctGatherType=jobacct_gather/linux`, but it runs unprivileged with
  `proctrack/pgid`. Real clusters differ, which is why the chain handles both.
- **Request: 1000 → 300 MB/cpu.** 72 × 1.25 = 90 MB is below the chain's
  floor of 256 MB, and rounding up to 50 MB gives 300. With OUTCAR alone,
  every rank is assumed to be as heavy as rank 0.
- **Converged in 2 chunks,** 8 ionic steps in total.

Two package problems were found by this test and fixed:

1. **Every chunk waited 45 s for accounting data that would never come.** The
   chain polled `sacct` for `MaxRSS` for up to 45 s. Where steps are recorded
   without memory, as on this testbed, the answer never changes, and every
   chunk paid the full wait. The chain now stops polling as
   soon as all steps are in a finished state: a step's usage is reported
   together with its completion, so a finished step with no `MaxRSS` does not
   get one later. On the testbed, `MaxRSS` was still empty 20 minutes after the job
   ended. Were that ever wrong on some cluster, the cost is small: the chain
   uses OUTCAR's rank-0 figure for every rank instead, which errs toward more
   (rank 0 is normally the heaviest). `job_mem_evidence` on the first run's job went from 45 s to 0 s.
   The fake `sacct` of tests 29–32 now answers like this testbed when a test
   gives it no data.
2. **The progress message counted the wrong steps.** A relaxation chunk
   reported `not converged yet (25/60 steps)`: electronic steps over NELM, in
   a run with NSW = 30. It now reports ionic steps against NSW; in this run:
   `not converged yet (3 ionic step(s) in this chunk, 3 of 30 done)`.

## 6. Pass / fail criterion

Convergence within the deadline, and the inequalities above. The values
themselves are machine-dependent and are reported, not asserted.

## 7. Verdict

**PASSED** — 8 assertions, 0 failed. See `logs/run.log` and `logs/chain.log`.

## Sources

- OUTCAR's memory lines are rank 0's (VASP labels them "MPI-rank0") —
  <https://vasp.at/wiki/OUTCAR>
- `MaxRSS`/`AveRSS` come from the `JobAcctGatherType` plugin —
  <https://slurm.schedmd.com/slurm.conf.html#OPT_JobAcctGatherType>
- `ISYM = 0` switches symmetry off, so NKPTS cannot change as the structure
  becomes more symmetric — <https://vasp.at/wiki/ISYM>
- `ISIF = 3` relaxes ions, cell shape and cell volume —
  <https://vasp.at/wiki/ISIF>
