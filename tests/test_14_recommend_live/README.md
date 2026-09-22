# test_14_recommend_live

> every generated SLURM script, submitted to a live slurmctld

## 1. Definition

Generates the recommender's SLURM script across a grid of systems and core
caps and hands each one to a real `slurmctld` with `sbatch --test-only`.

## 2. Purpose

Parsing a script tells you it is syntactically fine. Only the scheduler can
tell you it is **acceptable**. And the failure that matters is silent:
`--nodes`, `--ntasks` and `--ntasks-per-node` are three claims, and when they
disagree SLURM resolves the contradiction rather than refusing — the job gets
more CPUs than it asked for and nothing says so.

## 3. How it is executed

```
tests/run_all.sh test_14_recommend_live
```

5 k-point counts (1, 41, 63, 72, 190) × 3 NBANDS (48, 200, 800) × 2 calculation
types × 3 core caps (48, 96, 240). A few minutes; no VASP runs.

190 is in the grid on purpose: `190 = 2 × 5 × 19` shares only a factor 2 with
any multiple of 48, so it is the case where a rank count that suits the physics
and one the cluster can hand out whole disagree.

## 4. Expected results

Every script: accepted by SLURM; `nodes × cores-per-node` within the cap — the
cap SLURM **charges**, which is whole nodes, not ranks; and the three geometry
directives consistent.

## 5. Obtained results

```
90 generated script(s), every one accepted by a live slurmctld and inside its cap
```

## 6. Pass / fail criterion

Zero rejections, zero over-cap allocations, zero inconsistent geometries. A
recommendation the tool **refuses** to make is not a failure — a GW k-group
that cannot fit a node at a 48-core cap is correctly refused.

## 7. Verdict

**PASSED** — 1 assertion covering 90 scripts, 0 failed. See `logs/run.log`.

## Sources

- *"VASP assumes the ranks first fill up a node before the next node is
  occupied"* — <https://vasp.at/wiki/Category:Parallelization>
- <https://slurm.schedmd.com/sbatch.html>
