# test_24_alloc_profiles

> profile A (whole nodes) vs profile B (balanced): n x m = ntasks, exactly

## 1. Definition

Runs the recommender under both allocation profiles over a grid of k-point
counts and band counts, and checks the geometry each one writes into
`slurm.sh`. Then it hands every script to a real `slurmctld` with
`sbatch --test-only`, for DFT and GW at three core caps.

## 2. Purpose

Profile A asks the cluster for whole nodes: `--ntasks` is a multiple of the
cores on a node, so a calculation whose physics wants 190 ranks is given 192 or
240. Profile B asks for the rank count the physics wants and spreads it
**evenly** — n nodes of m ranks, `n × m = N` exactly.

Even is not a preference. An MPI rank count split unevenly over nodes makes one
node the slowest, and every collective in every electronic step waits for it.
That is invisible in the output: the job runs, converges, and is simply slower
than its rank count suggests.

Only the scheduler can say a script is **acceptable**, and the failure that
matters is silent: `--nodes`, `--ntasks` and `--ntasks-per-node` are three
claims, and when they disagree SLURM resolves the contradiction rather than
refusing. The job gets more CPUs than it asked for and nothing says so.

The third thing this guards is the one that already broke once. The layout is
computed in more than one place — the candidate loop, the function that writes
the script, and the tool that rewrites it after the benchmark. When they
disagree the first-pass script comes out right and the one the pipeline says to
submit does not.

## 3. How it is executed

```
tests/run_all.sh test_24_alloc_profiles
```

Two cluster profiles differing only in `WP_ALLOC_PROFILE`, 48-core nodes, a
240-core cap and a 5-node limit (`WP_MAX_NODES`, what `vasp-configure` reads
from the testbed partition's `MaxNodes`). For the live part, per profile: 5 k-point counts (1, 41, 63, 72,
190) × 3 NBANDS (48, 200, 800) × DFT and GW × 3 core caps (48, 96, 240). About
two minutes; no VASP runs. The live part needs the SLURM testbed and skips
without it.

190 is in the grid on purpose: `190 = 2 × 5 × 19` shares only a factor 2 with
any multiple of 48, so it is where a rank count that suits the physics and one
the cluster hands out whole disagree.

## 4. Expected results

| check | expected |
|---|---|
| every profile-B layout | `nodes × ntasks-per-node == ntasks`, `m ≤ 48`, within the cap and the 5-node limit |
| 63 k-points, profile B, no node limit known (the control) | 189 ranks over **7** nodes of 27: `189 = 3³ × 7` has no even split on 5 |
| the same with `WP_MAX_NODES = 5` | a layout on 5 nodes or fewer |
| 41 irreducible k-points, profile A | `ntasks` a multiple of 48 |
| 41 irreducible k-points, profile B | `ntasks` divisible by **41**, so KPAR can use it |
| an 8-band cell | both profiles **offer** rank counts below one node |
| a 24-core cap on 48-core nodes | B: 1 node × 24 ranks. A: refuses, saying the cap is the reason |
| NCORE, profile B | divides **m**, the ranks on the node |
| every generated script, both profiles | accepted by a live `slurmctld`; `ntasks` within the cap; `nodes × ntasks-per-node = ntasks` |
| every profile-A script | `nodes × 48` within the cap: SLURM charges whole nodes |
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
profile B: 28 layouts, every one n x m = ntasks exactly, m <= 48, within the cap and the 5-node limit
the control: with no node limit known, profile B spreads 189 ranks over 7 nodes
with WP_MAX_NODES = 5 it chooses a layout that fits: 126 ranks on 3 nodes
profile A asks for whole nodes (ntasks = 240, a multiple of 48)
profile B is free of that multiple (ntasks = 41 = 1 x 41)
and profile B's rank count divides the 41 k-points, which is what KPAR needs
profile whole-nodes offers rank counts below one node (1 2 4 8)
profile balanced offers rank counts below one node (1 .. 47)
profile B under a sub-node cap: 1 node x 24 ranks = 24, inside the 24 cap
profile A under a sub-node cap refuses, and says the cap is the reason
profile B: NCORE divides the ranks on a node in all 4 case(s)
profile A: 90 script(s), every one accepted by a live slurmctld, inside its cap, n x m = ntasks
profile B: 90 script(s), every one accepted by a live slurmctld, inside its cap, n x m = ntasks
stage 3 and stage 2 share one layout rule (190 ranks -> 5 38)
```

**One package bug was found while building this and fixed:** the profile
reached the candidate loop but not `compute_request_geometry`, which is the
function that writes the geometry into `slurm.sh`. Ten of twenty-eight profile-B
layouts came out with **no `--ntasks-per-node` at all** — the directive was
correctly withheld as untrue, because the script had been given the whole-node
split while the candidate carried the balanced one. Same shape as the bug that
put two copies of this rule in two files.

**A second one, found by the live grid on 2026-09-25 and fixed.** With profile
B, 8 of 90 scripts were rejected by SLURM: "Requested node configuration is not
available". An even split can need more nodes than the core cap suggests (63
k-points: 189 ranks, 7 nodes of 27), and the testbed partition allows 5
(`MaxNodes=5`). The recommender knew only the core cap. `vasp-configure` had a
function that reads the node limit from the partition and the QOS, and nothing
called it. Now it stores `WP_MAX_NODES`, and profile B does not offer a rank
count whose even split needs more nodes; the same case gets 126 ranks on 3
nodes. Profile A was not affected: its nodes are the core cap over the cores
per node.

## 6. Pass / fail criterion

`n × m == ntasks` is exact; there is no tolerance in an integer identity, and
one violation fails the test. The cap and `m ≤ cores-per-node` are likewise
exact. The live-scheduler check is pass/fail per script: zero rejections, zero
over-cap allocations, zero inconsistent geometries. A recommendation the tool
**refuses** to make is not a failure: a GW k-group that cannot fit a node at a
48-core cap is correctly refused.

## 7. Verdict

**PASSED** — 14 assertions, 0 failed. See `logs/run.log`.

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
- A partition's `MaxNodes`: "Maximum count of nodes which may be allocated to
  any single job" — <https://slurm.schedmd.com/slurm.conf.html#OPT_MaxNodes>
