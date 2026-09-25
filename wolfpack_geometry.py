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

# The two allocation profiles. A cluster profile carries one of these in
# WP_ALLOC_PROFILE; everything that lays ranks out on nodes reads it from there
# so the first-pass job script and the definitive one cannot disagree.
WHOLE_NODES = "whole-nodes"     # profile A: ntasks is a multiple of the node
BALANCED = "balanced"           # profile B: n * m = N, every node equal


# --------------------------------------------------------------------------- #
# Profile B: equal occupancy
# --------------------------------------------------------------------------- #
# The search window, in nodes, above the densest packing memory and cores allow.
# It is not physics. It is how far the search looks for a node count that
# DIVIDES the rank count before giving up on that rank count entirely, and it
# is small on purpose: a job spread much thinner than it needs to be pays
# inter-node FFT traffic for nothing, and there is almost always a nearby rank
# count that packs cleanly. A prime rank count above one node has no clean
# packing at all and is rejected here rather than laid out one rank per node,
# which is the shape this module exists to prevent.
BALANCED_SEARCH_NODES = 3


def balanced_layout(total_ranks: int, cpus_per_node: int,
                    usable_node_mb: float = 0.0, usage_per_rank_mb: float = 0.0,
                    ranks_per_kgroup: int = 0,
                    max_nodes: int = 0) -> Optional[Tuple[int, int]]:
    """Profile B: (nodes, ranks_per_node) with nodes * ranks_per_node EXACTLY
    equal to `total_ranks`, or None when no such layout is worth having.

    Profile A asks the scheduler for whole nodes, so the rank count has to be a
    multiple of the cores on a node: on 48-core nodes the physics may want 190
    ranks and gets 192 or 240. Profile B asks for the rank count the physics
    wants and spreads it EVENLY -- n nodes of m ranks, n * m = N, every node
    carrying the same load.

    Even is not a preference. An MPI rank count split unevenly over nodes makes
    one node the slowest, and every collective in every electronic step waits
    for it.

    Two things bound m, the ranks on a node:
      * the node's cores -- m <= cpus_per_node, always;
      * the node's memory, when a per-rank figure is known. Asking for fewer
        ranks per node is how a job gets more memory per rank, and on a cluster
        that shares nodes it costs nothing but inter-node traffic.

    Within those bounds this packs as densely as it can, because VASP wants the
    ranks to fill a node before the next one is used:

        "VASP assumes the ranks first fill up a node before the next node is
         occupied... If the ranks are placed differently, communication between
         the nodes occurs for every parallel FFT."
        -- https://vasp.at/wiki/Category:Parallelization

    `ranks_per_kgroup`, when given, is N / KPAR. A node holding a whole number
    of k-point groups keeps each group's communication inside one node, so a
    layout that manages it is preferred over a denser one that does not.

    `max_nodes`, when given, is the most nodes one job may have (the
    partition's MaxNodes, or a QOS limit; vasp-configure: WP_MAX_NODES). An
    even split can need more nodes than the core cap suggests -- 189 = 3^3 x 7
    ranks on 48-core nodes is 7 nodes of 27 at best -- and SLURM rejects a job
    above the limit ("Requested node configuration is not available"). Such a
    rank count has no layout here. 0 means no limit is known.
    """
    total = max(1, int(total_ranks))
    cpn = max(1, int(cpus_per_node))

    m_max = cpn
    if usable_node_mb > 0 and usage_per_rank_mb > 0:
        by_mem = int(usable_node_mb // math.ceil(usage_per_rank_mb))
        m_max = max(1, min(cpn, by_mem))

    if total <= m_max:                       # the whole job fits on one node
        return 1, total

    n_min = math.ceil(total / m_max)
    rpk = max(0, int(ranks_per_kgroup))

    # First choice: the densest layout in the window that also keeps whole
    # k-point groups on a node. Second choice: the densest layout, full stop.
    dense: Optional[Tuple[int, int]] = None
    for n in range(n_min, n_min + BALANCED_SEARCH_NODES + 1):
        if n <= 0 or total % n:
            continue
        if max_nodes and n > max_nodes:
            break
        m = total // n
        if m > m_max:
            continue
        if dense is None:
            dense = (n, m)
        if rpk and m % rpk == 0:
            return n, m
    return dense

def node_layout(total_ranks: int, kpar: int, cpus_per_node: int,
                usable_node_mb: float, usage_per_rank_mb: float,
                max_cores: Optional[int] = None,
                profile: str = WHOLE_NODES,
                max_nodes: int = 0) -> Tuple[int, int]:
    """Return (nodes, ranks_per_node).

    `usable_node_mb` is the node's RAM minus whatever is held back.
    `usage_per_rank_mb` is REAL expected RSS, not the padded request.
    `max_cores`, when given, is the account cap -- in CORES for profile A,
    because a cluster that hands out whole nodes charges cpus_per_node for each
    however few tasks run on them. Checking the cap against the RANK count made
    a request for 9120 cores look like "190 of 240".

    `profile` selects how the ranks are laid out:

      WHOLE_NODES (A)  the cluster is asked for whole nodes, so the rank count
                       is a multiple of the cores on a node. The cap is in
                       CORES: n nodes cost n * cpus_per_node whatever runs on
                       them.
      BALANCED (B)     the rank count comes from the physics and is spread
                       EVENLY, n * m = N exactly. The cap is in RANKS, because
                       a cluster that shares nodes charges for the cores the
                       job asked for. See balanced_layout.

    Both profiles return (1, N) when N does not fill a node: a rank count below
    cpus_per_node is a legitimate answer for a small cell, and padding it out
    to a full node adds ranks that have no bands left to work on.
    """
    if profile == BALANCED:
        got = balanced_layout(total_ranks, cpus_per_node,
                              usable_node_mb, usage_per_rank_mb,
                              ranks_per_kgroup=(max(1, int(total_ranks)) // max(1, int(kpar))
                                                if kpar else 0),
                              max_nodes=max_nodes)
        if got is not None:
            return got
        # No even split worth having. Fall through to the whole-node layout
        # rather than refuse here: the caller ranks candidates and a rank count
        # that cannot be laid out evenly simply should not have been offered.

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
