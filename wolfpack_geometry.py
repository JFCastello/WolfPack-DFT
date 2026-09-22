#!/usr/bin/env python3
"""How many nodes, and how many ranks on each.

==============================================================================
WHY THIS IS ITS OWN FILE
==============================================================================
This decision used to be written out twice -- once in vasp_recommend_slurm.py
for the first-pass job script, and again in vasp_test_recommend.py for the
DEFINITIVE one it rewrites after the benchmark. They were the same rule, so
they were wrong in the same way, and fixing one fixed nothing the user
actually submits:

    slurm.sh          --nodes=4    --ntasks=190     (fixed)
    slurm_vasptest.sh --nodes=190  --ntasks=190     (not fixed)

The second is the one the pipeline prints as "<- submit this". One copy now.

==============================================================================
THE RULE
==============================================================================
A k-point group must not straddle a node boundary: for conventional GW that
means cross-node chi/W traffic, which is the whole cost of the method. So a
node holds a WHOLE NUMBER of groups.

That is the only constraint, and it used to be read as something stronger --
one group per node, whatever its size. At KPAR = NKPTS a group is a SINGLE
RANK, and "one group per node" then means one node per rank: 190 ranks on 190
nodes, 9120 cores allocated to run 190, refused by the scheduler. A group
cannot straddle a boundary it never reaches. Pack as many whole groups onto a
node as memory allows.

Memory decides how many ranks fit: usable node RAM divided by the REAL per-rank
usage, capped at the cores the node has.
"""

import math
from typing import Optional, Tuple


def node_layout(total_ranks: int, kpar: int, cpus_per_node: int,
                usable_node_mb: float, usage_per_rank_mb: float,
                max_cores: Optional[int] = None) -> Tuple[int, int]:
    """Return (nodes, ranks_per_node).

    `usable_node_mb` is the node's RAM minus whatever is held back.
    `usage_per_rank_mb` is REAL expected RSS, not the padded request.
    `max_cores`, when given, is the account cap -- in CORES, because SLURM
    hands out whole nodes and charges cpus_per_node for each however few tasks
    run on them. Checking the cap against the RANK count made a request for
    9120 cores look like "190 of 240".
    """
    total = max(1, int(total_ranks))
    cpn = max(1, int(cpus_per_node))
    kpar = max(1, int(kpar))
    usage = max(float(usage_per_rank_mb), 1.0)

    by_use = max(1, int(usable_node_mb // math.ceil(usage)))
    cap = max(1, min(cpn, by_use))                 # ranks a node can hold

    rpk = total // kpar if (kpar and total % kpar == 0) else 0

    if total <= cap:                               # the whole job fits one node
        nodes, ntpn = 1, total
    elif rpk and rpk <= cap:                       # whole groups, packed
        groups_per_node = max(1, cap // rpk)
        nodes = math.ceil(kpar / groups_per_node)
        ntpn = min(cap, math.ceil(total / nodes))
    else:                                          # memory-only split
        ntpn = min(cpn, total, cap)
        nodes = max(1, math.ceil(total / ntpn))
        ntpn = min(cpn, math.ceil(total / nodes))

    # The cap is on allocated cores. If the group-aligned layout cannot pay for
    # itself, pack densely instead and let the caller refuse if it still does
    # not fit -- better a refusal than a script the scheduler rejects.
    if max_cores and nodes * cpn > max_cores:
        dense_ntpn = max(1, min(cpn, cap))
        dense_nodes = max(1, math.ceil(total / dense_ntpn))
        if dense_nodes * cpn <= max_cores or dense_nodes < nodes:
            nodes = dense_nodes
            ntpn = min(cpn, math.ceil(total / nodes))
    return nodes, ntpn


def ntasks_per_node_line(nodes: int, ntpn: int, total_ranks: int) -> str:
    """The #SBATCH line, or a comment saying why there isn't one.

    --nodes, --ntasks and --ntasks-per-node are three claims about one
    allocation. When they disagree SLURM keeps two and drops the third with a
    warning -- "can't honor --ntasks-per-node set to 48 which doesn't match the
    requested tasks 190 with the number of requested nodes 4" -- and then
    allocates 192 CPUs for 190 ranks. Say it only when it is true.
    """
    if nodes * ntpn == total_ranks:
        return f"#SBATCH --ntasks-per-node={ntpn}"
    return (f"# no --ntasks-per-node: {total_ranks} ranks do not divide evenly "
            f"over {nodes} node(s) ({nodes} x {ntpn} = {nodes * ntpn}), "
            f"so SLURM distributes them")


if __name__ == "__main__":                         # a quick self-check
    # The first two are the cases that shipped broken, with the memory the
    # benchmark actually measured on them -- not a round number chosen to make
    # the test pass.
    cases = [
        # total kpar cpn  usable    usage   cap   expect  what it is
        (190, 190, 48, 384000.0,  6362.0,  240,  4),   # LaMnO3: was 190 nodes x 1
        (144,  72, 48, 384000.0,  1624.0,  240,  3),   # LaVO3:  was  72 nodes x 2
        (190,   1, 48, 384000.0,  1600.0,  240,  4),   # no k-parallelism
        (190, 190, 48, 384000.0,  9000.0,  240,  5),   # heavy: 42 ranks/node, so 5
        (  8,   8,  8,   7000.0,   300.0,    8,  1),   # a laptop
    ]
    bad = 0
    for total, kpar, cpn, usable, usage, cap, want in cases:
        n, t = node_layout(total, kpar, cpn, usable, usage, cap)
        ok = (n == want and n * t >= total and t <= cpn and n * cpn <= cap)
        bad += not ok
        print(f"  {total:4d} ranks kpar={kpar:4d} -> {n} node(s) x {t}"
              f"  ({'ok' if ok else f'EXPECTED {want} nodes'})")
    raise SystemExit(1 if bad else 0)
