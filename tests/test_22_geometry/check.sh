#!/usr/bin/env bash
# test_22_geometry -- how many nodes, how many ranks on each.
#
# One rule, shared by the first-pass job script and the definitive one the
# benchmark rewrites. It used to be written twice and was wrong in both, in the
# same way, so fixing one fixed nothing the user submits. This checks the
# invariants of the surviving copy, and checks them as PROPERTIES over a sweep
# rather than against numbers a previous run printed.
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/t22"; rm -rf "$W"; mkdir -p "$W"

# --- the module's own self-check -------------------------------------------
# Its cases carry the memory the benchmark MEASURED on the runs that shipped
# broken, not round numbers chosen to make it pass.
out=$("$WP_PY" "$TK_DIR/wolfpack_geometry.py" 2>&1); rc=$?
(( rc == 0 )) && pass "the module's own regression cases still hold" \
              || fail "the module's own regression cases FAILED: $(tr '\n' ' ' <<<"$out")"

# --- the invariants, over a sweep ------------------------------------------
"$WP_PY" - "$TK_DIR" <<'PY' > "$W/sweep.out" 2>&1
import sys, itertools, math
sys.path.insert(0, sys.argv[1])
from wolfpack_geometry import node_layout, ntasks_per_node_line

bad, n = [], 0
for total, kpar, cpn, usable, usage, cap in itertools.product(
        [1, 8, 41, 96, 144, 190, 240],      # total ranks, incl. a prime
        [1, 2, 8, 72, 190],                 # KPAR
        [8, 48, 128],                       # cores per node
        [7000.0, 192000.0, 384000.0],       # usable RAM per node
        [300.0, 1624.0, 9000.0],            # measured RSS per rank
        [8, 240, 4096]):                    # the account's core cap
    if kpar > total:                        # not a layout anyone asks for
        continue
    nodes, ntpn = node_layout(total, kpar, cpn, usable, usage, cap)
    n += 1
    tag = f"total={total} kpar={kpar} cpn={cpn} usable={usable} usage={usage} cap={cap}"

    # I1. a node cannot hold more ranks than it has cores.
    if ntpn > cpn:
        bad.append(f"{tag}: {ntpn} ranks on a {cpn}-core node")
    # I2. the layout must have room for every rank.
    if nodes * ntpn < total:
        bad.append(f"{tag}: {nodes}x{ntpn} cannot hold {total} ranks")
    # I3. no empty node: a node allocated and not used is a node charged.
    if nodes > 1 and (nodes - 1) * ntpn >= total:
        bad.append(f"{tag}: {nodes} nodes when {nodes-1} would hold {total}")
    # I4. a node must not hold more ranks than its RAM allows, UNLESS even one
    #     rank does not fit -- one rank per node is the floor, not a violation.
    fits = max(1, int(usable // math.ceil(usage)))
    if ntpn > fits and ntpn > 1:
        bad.append(f"{tag}: {ntpn} ranks/node but only {fits} fit in RAM")
    # I5. the --ntasks-per-node line is printed only when it is TRUE.
    line = ntasks_per_node_line(nodes, ntpn, total)
    says = line.lstrip().startswith("#SBATCH")
    if says and nodes * ntpn != total:
        bad.append(f"{tag}: claims --ntasks-per-node={ntpn} but {nodes}x{ntpn} != {total}")
    if not says and nodes * ntpn == total:
        bad.append(f"{tag}: geometry is exact but the directive was withheld")

print(f"COUNT {n}")
for b in bad[:20]:
    print("VIOLATION", b)
print(f"BAD {len(bad)}")
PY
cnt=$(sed -n 's/^COUNT //p' "$W/sweep.out")
bad=$(sed -n 's/^BAD //p' "$W/sweep.out")
if [[ "$bad" == 0 ]]; then
    pass "$cnt layouts swept, every one satisfies all five invariants"
else
    fail "$bad of $cnt layouts violate an invariant"
    grep '^VIOLATION' "$W/sweep.out" | head -5 | while read -r l; do info "    $l"; done
fi

# --- the two regressions, stated as claims ---------------------------------
# These are the shipped failures, named. A sweep of invariants would not catch
# "190 nodes for 190 ranks" as wrong -- it satisfies every invariant above --
# because the fault was allocating 9120 cores to run 190 ranks.
read -r nodes ntpn < <("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
from wolfpack_geometry import node_layout
print(*node_layout(190, 190, 48, 384000.0, 6362.0, 240))")
ok_if "[[ $nodes -le 5 ]]" "KPAR = NKPTS does not mean one node per rank ($nodes nodes for 190 ranks, not 190)"
ok_if "[[ $((nodes * 48)) -le 240 ]]" "the 240-core cap is checked against CORES, not ranks ($((nodes*48)) cores)"

read -r nodes2 ntpn2 < <("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
from wolfpack_geometry import node_layout
print(*node_layout(144, 72, 48, 384000.0, 1624.0, 240))")
ok_if "[[ $nodes2 -le 3 ]]" "whole k-groups are packed onto a node, not spread one per node ($nodes2 nodes for 144 ranks)"

# --- the directive that used to lie ----------------------------------------
# 190 ranks over 4 nodes is 47.5: any --ntasks-per-node here is untrue, and
# SLURM answers an untrue one by allocating 192 CPUs and warning in a log
# nobody reads.
line=$("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
from wolfpack_geometry import ntasks_per_node_line
print(ntasks_per_node_line(4, 48, 190))")
ok_if "! grep -q '^#SBATCH' <<<'$line'" \
      "no --ntasks-per-node is claimed when 190 ranks do not divide over 4 nodes"
ok_if "grep -qi 'do not divide\|distributes' <<<'$line'" \
      "and the script says WHY the directive is absent, instead of leaving a gap"

exit $(( FAIL_N > 0 ))
