#!/usr/bin/env bash
###############################################################################
# wolfpack_steptime.sh -- how long the next VASP chunk will take, from what a
# run already measured. Used by vasp-relax-loop; also runnable on its own:
#
#   wolfpack_steptime.sh summary OUTCAR OSZICAR
#   wolfpack_steptime.sh first   OUTCAR OSZICAR NSW STARTUP_S
#   wolfpack_steptime.sh next    OUTCAR OSZICAR NSW WALL_S [COLD_NEL]
#   wolfpack_steptime.sh retry   OUTCAR OSZICAR NSW STARTUP_S FALLBACK_TREST_S
#
# Every mode prints key=value lines; `first`, `next` and `retry` end with
# est_s, the estimated seconds of a chunk of NSW ionic steps.
#
# Pure bash and awk on purpose: it runs inside the chunk job, on a compute
# node, where only VASP's modules are loaded.
#
# ------------------------------------------------------------------------------
# WHAT IS READ
#   OUTCAR   LOOP:  one electronic step, "real time" in seconds
#            LOOP+: one whole ionic step, its electronic steps INCLUDED
#                   (checked on VASP 6.5.1: 28.24 s against 26.98 s summed
#                   over its 11 LOOPs; the rest is forces and output)
#            NELM / NELMIN / NELMDL and EDIFF as VASP echoes them
#            "reached required accuracy", Elapsed time
#   OSZICAR  one line per electronic step: N, E, dE, d eps -- and "F=" at the
#            end of each ionic step
#
# THE ESTIMATE OF AN IONIC STEP
#   Completed: its LOOP+ time, measured.
#   Not completed (the run was cut off inside it): the electronic steps still
#   missing, extrapolated. VASP stops the SCF when |dE| and |d eps| are both
#   below EDIFF (vasp.at/wiki/index.php/EDIFF), so the convergence measure is
#   c = max(|dE|, |d eps|). log10(c) against the step number is fitted by
#   least squares over the self-consistent steps -- those after the NELMDL
#   delay, whose Hamiltonian is held fixed and whose dE says nothing about
#   self-consistency (NELMDL < 0: first ionic step only; > 0: every step) --
#   and the steps to reach EDIFF are read off the line, plus EXTRA_STEPS.
#   Fewer than 3 self-consistent points, or a line that does not fall, and
#   the estimate is NELM: the most VASP will do in one ionic step.
#   Missing steps x the median LOOP time + the step's force overhead (median
#   LOOP+ minus its LOOPs over completed steps; one LOOP time when no step
#   has completed yet).
#
#   EXTRA_STEPS = 2 was chosen on 46 truncation points of 10 real VASP runs
#   in this suite (Si, Al, Fe, a magnetic case): without it 14 predictions
#   fell short, by up to 4 steps of 15 (a metal's slow tail near EDIFF);
#   with it 3 did, by at most 2, and the mean overshoot is 24 %.
###############################################################################

ST_EXTRA_STEPS="${ST_EXTRA_STEPS:-2}"

# st_summary OUTCAR OSZICAR -> key=value lines describing the run
st_summary(){
    awk -v fo="$1" -v extra="$ST_EXTRA_STEPS" '
        function abs(x) { return x < 0 ? -x : x }
        function median(a, n,   i, j, t, b) {
            if (n < 1) return 0
            for (i = 1; i <= n; i++) b[i] = a[i]
            for (i = 2; i <= n; i++) { t = b[i]; j = i - 1
                while (j >= 1 && b[j] > t) { b[j+1] = b[j]; j-- } b[j+1] = t }
            return (n % 2) ? b[(n+1)/2] : (b[n/2] + b[n/2+1]) / 2
        }
        FILENAME == fo {
            if ($0 ~ /LOOP:/ && split($0, a, "real time") > 1) {
                nl++; L[nl] = a[2] + 0; opensum += a[2] + 0; openn++
            } else if ($0 ~ /LOOP\+:/ && split($0, a, "real time") > 1) {
                np++; P[np] = a[2] + 0; O[np] = P[np] - opensum
                opensum = 0; openn = 0
            } else if ($0 ~ /NELM *=.*NELMIN *=.*NELMDL *=/) {
                s = $0; sub(/.*NELM *= */, "", s); nelm = s + 0
                s = $0; sub(/.*NELMIN *= */, "", s); nelmin = s + 0
                s = $0; sub(/.*NELMDL *= */, "", s); nelmdl = s + 0
            } else if ($0 ~ /EDIFF *=.*stopping-criterion for ELM/) {
                s = $0; sub(/.*EDIFF *= */, "", s); ediff = s + 0
            } else if ($0 ~ /reached required accuracy/) {
                reached = 1
            } else if ($0 ~ /Elapsed time \(sec\):/) {
                s = $0; sub(/.*: */, "", s); elapsed = s + 0
            }
            next
        }
        # OSZICAR: "DAV:  3  -0.109E+02  -0.21E+00  -0.21E+00  2224 ..."
        # (also RMM:, CG :, ...): after the colon, N E dE d_eps.
        /^[ \t]*[A-Za-z]+[ \t]*:[ \t]+[0-9]+[ \t]/ {
            s = $0; sub(/^[^:]*:/, "", s); split(s, f)
            c = abs(f[3] + 0); d = abs(f[4] + 0); if (d > c) c = d
            ne++; C[ne] = c
            next
        }
        /F=/ { nf++; NE[nf] = ne; ne = 0; next }
        END {
            if (nelm < 1) nelm = 60; if (nelmin < 1) nelmin = 2
            if (ediff <= 0) ediff = 1e-4
            done = np; if (nf < done) done = nf       # a step both files agree on
            te = median(L, nl)
            no = 0; for (i = 1; i <= done; i++) if (O[i] > 0) { no++; oo[no] = O[i] }
            ovh = median(oo, no); ovk = (no > 0)
            if (!ovk) ovh = te
            st = ""; sn = ""; sp = 0
            for (i = 1; i <= done; i++) { st = st (i > 1 ? " " : "") sprintf("%.2f", P[i])
                                          sn = sn (i > 1 ? " " : "") NE[i]; sp += P[i] }
            # the ionic step that was still running
            ototal = 0; obasis = ""
            if (ne > 0) {
                delay = 0
                if (nelmdl < 0 && done == 0) delay = -nelmdl
                if (nelmdl > 0) delay = nelmdl
                k = 0
                for (i = delay + 1; i <= ne; i++) if (C[i] > 0) { k++; X[k] = i; Y[k] = log(C[i]) / log(10) }
                if (k < 3) {
                    ototal = nelm
                    obasis = sprintf("NELM (%d): only %d self-consistent step(s) after the %d-step delay, too few to extrapolate", nelm, k, delay)
                } else {
                    xb = 0; yb = 0; for (i = 1; i <= k; i++) { xb += X[i]; yb += Y[i] }
                    xb /= k; yb /= k; sxy = 0; sxx = 0
                    for (i = 1; i <= k; i++) { sxy += (X[i]-xb)*(Y[i]-yb); sxx += (X[i]-xb)^2 }
                    slope = sxy / sxx
                    if (slope > -0.05) {
                        ototal = nelm
                        obasis = sprintf("NELM (%d): the SCF is not converging (%.2f decades/step over %d steps)", nelm, slope, k)
                    } else {
                        cl = C[ne]
                        if (cl <= ediff) more = 1
                        else { more = (log(cl)/log(10) - log(ediff)/log(10)) / (-slope)
                               more = (more == int(more)) ? more : int(more) + 1 }
                        ototal = ne + more + extra
                        if (ototal > nelm) ototal = nelm
                        if (ototal < nelmin) ototal = nelmin
                        if (ototal <= ne) ototal = ne + 1
                        obasis = sprintf("%d done + %d to reach EDIFF=%g at %.2f decades/step + %d margin", \
                                         ne, more, ediff, -slope, extra)
                    }
                }
            }
            printf "ionic_done=%d\n", done
            printf "step_times=\"%s\"\n", st
            printf "step_nel=\"%s\"\n", sn
            printf "loopplus_sum=%.2f\n", sp
            printf "t_e=%.3f\n", te
            printf "n_loops=%d\n", nl
            printf "overhead=%.3f\n", ovh
            printf "overhead_measured=%d\n", ovk
            printf "open_nel=%d\n", ne
            printf "open_total=%d\n", ototal
            printf "open_basis=\"%s\"\n", obasis
            printf "nelm=%d\nnelmin=%d\nnelmdl=%d\nediff=%g\n", nelm, nelmin, nelmdl, ediff
            printf "elapsed=%.1f\n", elapsed
            printf "reached=%d\n", reached + 0
        }' "$1" "$2" 2>/dev/null
}

# _st_combine STARTUP T1 TR NSW -> est_s
_st_combine(){ awk -v s="$1" -v a="$2" -v b="$3" -v n="$4" \
    'BEGIN{ if (n < 1) n = 1; printf "%.1f", s + a + (n - 1) * b }'; }

# st_estimate MODE OUTCAR OSZICAR NSW [STARTUP_S|WALL_S] [FALLBACK_TREST_S]
st_estimate(){
    local mode="$1" oc="$2" oz="$3" nsw="$4" a5="${5:-0}" a6="${6:-0}"
    local ionic_done=0 step_times="" step_nel="" loopplus_sum=0 t_e=0 n_loops=0 overhead=0
    local overhead_measured=0 open_nel=0 open_total=0 open_basis="" nelm=60 nelmin=2 nelmdl=0
    local ediff=0 elapsed=0 reached=0 kv
    while IFS= read -r kv; do
        [[ $kv == *=* ]] || continue
        local k="${kv%%=*}" v="${kv#*=}"; v="${v#\"}"; v="${v%\"}"
        printf -v "$k" '%s' "$v"
    done < <(st_summary "$oc" "$oz")

    local t1 tr t1_basis tr_basis startup open_s est
    open_s=$(awk -v n="$open_total" -v t="$t_e" -v o="$overhead" 'BEGIN{ printf "%.1f", n*t + o }')
    read -r -a _st <<<"$step_times"
    read -r -a _sn <<<"$step_nel"
    _rest_mean(){ awk -v l="$step_times" 'BEGIN{ n = split(l, a, " "); s = 0
                     for (i = 2; i <= n; i++) s += a[i]; printf "%.1f", (n > 1 ? s/(n-1) : 0) }'; }

    # the first ionic step of a chunk
    local nel1=""
    if [[ $mode == next ]] && (( $(printf '%.0f' "$a6") > 0 )) && awk -v t="$t_e" 'BEGIN{exit !(t>0)}'; then
        # The next chunk starts from a carried WAVECAR. How much it saves is not
        # predictable from this chunk: in a live Si chain the first step took 2
        # electronic steps three chunks running, then 7, from a WAVECAR VASP
        # wrote for the very CONTCAR it started from (a cold start took 11).
        # So the first step is taken as a cold one, COLD_NEL steps at this
        # run's pace: never short for that reason.
        nel1=$(printf '%.0f' "$a6")
        t1=$(awk -v n="$nel1" -v t="$t_e" -v o="$overhead" 'BEGIN{ printf "%.1f", n*t + o }')
        t1_basis="as a cold start: ${nel1} electronic steps (the first of chunk 1) x ${t_e} s + ${overhead} s; a carried WAVECAR saves an unpredictable part of them"
    elif (( ionic_done >= 1 )); then
        t1=${_st[0]}; t1_basis="measured: ${_sn[0]} electronic steps"
    elif (( open_nel > 0 )); then
        t1=$open_s; t1_basis="${open_total} electronic steps (${open_basis})"
    else
        t1=0; t1_basis="no electronic step was measured"
    fi
    # the later ones
    if (( ionic_done >= 2 )); then
        tr=$(_rest_mean); tr_basis="measured: mean of ionic steps 2-${ionic_done}"
    elif (( ionic_done == 1 && open_nel > 0 )); then
        tr=$open_s; tr_basis="${open_total} electronic steps (${open_basis})"
    elif [[ $mode == retry ]] && awk -v t="$a6" 'BEGIN{exit !(t>0)}'; then
        tr=$a6; tr_basis="the previous estimate"
    else
        tr=$t1; tr_basis="taken equal to the first"
    fi

    case $mode in
        next)
            # Everything that is not an ionic step: srun and VASP start-up,
            # reading and writing files. What the job's own clock measured
            # minus the steps.
            startup=$(awk -v w="$a5" -v p="$loopplus_sum" 'BEGIN{ r = w - p; if (r < 0) r = 0; printf "%.1f", r }') ;;
        *)  startup=$(awk -v s="$a5" 'BEGIN{ printf "%.1f", s + 0 }') ;;
    esac
    est=$(_st_combine "$startup" "$t1" "$tr" "$nsw")

    printf 'mode=%s\n' "$mode"
    printf 'nsw=%s\n' "$nsw"
    printf 't_e=%s\n' "$t_e"
    printf 'startup_s=%s\n' "$startup"
    printf 't1_s=%s\n' "$t1"
    printf 't1_basis="%s"\n' "$t1_basis"
    printf 'tr_s=%s\n' "$tr"
    printf 'tr_basis="%s"\n' "$tr_basis"
    printf 'nel_first=%s\n' "$( [[ -n $nel1 ]] && echo "$nel1" || { (( ionic_done >= 1 )) && echo "${_sn[0]}" || echo "$open_total"; } )"
    printf 'ionic_done=%s\n' "$ionic_done"
    printf 'reached=%s\n' "$reached"
    printf 'est_s=%s\n' "$est"
}

# st_walltime_min EST_S SAFETY MARGIN_MIN -> whole minutes
st_walltime_min(){ awk -v e="$1" -v f="$2" -v m="$3" \
    'BEGIN{ w = e * f / 60; w = (w == int(w)) ? w : int(w) + 1; printf "%d", w + m }'; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    case "${1:-}" in
        summary) st_summary "${2:?OUTCAR}" "${3:?OSZICAR}" ;;
        first)   st_estimate first "${2:?OUTCAR}" "${3:?OSZICAR}" "${4:?NSW}" "${5:?STARTUP_S}" ;;
        next)    st_estimate next  "${2:?OUTCAR}" "${3:?OSZICAR}" "${4:?NSW}" "${5:?WALL_S}" "${6:-0}" ;;
        retry)   st_estimate retry "${2:?OUTCAR}" "${3:?OSZICAR}" "${4:?NSW}" "${5:?STARTUP_S}" "${6:-0}" ;;
        walltime) st_walltime_min "${2:?EST_S}" "${3:-1.25}" "${4:-5}" ;;
        *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
fi
