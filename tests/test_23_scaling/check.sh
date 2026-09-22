#!/usr/bin/env bash
# test_23_scaling -- stage 3's arithmetic: measure small, run big.
#
# vasp-test benchmarks the production configuration at a rank count the debug
# partition can hold, then scales the MEASURED per-rank memory up to the
# production rank count. Everything the production job asks SLURM for comes out
# of that extrapolation, so it is checked here as properties -- anchoring,
# monotonicity, never under-requesting -- and the rewritten script is handed to
# a live scheduler.
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/t23"; rm -rf "$W"; mkdir -p "$W"
TR="$TK_DIR/vasp_test_recommend.py"

# --- 1. the OUTCAR memory table, read back ---------------------------------
# The numbers below are the shape VASP writes, with values chosen so each row
# is distinguishable from the others -- a parser that swapped two rows, or read
# kBytes as MB, cannot pass.
cat > "$W/OUTCAR" <<'EOF'
      total amount of memory used by VASP MPI-rank0  2097152. kBytes
   ==================================================================
      base      :      30000. kBytes
      nonl-proj :     500000. kBytes
      fftplans  :      70000. kBytes
      grid      :     900000. kBytes
      one-center:      10000. kBytes
      wavefun   :     587152. kBytes
EOF
"$WP_PY" - "$TK_DIR" "$W" <<'PY' > "$W/parse.out" 2>&1
import sys, json
sys.path.insert(0, sys.argv[1])
from vasp_test_recommend import parse_outcar_memory
m = parse_outcar_memory(open(sys.argv[2] + "/OUTCAR").read())
print(json.dumps({k: round(v, 3) for k, v in m.items()}))
PY
got=$(cat "$W/parse.out")
# 2097152 kB = 2048 MB exactly; 900000 kB = 878.906 MB.
ok_if "grep -q '\"total\": 2048.0' <<<'$got'" "the rank-0 total is read as MB, not left in kBytes"
ok_if "grep -q '\"grid\": 878.906' <<<'$got'" "the grid row is read from its own line"
ok_if "grep -q '\"nonlr\": 488.281' <<<'$got'" "the nonl-proj row is not confused with another"
ok_if "grep -q '\"wave\": 573.391' <<<'$got'" "the wavefun row is read from its own line"

# --- 2. the estimator is ANCHORED to what was measured ---------------------
# The model is a shape; the benchmark is the truth. Evaluated AT the layout it
# was measured on, the estimator must return the measurement itself. If it does
# not, the correction factor is not doing its job and every extrapolation is
# off by that factor -- silently, since nothing downstream re-measures.
"$WP_PY" - "$TK_DIR" "$W" <<'PY' > "$W/est.out" 2>&1
import sys
sys.path.insert(0, sys.argv[1])
from vasp_test_recommend import parse_outcar_memory, make_estimator
mem = parse_outcar_memory(open(sys.argv[2] + "/OUTCAR").read())
anchor, nt, npar_t, ncore_t = 1800.0, 8, 4, 2
per_rank, corr = make_estimator(anchor, mem, nt, npar_t, ncore_t)
at_test = per_rank(nt, npar_t, ncore_t)
print(f"ANCHOR {abs(at_test - anchor):.6f}")
# more ranks over the same problem -> less per rank, and never negative
seq = [per_rank(r, npar_t, ncore_t) for r in (8, 16, 48, 96, 192)]
print("MONO", int(all(a > b for a, b in zip(seq, seq[1:]))))
print("POS", int(all(v > 0 for v in seq)))
# and it must not fall below the part that is NOT distributed over ranks
floor = mem["base"] + mem["fft"] + mem["one"]
print("FLOOR", int(seq[-1] > 0.5 * corr * floor if corr else 1))
print("SEQ", " ".join(f"{v:.0f}" for v in seq))
PY
d=$(sed -n 's/^ANCHOR //p' "$W/est.out")
awk -v d="${d:-9}" 'BEGIN{exit !(d < 1e-6)}' \
    && pass "the estimator returns the MEASURED value at the layout it was measured on (|d| = ${d:-?} MB)" \
    || fail "the estimator does not reproduce its own anchor (off by ${d:-?} MB)"
ok_if "[[ \$(sed -n 's/^MONO //p' '$W/est.out') == 1 ]]" \
      "per-rank memory falls as ranks rise ($(sed -n 's/^SEQ //p' "$W/est.out") MB)"
ok_if "[[ \$(sed -n 's/^POS //p' '$W/est.out') == 1 ]]" "no extrapolation goes negative"
ok_if "[[ \$(sed -n 's/^FLOOR //p' '$W/est.out') == 1 ]]" \
      "it does not scale away the part that is NOT distributed over ranks"

# --- 3. the request never sits below the prediction ------------------------
# Under-requesting is the one error SLURM turns into an OOM kill at hour six.
"$WP_PY" - "$TK_DIR" <<'PY' > "$W/geom.out" 2>&1
import sys, itertools
sys.path.insert(0, sys.argv[1])
from vasp_test_recommend import geometry
bad, n = [], 0
for total, cpn, use, nodemem, util, kpar, cap in itertools.product(
        [8, 48, 144, 190], [8, 48, 128], [300.0, 1600.0, 6400.0],
        [7000, 192000, 384000], [0.8, 0.95], [1, 8, 72], [240, 4096]):
    if kpar > total:
        continue
    mpc, nodes, ntpn = geometry(total, cpn, use, nodemem, mem_util=util,
                                kpar=kpar, max_cores=cap)
    n += 1
    tag = f"total={total} cpn={cpn} use={use} nodemem={nodemem} util={util} kpar={kpar}"
    # R1. never ask for less than the prediction: that is an OOM by arithmetic.
    if mpc < use and ntpn > 1:
        bad.append(f"{tag}: requests {mpc} MB/cpu for a predicted {use} MB/rank")
    # R2. never ask a node for more than it has.
    if mpc * ntpn > nodemem:
        bad.append(f"{tag}: {ntpn} x {mpc} MB exceeds the node's {nodemem} MB")
    # R3. the layout must still hold the job.
    if nodes * ntpn < total:
        bad.append(f"{tag}: {nodes}x{ntpn} cannot hold {total} ranks")
print(f"COUNT {n}"); [print("VIOLATION", b) for b in bad[:10]]; print(f"BAD {len(bad)}")
PY
cnt=$(sed -n 's/^COUNT //p' "$W/geom.out"); bad=$(sed -n 's/^BAD //p' "$W/geom.out")
if [[ "$bad" == 0 ]]; then
    pass "$cnt sizings swept: none under-requests, none oversubscribes a node"
else
    fail "$bad of $cnt sizings break a request rule"
    grep '^VIOLATION' "$W/geom.out" | head -4 | while read -r l; do info "    $l"; done
fi

# --- 4. the rewritten job script, and what it claims -----------------------
# 190 ranks over 4 nodes is 47.5 per node. The directive the recommender left
# behind must be replaced by one that is TRUE, or by the comment saying why
# there isn't one -- never left as it was.
cat > "$W/slurm.sh" <<'EOF'
#!/bin/bash
#SBATCH --job-name=wp
#SBATCH --nodes=190
#SBATCH --ntasks=190
#SBATCH --ntasks-per-node=1
#SBATCH --mem-per-cpu=7600
#SBATCH --time=01:00:00
srun vasp_std
EOF
"$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
from vasp_test_recommend import update_slurm
print(update_slurm('$W/slurm.sh', 6350, 4, 48, 190))" > "$W/upd.out" 2>&1
ok_if "grep -q True '$W/upd.out'" "stage 3 rewrote the production job script"
ok_if "grep -qE '^#SBATCH --nodes=4$' '$W/slurm.sh'" "the node count was updated (190 -> 4)"
ok_if "grep -qE '^#SBATCH --mem-per-cpu=6350$' '$W/slurm.sh'" "the memory request was updated from the measurement"
ok_if "! grep -qE '^#SBATCH --ntasks-per-node=' '$W/slurm.sh'" \
      "the stale --ntasks-per-node=1 is GONE, not left contradicting --nodes=4"
ok_if "grep -qE '^# no --ntasks-per-node' '$W/slurm.sh'" \
      "and the script says why there is no such directive"
ok_if "grep -q 'updated by vasp-test' '$W/slurm.sh'" \
      "the script records that a benchmark rewrote it"

# An exact geometry must get the directive BACK: withholding it always would
# pass the check above for the wrong reason.
cat > "$W/exact.sh" <<'EOF'
#!/bin/bash
#SBATCH --nodes=190
#SBATCH --ntasks=192
#SBATCH --ntasks-per-node=1
#SBATCH --mem-per-cpu=7600
srun vasp_std
EOF
"$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
from vasp_test_recommend import update_slurm
update_slurm('$W/exact.sh', 6350, 4, 48, 192)" >/dev/null 2>&1
ok_if "grep -qE '^#SBATCH --ntasks-per-node=48$' '$W/exact.sh'" \
      "when 4 x 48 = 192 really is the rank count, the directive IS written"

# --- 5. a live scheduler has the last word ---------------------------------
if have_slurm; then
    # Submitted AS STAGE 3 LEFT IT -- no flags of ours on the command line, or
    # the command line would be what the scheduler judged, not the script.
    # 4 x 48 ranks at 6350 MB/cpu is 304800 MB of a 384000 MB node: it fits.
    sed -i 's|^srun vasp_std|echo benchmark|' "$W/exact.sh"
    printf '#SBATCH --time=00:01:00\n' >> "$W/exact.sh"
    out=$(cd "$W" && SLURM_CONF="$TESTBED_ROOT/slurm.conf" \
          sbatch --test-only exact.sh 2>&1); rc=$?
    if (( rc == 0 )); then
        pass "a real slurmctld accepts the script stage 3 rewrote"
    else
        fail "the rewritten script was REJECTED by slurmctld: $(tail -1 <<<"$out")"
    fi
else
    skip "no reachable slurmctld: the rewritten script was not submitted"
fi

exit $(( FAIL_N > 0 ))
