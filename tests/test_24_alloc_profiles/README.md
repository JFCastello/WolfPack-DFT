# test_24_alloc_profiles

> profile A (whole nodes) vs profile B (balanced): n x m = ntasks, exactly

## 1. Definition

Runs the recommender under both allocation profiles over a grid of k-point
counts and band counts, and checks the geometry each one writes into
`slurm.sh`.

## 2. Purpose

Profile A asks the cluster for whole nodes: `--ntasks` is a multiple of the
cores on a node, so a calculation whose physics wants 190 ranks is given 192 or
240. Profile B asks for the rank count the physics wants and spreads it
**evenly** — n nodes of m ranks, `n × m = N` exactly.

Even is not a preference. An MPI rank count split unevenly over nodes makes one
node the slowest, and every collective in every electronic step waits for it.
That is invisible in the output: the job runs, converges, and is simply slower
than its rank count suggests.

The second thing this guards is the one that already broke once. The layout is
computed in more than one place — the candidate loop, the function that writes
the script, and the tool that rewrites it after the benchmark. When they
disagree the first-pass script comes out right and the one the pipeline says to
submit does not.

## 3. How it is executed

```
tests/run_all.sh test_24_alloc_profiles
```

Two cluster profiles differing only in `WP_ALLOC_PROFILE`, 48-core nodes, a
240-core cap. Seconds; no VASP.

## 4. Expected results

| check | expected |
|---|---|
| every profile-B layout | `nodes × ntasks-per-node == ntasks`, `m ≤ 48`, within the cap |
| 41 irreducible k-points, profile A | `ntasks` a multiple of 48 |
| 41 irreducible k-points, profile B | `ntasks` divisible by **41**, so KPAR can use it |
| an 8-band cell | both profiles **offer** rank counts below one node |
| a 24-core cap on 48-core nodes | B: 1 node × 24 ranks. A: refuses, saying the cap is the reason |
| NCORE, profile B | divides **m**, the ranks on the node |
| every generated script | accepted by a live `slurmctld` |
| stage 2 and stage 3 | one layout rule, same answer |

The A-refuses-at-24-cores row is not a gap. On a cluster that hands out whole
nodes, a 24-core cap cannot pay for a 48-core node, and saying so beats writing
a script the scheduler will reject.

D4 measured against `m` follows from the rule's own stated reason: *"Choose
NCORE as a factor of the cores per node **to avoid communicating between nodes
for the FFTs**."* The ranks that share an orbital's FFT are the ranks on the
node — in profile B that is `m`, not the node's physical core count.

## 5. Obtained results

```
profile B: 28 layouts, every one n x m = ntasks exactly, m <= 48, within the cap
profile A asks for whole nodes (ntasks = 240, a multiple of 48)
profile B is free of that multiple (ntasks = 41 = 1 x 41)
and profile B's rank count divides the 41 k-points, which is what KPAR needs
profile whole-nodes offers rank counts below one node (1 2 4 8)
profile balanced offers rank counts below one node (1 .. 47)
profile B under a sub-node cap: 1 node x 24 ranks = 24, inside the 24 cap
profile A under a sub-node cap refuses, and says the cap is the reason
profile B: NCORE divides the ranks on a node in all 4 case(s)
6 script(s) from both profiles, every one accepted by a live slurmctld
stage 3 and stage 2 share one layout rule (190 ranks -> 5 38)
```

**One package bug was found while building this and fixed:** the profile
reached the candidate loop but not `compute_request_geometry`, which is the
function that writes the geometry into `slurm.sh`. Ten of twenty-eight profile-B
layouts came out with **no `--ntasks-per-node` at all** — the directive was
correctly withheld as untrue, because the script had been given the whole-node
split while the candidate carried the balanced one. Same shape as the bug that
put two copies of this rule in two files.

## 6. Pass / fail criterion

`n × m == ntasks` is exact; there is no tolerance in an integer identity, and
one violation fails the test. The cap and `m ≤ cores-per-node` are likewise
exact. The live-scheduler check is pass/fail per script.

## 7. Verdict

**PASSED** — 11 assertions, 0 failed. See `logs/run.log`.

## Sources

- *"VASP assumes the ranks first fill up a node before the next node is
  occupied... If the ranks are placed differently, communication between the
  nodes occurs for every parallel FFT."* —
  <https://vasp.at/wiki/Category:Parallelization>
- *"Choose NCORE as a factor of the cores per node to avoid communicating
  between nodes for the FFTs"*; *"KPAR should factorize the number of k
  points."* — <https://vasp.at/wiki/Optimizing_the_parallelization>
- SLURM's behaviour when `--nodes`, `--ntasks` and `--ntasks-per-node`
  disagree — <https://slurm.schedmd.com/sbatch.html>
