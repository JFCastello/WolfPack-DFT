# test_22_geometry

> how many nodes, how many ranks on each: five invariants over 2025 layouts

## 1. Definition

Sweeps `wolfpack_geometry.node_layout` over a grid of rank counts, KPAR values,
node sizes, memory figures and core caps, and checks five invariants on every
result. Then states the two shipped failures as named claims.

## 2. Purpose

This decision used to be written out **twice** — once in
`vasp_recommend_slurm.py` for the first-pass job script, and again in
`vasp_test_recommend.py` for the definitive one the benchmark rewrites. They
were the same rule, so they were wrong in the same way, and fixing one fixed
nothing the user actually submits:

```
slurm.sh          --nodes=4    --ntasks=190     (fixed)
slurm_vasptest.sh --nodes=190  --ntasks=190     (not fixed)
```

The second is the one the pipeline prints as `<- submit this`. There is one
copy now, and this test guards it.

The two failures are checked **by name** rather than only as invariants,
because "190 nodes for 190 ranks" satisfies every invariant in the list: it
holds every rank, it overfills no node, it wastes no RAM. It was wrong because
it allocated 9120 cores to run 190 ranks, and only the core cap notices that.

## 3. How it is executed

```
tests/run_all.sh test_22_geometry
```

The module's own regression cases, then a 2025-point sweep, then the named
claims. Seconds; no VASP, no scheduler.

## 4. Expected results

| | invariant |
|---|---|
| I1 | a node never holds more ranks than it has cores |
| I2 | the layout has room for every rank |
| I3 | no empty node — a node allocated and not used is a node charged |
| I4 | a node never holds more ranks than its RAM allows, unless even one rank does not fit (one rank per node is the floor, not a violation) |
| I5 | `--ntasks-per-node` is printed **only when it is true** |

Plus the named claims: `KPAR = NKPTS` must not mean one node per rank; the core
cap must be checked against **cores**, not ranks; whole k-groups must be packed
onto a node rather than spread one per node.

I5 is its own failure mode. `--nodes`, `--ntasks` and `--ntasks-per-node` are
three claims about one allocation; when they disagree SLURM keeps two, drops
the third with a warning in a log nobody reads, and allocates 192 CPUs for 190
ranks.

## 5. Obtained results

```
the module's own regression cases still hold
2025 layouts swept, every one satisfies all five invariants
KPAR = NKPTS does not mean one node per rank (4 nodes for 190 ranks, not 190)
the 240-core cap is checked against CORES, not ranks (192 cores)
whole k-groups are packed onto a node (3 nodes for 144 ranks)
no --ntasks-per-node is claimed when 190 ranks do not divide over 4 nodes
and the script says WHY the directive is absent
```

No package bug was found here.

## 6. Pass / fail criterion

Zero invariant violations across the sweep — every invariant is an exact
integer comparison, so there is no tolerance. The named claims are bounds
(`≤ 5 nodes`, `≤ 240 cores`, `≤ 3 nodes`) rather than exact values, so a future
improvement that packs *better* still passes and only a regression fails.

## 7. Verdict

**PASSED** — 7 assertions (one covering 2025 layouts), 0 failed. See
`logs/run.log`.

## Sources

- The rank-placement rule the layout exists to satisfy — *"VASP assumes the
  ranks first fill up a node before the next node is occupied"* —
  <https://vasp.at/wiki/Category:Parallelization>
- SLURM's behaviour when `--nodes`, `--ntasks` and `--ntasks-per-node`
  disagree — <https://slurm.schedmd.com/sbatch.html>
