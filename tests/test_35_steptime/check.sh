#!/usr/bin/env bash
# test_35_steptime -- how long the next chunk takes, from what a run measured
# (wolfpack_steptime.sh). The fixtures carry the numbers of real VASP 6.5.1
# runs of this suite: silicon and bcc iron, 4 ranks.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/steptime"; rm -rf "$W"; mkdir -p "$W"
ST="$TK_DIR/wolfpack_steptime.sh"
val(){ sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" <<<"$2" | head -1; }

# mk NAME NELMDL "dE d_eps;dE d_eps;..." [LOOP_S] [F_AFTER]
# An OUTCAR and OSZICAR holding those electronic steps, each LOOP_S seconds;
# F_AFTER closes an ionic step after that many (a LOOP+ of their sum + 0.8 s).
mk(){
    local d="$W/$1" dl="$2" steps="$3" t="${4:-2.0}" fa="${5:-0}"
    mkdir -p "$d"
    awk -v dl="$dl" -v steps="$steps" -v t="$t" -v fa="$fa" -v oc="$d/OUTCAR" -v oz="$d/OSZICAR" 'BEGIN{
        print " vasp.6.5.1 10Mar25 (build fixture) complex" > oc
        printf "   NELM   =     60;   NELMIN=  2; NELMDL= %d     # of ELM steps \n", dl > oc
        print "   EDIFF  = 0.1E-05   stopping-criterion for ELM" > oc
        print "       N       E                     dE             d eps       ncg     rms" > oz
        n = split(steps, s, ";"); k = 0; sum = 0
        for (i = 1; i <= n; i++) { if (s[i] == "") continue
            split(s[i], v, " "); k++
            printf "DAV: %3d    -0.108000000000E+02    %s   %s  2000   0.1E+00\n", k, v[1], v[2] > oz
            printf "      LOOP:  cpu time      %.4f: real time      %.4f\n", t, t > oc; sum += t
            if (fa > 0 && k == fa) {
                printf "     LOOP+:  cpu time     %.4f: real time     %.4f\n", sum + 0.8, sum + 0.8 > oc
                print "   1 F= -.10745928E+02 E0= -.10745849E+02  d E =-.107459E+02" > oz
                k = 0; sum = 0 } } }'
    echo "$d"
}
SI="0.51600E+01 -0.28452E+03;-0.15881E+02 -0.15290E+02;-0.21058E+00 -0.21058E+00;-0.95825E-03 -0.95825E-03;-0.73502E-06 -0.73524E-06;0.12915E+00 -0.85282E-02;0.58503E-01 -0.16164E-01;-0.10951E-02 -0.44555E-03;-0.18262E-03 -0.18349E-04;-0.34642E-04 -0.41054E-05;0.14218E-06 -0.15866E-06"
FE="0.16987E+02 -0.33262E+03;-0.25503E+02 -0.23189E+02;-0.62128E+00 -0.61480E+00;-0.22530E-02 -0.22527E-02;-0.14167E-04 -0.14167E-04;0.82387E+00 -0.11197E+01;0.72742E-01 -0.80542E-01;0.66568E-02 -0.10089E-02;0.66989E-02 -0.81400E-03;0.47135E-04 -0.13616E-03;-0.12502E-04 -0.80929E-05;0.22216E-05 -0.77971E-06;-0.55419E-05 -0.26954E-06;0.15356E-05 -0.27774E-07;-0.21968E-06 -0.15727E-08"
first_k(){ awk -v k="$2" 'BEGIN{ n = split(ARGV[1], a, ";"); for (i = 1; i <= k; i++) printf "%s;", a[i]; ARGV[1] = "" }' "$1"; }

# ===========================================================================
# 1. EXTRAPOLATING THE FIRST IONIC STEP -- real silicon, cut off
# ===========================================================================
# The real step took 11 electronic steps. Steps 1-5 are NELMDL = -5's delay:
# their dE falls to 7e-7 with the Hamiltonian held fixed, then jumps to 0.13
# at step 6. Cut at 8: the fit uses 6, 7, 8 (0.129, 0.0585, 0.0011: about one
# decade a step) -> 3 more to 1e-6, + 2 margin = 13.
d=$(mk si8 -5 "$(first_k "$SI" 8)")
o=$("$ST" first "$d/OUTCAR" "$d/OSZICAR" 1 0)
ok_if "[[ \$(val nel_first '$o') == 13 ]] && grep -q '8 done + 3 to reach EDIFF=1e-06 at 1.04 decades/step + 2 margin' <<<\"\$o\"" \
      "silicon cut at step 8: 8 done + 3 to EDIFF + 2 = 13 (it took 11)"
d=$(mk si5 -5 "$(first_k "$SI" 5)")
o=$("$ST" first "$d/OUTCAR" "$d/OSZICAR" 1 0)
ok_if "[[ \$(val nel_first '$o') == 60 ]] && grep -q 'too few to extrapolate' <<<\"\$o\"" \
      "cut inside the delay (step 5, dE already 7e-7): not read as converged -- NELM, and why"
over=""; for k in 8 9 10; do
    d=$(mk "si$k" -5 "$(first_k "$SI" "$k")")
    over="$over $("$ST" first "$d/OUTCAR" "$d/OSZICAR" 1 0 | sed -n 's/^nel_first=//p')"
done
ok_if "[[ '$over' == ' 13 14 14' ]]" "silicon cut at 8, 9, 10: 13, 14, 14 -- never under the 11 it took (got$over)"

# Iron, the hard case: fast, then a slow tail near EDIFF (15 steps).
fe=""; for k in 8 9 10 11 12 13 14; do
    d=$(mk "fe$k" -5 "$(first_k "$FE" "$k")")
    fe="$fe $("$ST" first "$d/OUTCAR" "$d/OSZICAR" 1 0 | sed -n 's/^nel_first=//p')"
done
worst=$(awk -v l="$fe" 'BEGIN{ n = split(l, a, " "); w = 99; for (i = 1; i <= n; i++) if (a[i] - 15 < w) w = a[i] - 15; print w }')
ok_if "(( worst >= -2 ))" \
      "iron cut at 8-14 (it took 15):$fe -- at worst $worst steps short, within the 2 the margin allows"

# ===========================================================================
# 2. WHAT IS NOT EXTRAPOLATED
# ===========================================================================
d=$(mk flat -5 "1E+02 1E+02;1E+01 1E+01;1E+00 1E+00;1E-01 1E-01;1E-02 1E-02;0.10E+00 0.10E+00;0.11E+00 0.11E+00;0.10E+00 0.10E+00;0.12E+00 0.12E+00")
o=$("$ST" first "$d/OUTCAR" "$d/OSZICAR" 1 0)
ok_if "[[ \$(val nel_first '$o') == 60 ]] && grep -q 'not converging' <<<\"\$o\"" \
      "an SCF that is not falling: NELM (60), and why"
# With a WAVECAR, NELMDL = 0: no delay, every step counts.
d=$(mk warm 0 "0.1E+00 0.1E+00;0.1E-01 0.1E-01;0.1E-02 0.1E-02")
o=$("$ST" first "$d/OUTCAR" "$d/OSZICAR" 1 0)
ok_if "[[ \$(val nel_first '$o') == 8 ]]" "NELMDL = 0: 3 done + 3 to EDIFF + 2 = 8, no step skipped as a delay"
# RMM-DIIS and CG lines are read like Davidson's.
d=$(mk rmm 0 "0.1E+00 0.1E+00;0.1E-01 0.1E-01;0.1E-02 0.1E-02")
sed -i -e '2s/^DAV:/RMM:/' -e '3s/^DAV:/CG :/' "$d/OSZICAR"
o=$("$ST" first "$d/OUTCAR" "$d/OSZICAR" 1 0)
ok_if "[[ \$(val nel_first '$o') == 8 ]]" "RMM: and 'CG :' lines are read like DAV:"

# ===========================================================================
# 3. THE ESTIMATE OF A CHUNK
# ===========================================================================
# vasp-test completed nothing: step = 13 x 2.0 + 2.0 (the forces taken as one
# more electronic step) = 28 s; NSW = 2, start-up 10 s: 10 + 28 + 28 = 66 s.
d=$(mk est -5 "$(first_k "$SI" 8)" 2.0)
o=$("$ST" first "$d/OUTCAR" "$d/OSZICAR" 2 10)
ok_if "[[ \$(val t1_s '$o') == 28.0 && \$(val est_s '$o') == 66.0 ]]" \
      "chunk 1: 10 s start-up + 2 x 28 s = 66 s (got $(val est_s "$o"))"
ok_if "[[ \$(\"$ST\" walltime 66 1.15 5) == 7 && \$(\"$ST\" walltime 52.1739 1.15 5) == 6 ]]" \
      "walltime: 66 s x 1.15 = 75.9 s -> 2 min + 5 = 7; exactly 60 s -> 1 min + 5 = 6"

# A completed run: the next chunk from its own LOOP+ times. The real silicon
# relaxation: 6 ionic steps, 28.24 14.93 14.53 10.13 8.21 5.87 s.
d="$W/si_full"; mkdir -p "$d"
{
    echo " vasp.6.5.1"; echo "   NELM   =     60;   NELMIN=  2; NELMDL= -5     # of ELM steps "
    echo "   EDIFF  = 0.1E-05   stopping-criterion for ELM"
    for t in 28.237 14.934 14.532 10.130 8.207 5.873; do
        echo "      LOOP:  cpu time      2.0000: real time      2.0000"
        echo "     LOOP+:  cpu time     $t: real time     $t"
    done
    echo " reached required accuracy - stopping structural energy minimisation"
} > "$d/OUTCAR"
{ for i in 1 2 3 4 5 6; do echo "DAV:   1    -0.10E+02   -0.1E-06   -0.1E-06  100   0.1E-01"; echo "   $i F= -.10745928E+02"; done; } > "$d/OSZICAR"
o=$("$ST" next "$d/OUTCAR" "$d/OSZICAR" 2 84.0)
# start-up = 84.0 - 81.913 = 2.1; later steps: mean of 14.93..5.87 = 10.7
ok_if "[[ \$(val startup_s '$o') == 2.1 && \$(val t1_s '$o') == 28.24 && \$(val tr_s '$o') == 10.7 && \$(val est_s '$o') == 41.0 ]]" \
      "the next chunk from a real run: 2.1 s start-up + 28.24 + 10.7 = 41.0 s (got $(val est_s "$o"))"
ok_if "[[ \$(val reached '$o') == 1 ]]" "and it sees VASP's 'reached required accuracy'"

# The next chunk carries a WAVECAR: its first step is taken as a cold start,
# COLD_NEL = 11 electronic steps at this run's pace. t_e = 2.0 s; the overhead
# per ionic step is the median of LOOP+ - sum(LOOP) = 26.237 12.934 12.532
# 8.130 6.207 3.873 -> (8.130 + 12.532)/2 = 10.331 s. So 11 x 2.0 + 10.331 =
# 32.3 s, and 2.1 + 32.3 + 10.7 = 45.1 s.
o=$("$ST" next "$d/OUTCAR" "$d/OSZICAR" 2 84.0 11)
ok_if "[[ \$(val t1_s '$o') == 32.3 && \$(val nel_first '$o') == 11 && \$(val est_s '$o') == 45.1 ]] && grep -q 'as a cold start: 11 electronic steps' <<<\"\$o\"" \
      "carrying a WAVECAR: the first step as a cold start, 11 x 2.0 + 10.331 = 32.3 s; 45.1 s in all (got $(val est_s "$o"))"

# A retry: one ionic step completed (8 steps of 2.0 s, LOOP+ 16.8 s), the next
# cut after 3 (0.1, 0.01, 0.001): 3 + 3 + 2 = 8 steps x 2.0 + 0.8 = 16.8 s.
d=$(mk retry -5 "1E+02 1E+02;1E+01 1E+01;1E+00 1E+00;1E-01 1E-01;1E-02 1E-02;1E-03 1E-03;1E-05 1E-05;1E-07 1E-07;0.1E+00 0.1E+00;0.1E-01 0.1E-01;0.1E-02 0.1E-02" 2.0 8)
o=$("$ST" retry "$d/OUTCAR" "$d/OSZICAR" 2 5 0)
ok_if "[[ \$(val t1_s '$o') == 16.80 && \$(val tr_s '$o') == 16.8 && \$(val est_s '$o') == 38.6 ]]" \
      "a retry: the completed step measured (16.8 s), the cut one extrapolated (16.8 s), 5 + 16.8 + 16.8 = 38.6 s"

exit $(( FAIL_N > 0 ))
