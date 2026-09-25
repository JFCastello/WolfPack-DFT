# chain_harness.sh -- run vasp-relax-loop end to end without a scheduler.
#
# Sourced by the chain tests after lib.sh. The chain's body runs INSIDE each
# job -- measure, estimate, file, resubmit -- and this makes it runnable:
#
#   srun     a fake VASP. Reads INCAR/POSCAR, writes OUTCAR, OSZICAR, CONTCAR,
#            XDATCAR and WAVECAR in VASP 6.5.1's formats, and behaves as a real
#            one does in the one way the chain rests on: CONTCAR is the LAST
#            GEOMETRY IT COMPUTED -- after the last ionic step the ions do not
#            move (checked with VASP 6.5.1, IBRION 1, 2 and 3). What it does
#            on each call comes from a PLAN file, one line per call.
#   sbatch   records the script it was given and answers with a job id.
#   sacct    answers from files the test writes: per-job memory and state, and
#            a queue history for backfill-study.
#   squeue   says a job is alive only if the test said so.
#   scontrol reports a partition MaxTime the test chose, and its priority
#            settings (show config) when the test wrote them.
#   sshare, sprio, sacctmgr   the test's answer, else a controller that
#            cannot be reached.
#
# Every command runs in a subshell whose PATH starts with the fakes and
# otherwise holds only /usr/bin:/bin -- so the real sacct and sbatch cannot be
# reached by accident (a lesson this suite paid for twice; see RULES.md).

CH_TK="$TK_DIR/vasp_relax_loop.sh"

# ch_setup NAME -> prints the calculation directory
ch_setup(){
    local name="$1" d f
    d="$W/$name"; f="$W/$name.fake"
    rm -rf "$d" "$f"; mkdir -p "$d/.wolfpack" "$f/bin"
    : > "$f/plan"; : > "$f/alive"; echo 1000 > "$f/next_jid"

    # --- the cluster: 8-core nodes of 16 GB, a 32-core cap -------------------
    cat > "$f/cluster.conf" <<EOF
WP_VASP_STD="vasp_std"
WP_VASP_MODULES=""
WP_MAIN_PARTITION="fakepart"
WP_DEBUG_PARTITION="fakedev"
WP_MAIN_CPUS_PER_NODE="8"
WP_DEBUG_CPUS_PER_NODE="8"
WP_MAIN_MEM_PER_NODE_MB="16000"
WP_DEBUG_MEM_PER_NODE_MB="16000"
WP_MAX_CORES="32"
WP_DEBUG_MAX_CORES="8"
WP_MAIN_MEM_MARGIN="0.02"
WP_DEBUG_MEM_MARGIN="0.05"
WP_CHUNK_WALLTIME_MIN="60"
WP_CHUNK_MARGIN_MIN="5"
WP_ALLOC_PROFILE="whole-nodes"
EOF

    # --- the calculation: Si, a relaxation, after vasp-test --full-size -------
    cp "$CASES/Si/POSCAR" "$d/POSCAR"
    printf 'Auto\n0\nGamma\n4 4 4\n0 0 0\n' > "$d/KPOINTS"
    # Not a potential: a title that says what this is. No licensed VASP file
    # is ever copied into the suite.
    printf '  TITEL  = synthetic test fixture -- not a VASP potential\n   ENMAX  =  245.345; ENMIN  =  184.009 eV\n' > "$d/POTCAR"
    cat > "$d/INCAR" <<EOF
SYSTEM = Si chain test
PREC   = Accurate
ENCUT  = 400
EDIFF  = 1E-6
NELM   = 60
IBRION = 2
ISIF   = 2
NSW    = 2
EDIFFG = -0.01
ISMEAR = 0 ; SIGMA  = 0.05
EOF
    cat > "$d/slurm_vasptest.sh" <<'EOF'
#!/bin/bash
#SBATCH --job-name=vasp
#SBATCH --partition=fakepart
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=4
#SBATCH --mem-per-cpu=2000
#SBATCH --time=04:00:00
/usr/bin/time -v srun --cpu-bind=cores vasp_std
EOF
    # vasp-test --full-size, as it leaves the folder: stopped inside the first
    # ionic step after 8 electronic steps of 2.0 s -- 5 non-self-consistent
    # (NELMDL = -5), then max(|dE|,|d eps|) = 1e-1, 1e-2, 1e-3: one decade a
    # step, 3 more to EDIFF = 1e-6, +2 margin = 13 steps. With the force step
    # taken as one more 2.0 s (none completed): 28 s per ionic step.
    printf 'stage="test"\ntest_avg_loop="2.0"\ntest_ranks="4"\ntest_partition="fakepart"\ntest_cpu_eff="90"\ntest_startup_s="10"\ntest_scf_per_ionic="0"\ntest_full_size="1"\n' \
        > "$d/.wolfpack/state.env"
    {
        echo " vasp.6.5.1 10Mar25 (build fake) complex"
        echo "   NELM   =     60;   NELMIN=  2; NELMDL= -5     # of ELM steps "
        echo "   EDIFF  = 0.1E-05   stopping-criterion for ELM"
        for i in 1 2 3 4 5 6 7 8; do echo "      LOOP:  cpu time      2.0000: real time      2.0000"; done
    } > "$d/.wolfpack/vasptest_OUTCAR"
    {
        echo "       N       E                     dE             d eps       ncg     rms          rms(c)"
        k=0
        for v in 1E+02 1E+01 1E+00 1E-01 1E-02 1E-01 1E-02 1E-03; do
            k=$((k+1)); printf 'DAV:  %2d    -0.100000000000E+02   -%s   -%s  1000   0.1E+00\n' "$k" "$v" "$v"
        done
    } > "$d/.wolfpack/vasptest_OSZICAR"

    # --- the fakes ------------------------------------------------------------
    cat > "$f/bin/sbatch" <<'EOS'
#!/bin/bash
# records the script it was handed, answers with the next job id
f="$FAKE_DIR"; script="${@: -1}"
jid=$(cat "$f/next_jid"); echo $(( jid + 1 )) > "$f/next_jid"
cp -f "$script" "$f/submitted.$jid"
echo "$jid" >> "$f/submitted"
echo "Submitted batch job $jid"
EOS
    cat > "$f/bin/squeue" <<'EOS'
#!/bin/bash
# alive only if the test said so
jid=""; while [[ $# -gt 0 ]]; do case "$1" in -j) jid="$2"; shift 2 ;; *) shift ;; esac; done
[[ -n $jid ]] && grep -qx "$jid" "$FAKE_DIR/alive" && echo "  $jid fakepart vasp-chain user R 0:10 1 fake01"
exit 0
EOS
    cat > "$f/bin/sacct" <<'EOS'
#!/bin/bash
# per-job memory/state from sacct.<jid>; a queue history from history
jid=""; for ((i=1; i<=$#; i++)); do [[ ${!i} == -j ]] && { j=$((i+1)); jid="${!j}"; }; done
if [[ -n $jid ]]; then
    # With no scripted answer, behave like a cluster whose accounting records no RSS
    # (this suite's own testbed): the steps are there, finished, and empty.
    if [[ -f "$FAKE_DIR/sacct.$jid" ]]; then cat "$FAKE_DIR/sacct.$jid"
    else printf '%s|COMPLETED||\n%s.0|COMPLETED||\n' "$jid" "$jid"; fi
else
    [[ -f "$FAKE_DIR/history" ]] && cat "$FAKE_DIR/history"
fi
exit 0
EOS
    cat > "$f/bin/scontrol" <<'EOS'
#!/bin/bash
if [[ $1 == show && $2 == partition ]]; then
    echo "PartitionName=$3 AllowGroups=ALL Default=NO MaxTime=${FAKE_MAXTIME:-UNLIMITED} MinNodes=0"
elif [[ $1 == show && $2 == config && -f "$FAKE_DIR/config" ]]; then
    cat "$FAKE_DIR/config"
fi
exit 0
EOS
    # sshare, sprio, sacctmgr: the test's answer when it wrote one, else what
    # a login node with no reachable controller says.
    local c
    for c in sshare sprio sacctmgr; do
        cat > "$f/bin/$c" <<EOS
#!/bin/bash
if [[ -f "\$FAKE_DIR/$c" ]]; then cat "\$FAKE_DIR/$c"; exit 0; fi
echo "$c: fatal: Could not establish a configuration source" >&2
exit 1
EOS
    done
    cat > "$f/bin/srun" <<'EOS'
#!/usr/bin/env python3
"""A fake VASP. One line of $FAKE_DIR/plan per call (the last is reused),
key=value:
   nel=A,B,...  electronic steps of each ionic step (the last repeats); 8
   t_e=S        seconds per electronic step, as LOOP reports it; 2.0
   ovh=S        seconds of an ionic step beyond its electronic steps; 0.5
   conv_at=K    'reached required accuracy' after ionic step K of this run
   stop_at=E    the walltime warning after E electronic steps of this run:
                the job sends the chain USR1 (as SLURM does), VASP is killed
   oom_at=E     killed for memory after E electronic steps (the body lives)
   killjob=1    with stop_at/oom_at: the whole job dies, the body with it
   maxmem_kb=K  rank 0's peak, for the OUTCAR footer
The electronic steps converge one decade per step down to 5e-7 < EDIFF, after
the 5 non-self-consistent steps of NELMDL = -5 when there is no WAVECAR.
The ions move 0.002 (fractional) per ionic step, and CONTCAR is the LAST
geometry computed: after the last ionic step VASP does not move them."""
import os, re, sys, signal, time
fd = os.environ["FAKE_DIR"]
plan = [l.strip() for l in open(os.path.join(fd, "plan")) if l.strip()]
pu = os.path.join(fd, "plan_used")
used = int(open(pu).read()) if os.path.exists(pu) else 0
line = plan[min(used, len(plan) - 1)] if plan else ""
open(pu, "w").write(str(used + 1))
P = dict(kv.split("=", 1) for kv in line.split())
nel = [int(x) for x in P.get("nel", "8").split(",")]
t_e = float(P.get("t_e", 2.0)); ovh = float(P.get("ovh", 0.5))
conv_at = int(P.get("conv_at", 0)); stop_at = int(P.get("stop_at", 0)); oom_at = int(P.get("oom_at", 0))
killjob = P.get("killjob") == "1"; maxkb = int(P.get("maxmem_kb", 1500 * 1024))

inc = open("INCAR").read()
def tag(k):
    m = re.search(r"(?:^|;)\s*%s\s*=\s*([^\s;!#]+)" % k, inc, re.M | re.I)
    return m.group(1) if m else ""
nsw = int(tag("NSW") or 0)
had_wave = os.path.exists("WAVECAR") and os.path.getsize("WAVECAR") > 0
pos = open("POSCAR").read().splitlines()
nat = sum(int(x) for x in pos[6].split())
coords = [[float(x) for x in pos[8 + i].split()[:3]] for i in range(nat)]
open(os.path.join(fd, "vasp_seen"), "a").write("dir=%s NSW=%d WAVECAR=%d x2=%.4f\n" % (
    os.path.basename(os.getcwd()), nsw, int(had_wave), coords[1][0]))

nelmdl = 0 if had_wave else -5
out = [" vasp.6.5.1 10Mar25 (build fake) complex",
       "   NELM   =     60;   NELMIN=  2; NELMDL= %d     # of ELM steps " % nelmdl,
       "   EDIFF  = 0.1E-05   stopping-criterion for ELM",
       "   EDIFFG = -.1E-01   stopping-criterion for IOM",
       "   NSW    =     %d    number of steps for IOM" % nsw]
osz = []
done_e = 0; cut = None; steps = nsw if not conv_at else min(nsw, conv_at)
for k in range(1, steps + 1):
    n = nel[min(k - 1, len(nel) - 1)]
    delay = 5 if (k == 1 and nelmdl < 0) else 0
    osz.append("       N       E                     dE             d eps       ncg     rms          rms(c)")
    for j in range(1, n + 1):
        if j <= delay: c = 10.0 ** (2 - j)
        else: c = 5e-7 * 10.0 ** (n - j)
        osz.append("DAV: %3d    -0.108000000000E+02   -%.5E   -%.5E  1000   0.100E-01" % (j, c, c))
        out.append("      LOOP:  cpu time      %.4f: real time      %.4f" % (t_e, t_e))
        done_e += 1
        if (stop_at and done_e == stop_at) or (oom_at and done_e == oom_at):
            cut = "stop" if stop_at else "oom"; break
    if cut: break
    f = 0.5 / (k + 1)
    out += [" POSITION                                       TOTAL-FORCE (eV/Angst)",
            " -----------------------------------------------------------------------------------",
            "      0.00000      0.00000      0.00000         %.6f      0.000000      0.000000" % f,
            " -----------------------------------------------------------------------------------",
            "     LOOP+:  cpu time     %.4f: real time     %.4f" % (n * t_e + ovh, n * t_e + ovh)]
    osz.append("   %d F= -.1082%04dE+02 E0= -.10820773E+02  d E =-.108208E+02" % (k, 9999 - k))
    if conv_at and k == conv_at:
        out.append(" reached required accuracy - stopping structural energy minimisation")
    if k < steps:                    # the optimiser moves the ions -- not after the last step
        coords[1][0] += 0.002

def poscar_text():
    L = pos[0:8] + ["  %.12f  %.12f  %.12f" % tuple(c) for c in coords]
    return "\n".join(L) + "\n"
open("OSZICAR", "w").write("\n".join(osz) + "\n")
open("CONTCAR", "w").write(poscar_text())
if cut:
    open("OUTCAR", "w").write("\n".join(out) + "\n")
    jid = os.environ.get("SLURM_JOB_ID", "0")
    t = os.getppid()                                   # /usr/bin/time
    body = int(open("/proc/%d/stat" % t).read().split(")")[1].split()[1])
    if cut == "stop":
        if killjob:
            sys.stderr.write("slurmstepd: error: *** JOB %s ON fake01 CANCELLED AT 2026-09-25T03:00:00 DUE TO TIME LIMIT ***\n" % jid)
        else:
            os.kill(body, signal.SIGUSR1)              # SLURM's warning to the batch script
            time.sleep(0.3)
    else:
        sys.stderr.write("slurmstepd: error: Detected 1 oom_kill event in StepId=%s.0. Some of the step tasks have been OOM Killed.\n" % jid)
        sys.stderr.write("srun: error: fake01: task 3: Out Of Memory\n")
    if killjob:
        for pid in (body, t):
            try: os.kill(pid, signal.SIGKILL)
            except OSError: pass
    sys.exit(143 if cut == "stop" else 137)
if tag("LWAVE").upper().find("F") < 0:
    open("WAVECAR", "wb").write(b"\0" * 4096)
    open("CHGCAR", "w").write("fake\n")
total = sum(float(x.split()[-1]) for x in out if "LOOP+:" in x)
out += [" General timing and accounting informations for this job:",
        " ========================================================",
        "                   Maximum memory used (kb):      %d." % maxkb,
        "                   Average memory used (kb):          N/A",
        "                         Elapsed time (sec):      %.3f" % (total + 3.0)]
open("OUTCAR", "w").write("\n".join(out) + "\n")
open("vasprun.xml", "w").write("<modeling></modeling>\n")
sys.exit(0)
EOS
    chmod +x "$f/bin/"*
    echo "$d"
}

_ch_fake(){ echo "$1.fake"; }

# ch_run DIR [args...]            the launcher, on a "login node"
ch_run(){
    local d="$1" f; shift; f=$(_ch_fake "$d")
    ( cd "$d" && env -u SLURM_JOB_ID PATH="$f/bin:/usr/bin:/bin" FAKE_DIR="$f" \
          FAKE_MAXTIME="${FAKE_MAXTIME:-UNLIMITED}" WOLFPACK_CLUSTER_CONF="$f/cluster.conf" \
          HOME="$f" bash "$CH_TK" "$@" )
}

# ch_backfill DIR [args...]       backfill-study, standing alone, in DIR, on the
#                                 same fake cluster
ch_backfill(){
    local d="$1" f; shift; f=$(_ch_fake "$d")
    ( cd "$d" && env -u SLURM_JOB_ID PATH="$f/bin:/usr/bin:/bin" FAKE_DIR="$f" \
          FAKE_MAXTIME="${FAKE_MAXTIME:-UNLIMITED}" WOLFPACK_CLUSTER_CONF="$f/cluster.conf" \
          HOME="$f" "$WP_PY" "$TK_DIR/backfill_study.py" "$@" )
}

# ch_last_jid DIR                 the job the chain most recently submitted
ch_last_jid(){ tail -1 "$(_ch_fake "$1")/submitted" 2>/dev/null; }

# ch_chunk DIR                    run the job the chain last submitted, as SLURM
#                                 would: THE SUBMITTED SCRIPT ITSELF (its exec
#                                 line included), its own job id, its granted
#                                 memory, stdout/stderr into VASP-chain-<jid>.*
ch_chunk(){
    local d="$1" f jid mem; f=$(_ch_fake "$d"); jid=$(ch_last_jid "$d")
    [[ -n $jid ]] || { echo "no submitted chunk" >&2; return 99; }
    mem=$(grep -oP '^#SBATCH --mem-per-cpu=\K[0-9]+' "$f/submitted.$jid")
    ( cd "$d" && env PATH="$f/bin:/usr/bin:/bin" FAKE_DIR="$f" SLURM_JOB_ID="$jid" \
          SLURM_MEM_PER_CPU="$mem" SLURM_SUBMIT_DIR="$d" \
          WOLFPACK_CLUSTER_CONF="$f/cluster.conf" HOME="$f" \
          bash "$f/submitted.$jid" > "VASP-chain-$jid.out" 2> "VASP-chain-$jid.err" )
}

# ch_die DIR                      the job dies with its chain body (the plan line
#                                 says killjob=1); the shell's "Killed" notice
#                                 is not let into the log
ch_die(){ { ch_chunk "$1"; } 2>/dev/null; return 0; }

ch_plan(){ echo "$2" >> "$(_ch_fake "$1")/plan"; }
ch_sacct(){ printf '%s\n' "${@:3}" > "$(_ch_fake "$1")/sacct.$2"; }
ch_alive(){ echo "$2" >> "$(_ch_fake "$1")/alive"; }
ch_state(){ sed -n "s/^$2=\"\(.*\)\"$/\1/p" "$1/wolfpack_chain/chain.env" | head -1; }
ch_job(){ grep -oP "^#SBATCH --$2=\K\S+" "$1/wolfpack_chain/slurm_chunk.sh" 2>/dev/null | head -1; }
ch_nsub(){ grep -c . "$(_ch_fake "$1")/submitted" 2>/dev/null || echo 0; }
# ch_seen DIR N                   what VASP saw on its N-th call (1-based)
ch_seen(){ sed -n "${2}p" "$(_ch_fake "$1")/vasp_seen" 2>/dev/null; }
