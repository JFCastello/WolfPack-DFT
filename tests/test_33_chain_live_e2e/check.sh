#!/usr/bin/env bash
# test_33_chain_live_e2e -- vasp-relax-loop on a real scheduler with a real
# VASP, after the real pipeline: vasp-dry-run, vasp-recommend-slurm,
# vasp-test --full-size. The chain relaxes silicon in chunks of NSW = 2 until
# VASP reports "reached required accuracy", and the result is compared with
# one direct VASP run of the same relaxation.
#
# The fake harness (test_36) proves the decisions. This proves the plumbing
# they rest on, and measures what matters most: how close each chunk's
# walltime estimate came to the time it actually used.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
have_vasp      || { skip "no VASP -- the live chain goes untested"; exit 0; }
have_potcar Si || { skip "no Si POTCAR -- the live chain goes untested"; exit 0; }
have_slurm     || { skip "no reachable slurmctld -- run tests/slurm_testbed.sh start"; exit 0; }
export SLURM_CONF="$TESTBED_ROOT/slurm.conf"
W="$WORK/chainlive"; rm -rf "$W"; mkdir -p "$W"

# Si with one atom pushed off its site (the case of test_16), 6x6x6 k-points.
_setup(){ # _setup DIR NSW
    local d="$1"; mkdir -p "$d"
    awk 'NR==10 { printf "   0.7700000000  0.7600000000  0.7500000000 Si\n"; next } { print }' \
        "$CASES/Si/POSCAR" > "$d/POSCAR"
    printf 'Auto\n0\nGamma\n6 6 6\n0 0 0\n' > "$d/KPOINTS"
    cat "$WP_POTCAR_DIR/Si/POTCAR" > "$d/POTCAR"
    cat > "$d/INCAR" <<EOF
SYSTEM = Si live chain
PREC   = Accurate
ENCUT  = 400
EDIFF  = 1E-6
EDIFFG = -0.01
ISMEAR = 0 ; SIGMA = 0.05
IBRION = 2
ISIF   = 2
NSW    = $2
NELM   = 60
EOF
}
cat > "$W/cluster.conf" <<EOF
WP_VASP_STD="$WP_VASP"
WP_VASP_MODULES=""
WP_MAIN_PARTITION="local"
WP_DEBUG_PARTITION="local"
WP_MAIN_CPUS_PER_NODE="8"
WP_DEBUG_CPUS_PER_NODE="8"
WP_MAIN_MEM_PER_NODE_MB="6000"
WP_DEBUG_MEM_PER_NODE_MB="6000"
WP_MAX_CORES="4"
WP_DEBUG_MAX_CORES="4"
WP_ALLOC_PROFILE="balanced"
WP_MEM_UTIL="0.81"
WP_MEM_UTIL_MIN="0.80"
WP_MAIN_MEM_MARGIN="0.02"
WP_DEBUG_MEM_MARGIN="0.05"
WP_TEST_WALLTIME_MIN="3"
EOF
export WOLFPACK_CLUSTER_CONF="$W/cluster.conf"

# --- the reference: one direct run ----------------------------------------------
_setup "$W/direct" 30
( cd "$W/direct" && OMP_NUM_THREADS=1 timeout 900 mpirun -np 4 "$WP_VASP" > vasp.log 2>&1 )
e_direct=$(grep -oP 'F= *\K-?[0-9.E+]+' "$W/direct/OSZICAR" | tail -1)
n_direct=$(grep -c 'F=' "$W/direct/OSZICAR")
ok_if "grep -q 'reached required accuracy' '$W/direct/OUTCAR'" \
      "the reference relaxation converged in one run (${n_direct} ionic steps, E = ${e_direct} eV)"

# --- the pipeline, then the chain ----------------------------------------------------
d="$W/si"; _setup "$d" 2
cd "$d" || exit 1
timeout 300 bash "$TK_DIR/vasp_dry_run.sh" > dry.log 2>&1
for _ in $(seq 1 60); do [[ -s .wolfpack/dryrun_OUTCAR ]] && break; sleep 2; done
# 4 ranks, as the reference run: on this 8-core laptop 8 ranks are 5 x slower per step.
timeout 300 "$WP_PY" "$TK_DIR/vasp_recommend_slurm.py" --min-cores 4 --max-cores 4 > rec.log 2>&1
ok_if "[[ -s slurm.sh ]]" "stage 2 chose a layout ($(grep -oP '(?<=--ntasks=)\d+' slurm.sh 2>/dev/null | head -1) ranks)"
[[ -s slurm.sh ]] || exit 1
timeout 300 bash "$TK_DIR/vasp_test.sh" --full-size > test.log 2>&1
for _ in $(seq 1 150); do [[ -s .wolfpack/vasptest_OSZICAR && -s slurm_vasptest.sh ]] && break; sleep 2; done
ok_if "[[ -s .wolfpack/vasptest_OSZICAR && -s .wolfpack/vasptest_OUTCAR ]]" \
      "vasp-test --full-size kept its OUTCAR and OSZICAR for the chain"
[[ -s .wolfpack/vasptest_OSZICAR ]] || exit 1
ok_if "grep -q 'test_full_size=\"1\"' .wolfpack/state.env && [[ \$(grep -oP 'test_ranks=\"\K[0-9]+' .wolfpack/state.env | tail -1) == \$(grep -oP '(?<=--ntasks=)\d+' slurm_vasptest.sh | head -1) ]]" \
      "and measured at the production rank count"
_su=$(grep -oP 'test_startup_s="\K[0-9.]+' .wolfpack/state.env | tail -1)
ok_if "awk -v s='${_su:-0}' 'BEGIN{exit !(s>0)}'" \
      "its start-up time is no longer clamped to 0 when an ionic step completed (${_su:-?} s)"

out=$(timeout 120 bash "$TK_DIR/vasp_relax_loop.sh" --max-ionic 40 2>&1); rc=$?
echo "$out" > launch.log
ok_if "(( rc == 0 ))" "the chain launches on the live scheduler (rc=$rc)"
(( rc == 0 )) || exit 1
state(){ sed -n "s/^$1=\"\(.*\)\"$/\1/p" wolfpack_chain/chain.env | head -1; }
for _ in $(seq 1 540); do
    case "$(state chain_state)" in converged|stopped) break ;; esac
    sleep 5
done
cp relax_progress.txt "$W/progress.txt" 2>/dev/null
info "$(sed 's/^/    /' relax_progress.txt)"
ok_if "[[ '$(state chain_state)' == converged ]]" \
      "the chain converged: VASP's 'reached required accuracy' ($(state chain_state) $(state stop_reason))"

# --- plumbing -----------------------------------------------------------------------
n=$(ls -d wolfpack_chain/[0-9][0-9][0-9] 2>/dev/null | wc -l)
bad=0
for i in $(seq 2 "$n"); do
    a=$(printf 'wolfpack_chain/%03d' $((i-1))); b=$(printf 'wolfpack_chain/%03d' "$i")
    cmp -s "$a/CONTCAR" "$b/POSCAR" || bad=$((bad+1))
done
ok_if "(( n >= 2 && bad == 0 ))" "each of the ${n} chunks started from the CONTCAR of the one before"
ok_if "cmp -s POSCAR '$W/direct/POSCAR' && cmp -s CONTCAR \"wolfpack_chain/\$(printf %03d $n)/CONTCAR\"" \
      "the folder's POSCAR is still the input; its CONTCAR is the last chunk's"
tmo=$(awk -F'\t' '$12 ~ /TIMEOUT|OOM|DIED/' wolfpack_chain/progress.rows | wc -l)
ok_if "(( tmo == 0 ))" "no chunk ran out of its walltime or memory (${tmo} did)"

# --- the estimates against what the chunks did -----------------------------------------
# Two estimates per chunk, of different kinds. The electronic steps of its first
# ionic step (est.e) is the method's own prediction, and does not depend on the
# machine. The time is that count times the seconds per electronic step, and
# inherits however repeatable the machine is -- which is measured here too, from
# VASP's own LOOP lines, not assumed.
sec(){ awk -F: '{ print $1*3600 + $2*60 + $3 }' <<<"$1"; }
info "    chunk  est.e  e-steps  estimate  used  used/estimate"
worst=0; short=0
while IFS=$'\t' read -r ch tr ns io ge ne ee es as us en fm re; do
    [[ $re == ok || $re == CONVERGED ]] || continue
    first=${ne%% *}
    (( ee - first < -2 )) && short=$((short+1))
    e=$(sec "$es"); u=$(sec "$us")
    r=$(awk -v u="$u" -v e="$e" 'BEGIN{ printf "%.2f", (e > 0 ? u/e : 0) }')
    info "    $(printf '%5s %6s %8s %8ss %5ss %8s' "$ch" "$ee" "$first" "$e" "$u" "$r")"
    awk -v r="$r" -v w="$worst" 'BEGIN{exit !(r > w)}' && worst=$r
done < wolfpack_chain/progress.rows
ok_if "(( short == 0 ))" \
      "the electronic steps of each chunk's first ionic step were never under-estimated by more than the 2-step margin"
spread=$(cat wolfpack_chain/[0-9][0-9][0-9]/OUTCAR | awk '/LOOP:/{ k = split($0, a, "real time"); v = a[2] + 0
             if (mn == "" || v < mn) mn = v; if (v > mx) mx = v } END{ printf "%.1f-%.1f", mn, mx }')
info "    seconds per electronic step on this machine, across the chunks (VASP's LOOP): ${spread}"
info "    the largest used/estimate: ${worst} -- what the walltime's x 1.15 + 5 min has to absorb"

# --- the answer against the direct run ------------------------------------------------
e_chain=$(grep -oP 'F= *\K-?[0-9.E+]+' OSZICAR | tail -1)
de=$(awk -v a="$e_chain" -v b="$e_direct" 'BEGIN{d=a-b; if(d<0)d=-d; printf "%.6f", d}')
ok_if "awk -v d='$de' 'BEGIN{exit !(d < 0.002)}'" \
      "the chain and the direct run agree in energy (|dE| = ${de} eV; chain ${e_chain}, direct ${e_direct})"
dr=$("$WP_PY" - "$W/direct/CONTCAR" CONTCAR <<'PY'
import sys
def frac(p):
    L = open(p).read().split("\n"); s = float(L[1].split()[0])
    lat = [[float(x) * s for x in L[i].split()[:3]] for i in (2, 3, 4)]
    n = sum(int(x) for x in L[6].split())
    return lat, [[float(x) for x in L[8 + i].split()[:3]] for i in range(n)]
la, a = frac(sys.argv[1]); _, b = frac(sys.argv[2])
m = 0
for p, q in zip(a, b):
    d = [((x - y + 0.5) % 1) - 0.5 for x, y in zip(p, q)]
    c = [sum(d[k] * la[k][j] for k in range(3)) for j in range(3)]
    m = max(m, sum(v * v for v in c) ** 0.5)
print("%.4f" % m)
PY
)
ok_if "awk -v d='${dr:-9}' 'BEGIN{exit !(d < 0.01)}'" \
      "and in structure (max |dr| = ${dr} A)"
geoms=$(state geoms_done); scfs=$(state scf_total)
info "    the direct run: ${n_direct} ionic steps; the chain: ${n} chunks, ${geoms} geometries, ${scfs} SCF runs"

exit $(( FAIL_N > 0 ))
