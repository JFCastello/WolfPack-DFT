# test_29_chain_memory

> every chunk measures its memory and rewrites the next chunk's request

## 1. Definition

Runs a chunked relaxation (`vasp-relax-loop`) against a scripted scheduler and
a scripted VASP, feeds each finished chunk a known memory measurement, and
reads the `#SBATCH` lines of the job script the chain submits next.

## 2. Purpose

Until this change a chain took `--mem-per-cpu` once, from
`slurm_vasptest.sh`, and kept it for every chunk. It timed every chunk
carefully and never looked at how much memory one used. Two things follow:

- a request that was too small killed **every** chunk the same way;
- a request that was too large was paid for in queue time on **every**
  resubmission — and a chain resubmits many times.

The test pins down the rule that replaces it, and the cases where the rule has
to do more than scale a number: a node that can no longer hold the ranks, a
chunk lighter than an earlier one, a cluster with no accounting, a cell that
grows, a request no node can satisfy, and a `--stop`/`--resume` in between.

## 3. How it is executed

```
tests/run_all.sh test_29_chain_memory
```

`tests/chain_harness.sh` replaces `sbatch`, `squeue`, `sacct`, `scontrol` and
`srun` with small fakes: `srun` is a Python stand-in for VASP that writes an
OSZICAR, OUTCAR, CONTCAR and XDATCAR as told; `sacct` answers with the rows the
test writes for each job. The chain script itself — `vasp_chain.sh` and the
chunk body it renders — is the real one. The fake cluster has 8-core nodes of
16000 MB, a 5-minute chunk margin and a 32-core cap. About 15 seconds.

## 4. Expected results

The rule comes from how SLURM enforces memory: the limit is on the **job's
total on each node** (`cgroup.conf`, `ConstrainRAMSpace`), not on each task.
The heaviest node holds rank 0 (the `MaxRSS`) plus the other ranks at the mean
(`AveRSS`), so the request per CPU is

```
need = (MaxRSS + (ntpn − 1) × AveRSS) / ntpn × 1.25     rounded up to 50 MB
```

where 1.25 is the chain's headroom (`WP_CHAIN_MEM_SAFETY`).

| case | input | expected |
|---|---|---|
| shrink | 2000 granted; 1500 peak / 1000 mean, 4 ranks per node | (1500 + 3·1000)/4 × 1.25 = 1406 → **1450**; the chunk reports `3 ionic step(s) in this chunk, 3 of 60 done` |
| grow and spread | 5000 / 4000 at 4 per node → 5350 MB/cpu = 21400 MB, node usable 15680 | **2 nodes × 2** ranks, still **4** ranks, recomputed at 2 per node: 9000/2 × 1.25 = **5650** |
| the peak is kept | a later chunk measures 1000 / 800 | request stays **5650**; `mem_peak_max_mb` stays 5000 |
| no accounting | `sacct` has the steps, finished, but no `MaxRSS`; OUTCAR says 2 097 152 kB | every rank assumed as heavy as rank 0: 2048 × 1.25 = 2560 → **2600**; the chunk says the figure came from OUTCAR; it does not sit out the 45-s `sacct` poll (< 30 s) |
| ISIF = 3 | 2000 / 2000; the cell grew 9.27 % in volume (3 steps at +1 % per axis) | 2500 × 1.0927 = 2732 → **2750** |
| cannot fit | 20000 MB for one rank on a 16000 MB node | chain stops with `memory_does_not_fit`, nothing submitted, the stop gives the numbers; the chunk's geometry is kept; `STOPPED` says `--resume` cannot fix it here and what frees memory |
| … then `--resume` | same profile | refused, nothing submitted — never the old allocation, already measured too small |
| … then `--resume` | profile changed to 128000-MB nodes | continues at the measured need: (20000 + 3·20000)/4 × 1.25 = **25000**, 1 node × 4 |
| `--stop` / `--resume` | after the chain had grown to 2 × 5650 | `--resume` keeps **2 × 5650**, not `slurm_vasptest.sh`'s 1 × 2000 |

The rank count never changes in the spread case because the INCAR's
KPAR/NCORE were chosen for it (VASP requires KPAR to divide the ranks and NCORE
to divide the ranks per k-point group).

For ISIF = 3 the scaling is the plane-wave count: at fixed ENCUT the number of
plane waves is proportional to the cell volume, and the wavefunction arrays
scale with it.

## 5. Obtained results

All twenty-three as expected. `chain.log` now carries what each chunk used next to
what it was granted:

```
# idx  jobid  kind   cap  used  t_step  elapsed  frac  peakMB  reqMB verdict
  1    1000   RELAX    3     3    30.0        0  0.00    1500   2000 CONTINUE
  2    1001   RELAX    6     6    30.0        0  0.00    5000   1450 CONTINUE
  3    1002   RELAX   12    12    30.0        0  0.00    1000   5650 CONTINUE
  4    1003   RELAX   24    24    30.0        0  0.00    1000   5650 STOP  stop requested
```

(`elapsed` is 0 because the fake VASP reports its step times without spending
them.) Chunk 2 was granted 1450 and peaked at 5000 — the input of the "grow"
case; chunk 3 peaked at 1000 and was still granted 5650, the "peak is kept"
case.

The test uses NSW = 60 so that the chain is still running at its third chunk;
a chain that has spent NSW stops, and a stopped chain sizes no next chunk. One
assertion checks that chunk 3 said CONTINUE, so the case cannot pass by
default.

Two package bugs were found by this test and fixed in `vasp_chain.sh`:

1. `--resume` re-rendered the chunk job script from `slurm_vasptest.sh`,
   discarding every allocation the chain had measured (the `--stop` /
   `--resume` case in section 4).
2. A new start in a folder with an old chain inherited that chain's state —
   its NBANDS, NKPTS and force history, and now its memory.

## 6. Pass / fail criterion

Exact equality of every `#SBATCH` value against the arithmetic written in the
test. The arithmetic is done by hand here, in the comments of `check.sh`, not
by calling the code under test. Rounding is part of the rule (up to 50 MB), so
there is no tolerance to choose.

## 7. Verdict

**PASSED** — 23 assertions, 0 failed. See `logs/run.log`.

## Sources

- SLURM enforces the job's memory per node, through the task/cgroup plugin:
  `ConstrainRAMSpace` — <https://slurm.schedmd.com/cgroup.conf.html>
- `--mem-per-cpu` is multiplied by the CPUs allocated on each node —
  <https://slurm.schedmd.com/sbatch.html#OPT_mem-per-cpu>
- `MaxRSS` is the maximum over tasks, `AveRSS` the average —
  <https://slurm.schedmd.com/sacct.html>
- OUTCAR's memory figures are rank 0's: VASP labels them so itself
  ("total amount of memory used by VASP MPI-rank0") —
  <https://vasp.at/wiki/OUTCAR>
- KPAR must divide the number of ranks — <https://vasp.at/wiki/KPAR>
- At fixed ENCUT the number of plane waves changes with the cell volume (the
  origin of the Pulay stress) — <https://vasp.at/wiki/Pulay_stress>
