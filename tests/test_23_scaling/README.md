# test_23_scaling

> stage 3's arithmetic: measure small, run big -- and never under-request

## 1. Definition

Checks the extrapolation `vasp-test` performs after its benchmark: reading the
OUTCAR memory table, anchoring a model to the measured per-rank memory, scaling
it to the production rank count, sizing the request, and rewriting the
production job script. The rewritten script is then handed to a live
`slurmctld`.

## 2. Purpose

The benchmark runs the production configuration at a rank count the debug
partition can hold. **Everything the production job asks SLURM for comes out of
extrapolating that one measurement**, and nothing downstream re-measures it.
So an error here is paid once, at hour six of a production run, as an OOM kill.

Three things are checked that a "does it run" test would not:

- **Anchoring.** The model is a shape; the benchmark is the truth. Evaluated at
  the layout it was measured on, the estimator must return the measurement
  itself. If it does not, the correction factor is not doing its job and every
  extrapolation is off by that factor, silently.
- **Never under-requesting.** Asking for less than the prediction is an OOM by
  arithmetic.
- **The rewritten script's own claims.** `--nodes`, `--ntasks` and
  `--ntasks-per-node` must not be left contradicting each other after the
  rewrite.

## 3. How it is executed

```
tests/run_all.sh test_23_scaling
```

A synthetic OUTCAR whose memory rows are all distinguishable, then a
1080-point sizing sweep, then two job-script rewrites, then `sbatch
--test-only`. Seconds; no VASP.

## 4. Expected results

| check | expected |
|---|---|
| OUTCAR memory table | each row read from its own line, kBytes converted to MB (2097152 kB → 2048.0 MB) |
| the estimator at its own anchor | **exactly** the measured value |
| per-rank memory vs rank count | falls, stays positive, does not scale away the non-distributed part |
| every sizing | request ≥ prediction; `mem-per-cpu × ranks-per-node` ≤ node RAM; layout holds the job |
| rewriting a `190 nodes / 190 ranks` script to 4 × 48 for 190 ranks | nodes and memory updated; the stale `--ntasks-per-node=1` **gone**, replaced by the comment saying why there is none |
| rewriting one where 4 × 48 = 192 really is the rank count | the directive **is** written |
| the rewritten script | accepted by a live `slurmctld`, submitted exactly as stage 3 left it |

The last two are a pair on purpose: withholding the directive always would pass
the "no untrue directive" check for entirely the wrong reason.

## 5. Obtained results

```
the memory table reads back: total 2048.0, grid 878.906, nonlr 488.281,
    wave 573.391 MB
the estimator returns the MEASURED value at its own layout   |d| = 0.000000 MB
per-rank memory falls as ranks rise: 1800 1548 1380 1338 1317 MB
1080 sizings swept: none under-requests, none oversubscribes a node
the stale --ntasks-per-node=1 is gone; the true one is written when it is true
a real slurmctld accepts the script stage 3 rewrote
```

No package bug was found here. One assertion failed on the first run; it was
**mine**.


## 6. Pass / fail criterion

| quantity | criterion | why |
|---|---|---|
| anchoring | `|estimate − measurement| < 1e-6` MB | it is an identity, not an approximation: anything else means the correction factor is wrong |
| memory rows | exact to 3 decimals | a unit error is a factor of 1024 |
| request vs prediction | `≥`, no tolerance | the whole point |
| node total | `≤` node RAM, no tolerance | SLURM enforces it |

## 7. Verdict

**PASSED** — 17 assertions, 0 failed. See `logs/run.log`.

## Sources

- The VASP component-distribution rules the model uses — wavefunctions scale
  with the total rank count, the grid with `NPAR`, the projectors with `NCORE`:
  <https://vasp.at/wiki/Category:Parallelization> and
  <https://www.vasp.at/wiki/index.php/NCORE>
- `MaxRSS` vs `AveRSS`, and what SLURM actually enforces —
  <https://slurm.schedmd.com/sacct.html>,
  <https://slurm.schedmd.com/sbatch.html>
