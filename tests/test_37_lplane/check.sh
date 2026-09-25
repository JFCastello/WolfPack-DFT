#!/usr/bin/env bash
# test_37_lplane -- LPLANE, as https://vasp.at/wiki/LPLANE sets it: from the
# grid (NGZ), the band group (NCORE) and the network the nodes share; written
# into the INCAR with KPAR and NCORE; and checked by vasp-test on what the
# benchmark really ran.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/lplane"; rm -rf "$W"; mkdir -p "$W"
HW="$TK_DIR/wolfpack_hw.sh"; REC="$TK_DIR/vasp_recommend_slurm.py"; HELPER="$TK_DIR/vasp_test_recommend.py"

# ===========================================================================
# 1. THE NETWORK, FROM /sys
# ===========================================================================
_ib(){ # _ib ROOT DEV LINK_LAYER STATE RATE
    mkdir -p "$1/class/infiniband/$2/ports/1"
    echo "$3" > "$1/class/infiniband/$2/ports/1/link_layer"
    echo "$4" > "$1/class/infiniband/$2/ports/1/state"
    echo "$5" > "$1/class/infiniband/$2/ports/1/rate"
}
_net(){ mkdir -p "$1/class/net/$2"; [[ -n ${3:-} ]] && echo "$3" > "$1/class/net/$2/speed"; }
hw(){ WP_SYSFS="$1" bash "$HW" interconnect; }

s="$W/sys_ib"; _ib "$s" mlx5_0 InfiniBand "1: DOWN" "10 Gb/sec (4X)"; _ib "$s" mlx5_1 InfiniBand "4: ACTIVE" "100 Gb/sec (4X EDR)"; _net "$s" eth0 1000
ok_if "[[ \$(hw '$s') == 'infiniband|mlx5_1, 100 Gb/sec (4X EDR), ACTIVE|' ]]" \
      "InfiniBand: the ACTIVE port, with its rate (got $(hw "$s"))"
s="$W/sys_opa"; _ib "$s" hfi1_0 InfiniBand "4: ACTIVE" "100 Gb/sec (4X EDR)"
ok_if "[[ \$(hw '$s') == omnipath\\|* ]]" "an hfi1 device is Omni-Path"
s="$W/sys_roce"; _ib "$s" mlx5_0 Ethernet "4: ACTIVE" "25 Gb/sec (1X EDR)"
ok_if "[[ \$(hw '$s') == roce\\|* ]]" "an RDMA port whose link layer is Ethernet is RoCE"
s="$W/sys_cxi"; mkdir -p "$s/class/cxi/cxi0"; _net "$s" hsn0 200000
ok_if "[[ \$(hw '$s') == 'slingshot|cxi0|' ]]" "a CXI device is Slingshot"
s="$W/sys_eth"; _net "$s" lo; _net "$s" eno1 1000; _net "$s" veth0 -1
ok_if "[[ \$(hw '$s') == 'ethernet|eno1 1000 Mb/s|1000' ]]" "no RDMA device: Ethernet, and its speed (got $(hw "$s"))"
s="$W/sys_none"; mkdir -p "$s/class"
ok_if "[[ \$(hw '$s') == 'unknown||' ]]" "nothing to read: unknown, not a guess"

# ===========================================================================
# 2. THE RULE: NGZ >= 3 x NCORE, and .TRUE. on 1 Gbit Ethernet
# ===========================================================================
rule(){ "$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
import vasp_recommend_slurm as R
R.NETWORK.update(kind='$3', speed_mbs=${4:-None})
lp, why = R.lplane_for($1, $2)
print(lp, '|', why)"; }
ok_if "[[ \$(rule 28 4 infiniband) == 'True | NGZ = 28 >= 3 x NCORE = 12: plane-wise, the VASP default' ]]" \
      "NGZ 28, NCORE 4: .TRUE. (28 >= 12)"
ok_if "[[ \$(rule 20 8 infiniband) == 'False | NGZ = 20 < 3 x NCORE = 24: plane-wise would leave ranks with fewer than 3 planes' ]]" \
      "NGZ 20, NCORE 8: .FALSE. (20 < 24)"
ok_if "[[ \$(rule 20 8 ethernet 1000) == None\\ \\|* ]]" \
      "the same on 1 Gbit Ethernet: no LPLANE is allowed (it must be .TRUE.), the layout goes"
ok_if "[[ \$(rule 20 8 ethernet 10000) == False\\ \\|* ]]" \
      "10 Gbit Ethernet is not the page's '1 Gbit' case: the NGZ rule alone"
ok_if "[[ \$(rule 0 8 infiniband) == True\\ \\|\\ NGZ\\ unknown* ]]" "no grid in the dry run: the VASP default, and it says so"

# ===========================================================================
# 3. END TO END: the recommendation, the INCAR, the state
# ===========================================================================
CONF="$W/cluster.conf"
cat > "$CONF" <<'EOF'
WP_VASP_STD="vasp_std"
WP_MAIN_PARTITION="main"
WP_DEBUG_PARTITION="debug"
WP_MAIN_CPUS_PER_NODE="48"
WP_DEBUG_CPUS_PER_NODE="48"
WP_MAIN_MEM_PER_NODE_MB="192000"
WP_DEBUG_MEM_PER_NODE_MB="192000"
WP_MAX_CORES="48"
WP_MAIN_NUMA_CORES="24"
WP_ALLOC_PROFILE="whole-nodes"
WP_INTERCONNECT="infiniband"
WP_INTERCONNECT_DETAIL="mlx5_0, 100 Gb/sec (4X EDR), ACTIVE"
EOF
_calc(){ # _calc NAME NGZ -> a folder after the dry run, 1 k-point, 480 bands
    local d="$W/$1"; mkdir -p "$d/.wolfpack"
    cat > "$d/.wolfpack/dryrun_OUTCAR" <<EOF
 vasp.6.5.1 test
 Found      1 irreducible k-points:
   k-points           NKPTS =      1   k-points in BZ     NKDIM =      1   number of bands    NBANDS=    480
   number of dos      NEDOS =    301   number of ions     NIONS =    100
   dimension x,y,z NGX =    96 NGY =   96 NGZ =   $2
   dimension x,y,z NGXF=   192 NGYF=  192 NGZF=  $(( $2 * 2 ))
   support grid    NGXF=   192 NGYF=  192 NGZF=  $(( $2 * 2 ))
   ions per type =              100
  k-point   1 :  0.0000 0.0000 0.0000  plane waves:   90000
   total plane-waves  NPLWV = 480000
EOF
    printf 'SYSTEM = lplane\nENCUT = 400\nLPLANE = .FALSE.\n' > "$d/INCAR"
    printf 'stage="dryrun"\ndryrun_outcar=".wolfpack/dryrun_OUTCAR"\n' > "$d/.wolfpack/state.env"
    echo "$d"
}
recd(){ ( cd "$1" && WOLFPACK_CLUSTER_CONF="$CONF" "$WP_PY" "$REC" --calc-type dft "${@:2}" > rec.txt 2>&1 ); }
d=$(_calc tall 96); recd "$d"
nc=$(grep -oP '^NCORE +: \K[0-9]+' "$d/rec.txt")
ok_if "grep -qE '^LPLANE +: \\.TRUE\\. +\\(NGZ = 96 >= 3 x NCORE = [0-9]+: plane-wise, the VASP default\\)' '$d/rec.txt'" \
      "a tall grid (NGZ 96, NCORE $nc): .TRUE., with the reason printed"
ok_if "grep -q '^interconnect *: infiniband  (mlx5_0, 100 Gb/sec (4X EDR), ACTIVE)' '$d/rec.txt'" \
      "and the interconnect it assumed, from the profile"
ok_if "grep -qE '^[[:space:]]*LPLANE[[:space:]]*=[[:space:]]*\\.TRUE\\.' '$d/INCAR' && grep -q 'lplane=\".TRUE.\"' '$d/.wolfpack/state.env'" \
      "LPLANE is written into the INCAR (it said .FALSE.) and recorded for vasp-test"
d=$(_calc flat 12); recd "$d"
nc=$(grep -oP '^NCORE +: \K[0-9]+' "$d/rec.txt")
ok_if "(( nc > 4 )) && grep -qE '^LPLANE +: \\.FALSE\\. +\\(NGZ = 12 < 3 x NCORE = ' '$d/rec.txt' && grep -qE '^[[:space:]]*LPLANE[[:space:]]*=[[:space:]]*\\.FALSE\\.' '$d/INCAR'" \
      "a flat grid (NGZ 12) with NCORE $nc > 4: .FALSE., and it is written"
sed -i 's/^WP_INTERCONNECT=.*/WP_INTERCONNECT="ethernet"/; s/^WP_INTERCONNECT_DETAIL=.*/WP_ETH_SPEED_MBS="1000"/' "$CONF"
d=$(_calc flat_eth 12); recd "$d"
nc=$(grep -oP '^NCORE +: \K[0-9]+' "$d/rec.txt")
ok_if "[[ -n '$nc' ]] && (( nc <= 4 )) && grep -qE '^LPLANE +: \\.TRUE\\.' '$d/rec.txt' && grep -q '1 Gbit Ethernet: LPLANE must be .TRUE.' '$d/rec.txt'" \
      "on 1 Gbit Ethernet the same grid keeps .TRUE.: only band groups of NCORE <= 4 remain ($nc)"

# ===========================================================================
# 4. VASP-TEST: THE RULE ON WHAT THE BENCHMARK RAN
# ===========================================================================
# The lines as VASP 6.5.1 prints them (a Si run, 4 ranks, NCORE = 4, LREAL =
# Auto). The wiki calls the last block "real space projector functions"; VASP
# prints "real space projection operators:".
_bench(){ # _bench DIR NGZ NCORE -> an OUTCAR and the INCAR it ran
    mkdir -p "$1"
    cat > "$1/OUTCAR" <<EOF
 vasp.6.5.1 10Mar25 (build fixture) complex
 distrk:  each k-point on    4 cores,    1 groups
 distr:  one band on NCORE=   $3 cores,    1 groups
   dimension x,y,z NGX =    28 NGY =   28 NGZ =   $2
 real space projection operators:
  total allocation   :        735.12 KBytes
  max/ min on nodes  :        185.50        182.75
EOF
    printf 'ENCUT = 400\nLREAL = Auto\nLPLANE = .TRUE. ; NCORE = %s\n' "$3" > "$1/INCAR"
}
help(){ "$WP_PY" "$HELPER" "$1/OUTCAR" --maxrss-mb 200 --ntasks-test 4 --test-ncore "$2" \
          --test-npar $(( 4 / $2 )) --prod-ranks 4 --prod-ncore "$2" --cpus-per-node 8 \
          --node-mem-mb 8000 --lplane .TRUE. --incar-run "$1/INCAR" "${@:3}" 2>&1; }
b="$W/bench_ok"; _bench "$b" 28 4
out=$(help "$b" 4 --net-profile infiniband --net-node "infiniband|mlx5_0, 100 Gb/sec (4X EDR), ACTIVE|")
ok_if "grep -q '^\[LPLANE\]' <<<\"\$out\" && grep -q 'as run           : LPLANE = .TRUE.  (the benchmark.s INCAR); recommended .TRUE.' <<<\"\$out\"" \
      "vasp-test's report has an [LPLANE] block: what the benchmark ran, and what was recommended"
ok_if "grep -q 'NGZ = 28, NCORE = 4 (OUTCAR)  ->  NGZ >= 3 x NCORE = 12' <<<\"\$out\" && ! grep -q 'WARN' <<<\"\$out\"" \
      "NGZ and NCORE as VASP printed them, and the rule holds: no warning"
ok_if "grep -q 'real-space proj. : total 735.12 KBytes, max/min per rank 185.50 / 182.75  (x1.015)' <<<\"\$out\"" \
      "with LREAL on, the real-space projectors' max and min per rank, as VASP 6.5.1 prints them"
ok_if "grep -q 'interconnect     : profile infiniband; this compute node infiniband' <<<\"\$out\"" \
      "and the compute node's network next to the profile's"
b="$W/bench_bad"; _bench "$b" 20 4
out=$(help "$b" 4 --net-profile infiniband --net-node "ethernet|eth0 1000 Mb/s|1000")
ok_if "grep -q 'NGZ = 20, NCORE = 4 (OUTCAR)  ->  NGZ >= 3 x NCORE = 12' <<<\"\$out\"" "NGZ 20 with NCORE 4 still holds (20 >= 12)"
b="$W/bench_bad8"; _bench "$b" 20 8
out=$(help "$b" 8 --net-profile infiniband --net-node "ethernet|eth0 1000 Mb/s|1000")
ok_if "grep -q 'WARN\] LPLANE = .TRUE. with NGZ = 20 < 24' <<<\"\$out\"" \
      "LPLANE = .TRUE. run with NGZ 20 < 3 x NCORE 8: a warning quoting the page"
ok_if "grep -q \"WARN\] the recommendation assumed 'infiniband'\" <<<\"\$out\" && grep -q 'vasp-configure --interconnect ethernet' <<<\"\$out\"" \
      "a compute node whose network is not the profile's: said, with the commands to fix it"

exit $(( FAIL_N > 0 ))
