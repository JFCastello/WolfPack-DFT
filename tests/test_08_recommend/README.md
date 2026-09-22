# test_08_recommend

> vasp-recommend-slurm: the VASP parallelization rules, judged per regime

## 1. Definition

Sweeps the recommender over a grid of k-point counts, calculation types and
core caps, and checks every recommendation it makes against the published VASP
parallelization rules — **and against the right set of them**.

## 2. Purpose

VASP parallelizes GW/RPA by different rules than an electronic minimization.
A GW layout checked against the SCF rules would fail for rules that are not its
own; worse, if it **passed** them, that would mean the tool had quietly applied
rules VASP does not apply there.

So the test reads which regime applies off the recommendation itself — the tool
states it — and judges by that set. The two sets:

### Shared: MPI rank placement, which is neither algorithm's business

| | rule |
|---|---|
| D1 / G1 | `N_ranks = N_nodes × C_node`, and `N_nodes × C_node ≤ C_max` |
| D3 / G2 | `N_ranks % KPAR == 0` |
| both | `NPAR × NCORE × KPAR == N_ranks`; `NKPTS = 1` forces `KPAR = 1` |

### relax / SCF only

| | rule |
|---|---|
| D2 | `NKPTS % KPAR == 0` |
| D4 | `C_node % NCORE == 0` or `C_NUMA % NCORE == 0` |
| D5 | `(N_ranks/KPAR) % NCORE == 0` |
| D6 | `NBANDS_real = ceil(NBANDS/NPAR) × NPAR` |

### GW / RPA only

| | rule |
|---|---|
| G3 | `NCORE = 1`, always |

## 3. How it is executed

```
tests/run_all.sh test_08_recommend
```

4 k-point counts (1 = Γ-only, 41 = prime, 63, 72) × 3 calculation types
(dft, gw, gw-low) × 3 core caps (48, 96, 240), from captured dry-run OUTCARs.
Seconds; no VASP, no SLURM.

The prime 41 is in the grid because it is the case where "KPAR should factorize
NKPTS" and "KPAR should divide the rank count" pull in opposite directions.

## 4. Expected results

Every recommendation satisfies every rule of **its own** regime and none of the
other's. A refusal is not a violation: a GW layout whose k-group cannot fit in a
node's memory at a 48-core cap is *correctly* refused. Plus: a core cap below
one node is refused rather than rounded up, and a missing dry-run OUTCAR is
refused by name.

## 5. Obtained results

```
32 recommendations checked, 0 rule violations
 4 correct refusals (gw-low, where a k-group does not fit)
a core cap below one node is refused, not rounded up
a missing dry-run OUTCAR is refused by name
```

Each line in `logs/run.log` states which rule set was applied, e.g.
`[GW / RPA (NCORE = 1; a k-group must fit in memory)]`.

## 6. Pass / fail criterion

Zero violations. Every rule is an exact integer identity — there is no
tolerance, and nothing here is a matter of judgement. A recommendation that
satisfies a rule belonging to the *other* regime is not thereby a failure, but
one that violates a rule of its own regime is.

## 7. Verdict

**PASSED** — 34 assertions, 0 failed. See `logs/run.log`.

## Sources

- *"VASP assumes the ranks first fill up a node before the next node is
  occupied... If the ranks are placed differently, communication between the
  nodes occurs for every parallel FFT."* —
  <https://vasp.at/wiki/Category:Parallelization>
- *"Choose NCORE as a factor of the cores per node"*; *"increase KPAR up to the
  number of irreducible k points. Keep in mind that KPAR should factorize the
  number of k points."* — these sit under **"Tips to parallelize electronic
  minimization"**, which is what scopes them to that regime:
  <https://vasp.at/wiki/Optimizing_the_parallelization>
- *"Unfortunately you need to use the default for GW and RPA calculations"*
  (NCORE = 1) — same page.
- `KPAR` must divide the total number of cores —
  <https://vasp.at/wiki/KPAR>
