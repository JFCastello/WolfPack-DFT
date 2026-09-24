# chain_harness.sh -- run vasp-relax-loop end to end without a scheduler.
#
# Sourced by the chain tests after lib.sh. Nothing in the suite ran a chunk's
# body before these tests: the chain was checked at launch (test_09) and its
# restart physics by hand (test_16), but the code that runs INSIDE each job --
# measure, decide, archive, resubmit -- had no test at all. This makes it
# runnable:
#
#   srun     a fake VASP. Reads INCAR/POSCAR, writes OUTCAR, OSZICAR, CONTCAR,
#            XDATCAR, WAVECAR and vasprun.xml in VASP 6.5.1's own formats
#            (copied from real runs in this suite), and can die of an OOM.
#            What it does on each call comes from a PLAN file, one line per call.
#   sbatch   records the script it was given and answers with a job id.
#   sacct    answers from files the test writes: per-job memory and state, and
#            a queue history for the study.
#   squeue   says a job is alive only if the test said so.
#   scontrol reports a partition MaxTime the test chose.
#
# Every chain command runs in a subshell whose PATH starts with the fakes and
# otherwise holds only /usr/bin:/bin -- so the real sacct and sbatch cannot be
# reached by accident (a lesson this suite paid for twice; see RULES.md).

CH_TK="$TK_DIR/vasp_chain.sh"

# ch_setup NAME [ISIF] -> prints the calculation directory
ch_setup(){
    local name="$1" isif="${2:-2}" d f
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

    # --- the calculation: Si, a relaxation, after stage 3 ---------------------
    cp "$CASES/Si/POSCAR" "$d/POSCAR"
    printf 'Auto\n0\nGamma\n4 4 4\n0 0 0\n' > "$d/KPOINTS"
    # Not a potential: the one line the chain reads (ENMAX), under a title that
    # says what this is. No licensed VASP file is ever copied into the suite.
    printf '  TITEL  = synthetic test fixture -- not a VASP potential\n   ENMAX  =  245.345; ENMIN  =  184.009 eV\n' > "$d/POTCAR"
    cat > "$d/INCAR" <<EOF
SYSTEM = Si chain test
PREC   = Accurate
ENCUT  = 400
EDIFF  = 1E-6
NELM   = 60
IBRION = 2
ISIF   = ${isif}
NSW    = 20
EDIFFG = -0.01
ISMEAR = 0
SIGMA  = 0.05
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
    # the benchmark's measurements, as vasp-test leaves them
    printf 'stage="test"\ntest_avg_loop="2.0"\ntest_ranks="4"\ntest_cpu_eff="90"\ntest_startup_s="10"\ntest_scf_per_ionic="10"\n' \
        > "$d/.wolfpack/state.env"

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
fi
exit 0
EOS
    cat > "$f/bin/srun" <<'EOS'
#!/usr/bin/env python3
"""A fake VASP. One line of $FAKE_DIR/plan per call, key=value:
   ionic=N     ionic steps before an OOM, a job kill or convergence. Otherwise
               VASP runs to the cap -- a real VASP does not stop early for no
               reason, and the chain rightly treats one that does as a failure.
   t_ion=S     seconds per ionic step, as LOOP+ reports it
   spi=N       electronic steps per ionic step
   maxmem_kb=K rank 0's peak, for the OUTCAR footer
   converge=1  finish with 'reached required accuracy'
   oom=1       die of an OOM after `ionic` steps: no footer, slurmstepd's
               message on stderr, exit 137. The chain's body survives it.
   killjob=1   the same, but the whole JOB dies: the fake also kills the chunk
               body that launched it, as SLURM does when the job goes
   timeout=1   the job is killed by its walltime instead: slurmstepd's
               "DUE TO TIME LIMIT" line, body killed too
   vscale=F    lattice scale per ionic step (cell relaxations)
   wavesize=B  bytes of WAVECAR; wavepartial=1 writes half of it (a death
               while writing)
The last line is reused once the plan runs out."""
import os, re, sys
fd = os.environ["FAKE_DIR"]
plan = [l.strip() for l in open(os.path.join(fd, "plan")) if l.strip()]
used = int(open(os.path.join(fd, "plan_used")).read()) if os.path.exists(os.path.join(fd, "plan_used")) else 0
line = plan[min(used, len(plan) - 1)] if plan else ""
open(os.path.join(fd, "plan_used"), "w").write(str(used + 1))
P = dict(kv.split("=", 1) for kv in line.split())
ionic = int(P.get("ionic", 3)); t_ion = float(P.get("t_ion", 30)); spi = int(P.get("spi", 5))
maxkb = int(P.get("maxmem_kb", 1500 * 1024)); conv = P.get("converge") == "1"
tmo = P.get("timeout") == "1"
oom = P.get("oom") == "1" or P.get("killjob") == "1" or tmo
killjob = P.get("killjob") == "1" or tmo
vscale = float(P.get("vscale", 1.0))
wsize = int(P.get("wavesize", 4096)); wpart = P.get("wavepartial") == "1"

inc = open("INCAR").read()
def tag(k, d):
    m = re.search(r"^\s*%s\s*=\s*(-?\d+)" % k, inc, re.M | re.I)
    return int(m.group(1)) if m else d
nsw = tag("NSW", 0); nelm = tag("NELM", 60)
open(os.path.join(fd, "vasp_seen"), "a").write(
    "ISTART=%d ICHARG=%d NSW=%d NELM=%d\n" % (tag("ISTART", 0), tag("ICHARG", 2), nsw, nelm))
steps = min(ionic, max(nsw, 1)) if (oom or conv) else max(nsw, 1)
if conv:
    steps = max(1, steps)

pos = open("POSCAR").read().splitlines()
scale = float(pos[1].split()[0]); lat = [[float(x) for x in pos[i].split()[:3]] for i in (2, 3, 4)]
nat = sum(int(x) for x in pos[6].split())
coords = [[float(x) for x in pos[8 + i].split()[:3]] for i in range(nat)]

out = ["  vasp.6.5.1 10Mar25 (build fake) complex",
       "   NELM   =     %d;   NELMIN=  2; NELMDL= -5     # of ELM steps" % nelm,
       "   NSW    =     %d    number of steps for IOM" % nsw,
       "   k-points           NKPTS =     29   k-points in BZ     NKDIM =     29   number of bands    NBANDS=      8",
       " total amount of memory used by VASP MPI-rank0    %d. kBytes" % (maxkb // 2)]
osz = ["       N       E                     dE             d eps       ncg     rms          rms(c)"]
xd = [pos[0], pos[1]] + pos[2:5] + pos[5:7]
for k in range(1, steps + 1):
    for e in range(1, spi + 1):
        out.append("      LOOP:  cpu time      %.4f: real time      %.4f" % (t_ion / spi, t_ion / spi))
        osz.append("DAV:   %d    -0.108000000000E+02   -0.10000E-03   -0.10000E-03   100   0.100E-01" % e)
    fmax = 0.005 if (conv and k == steps) else 0.5 / (k + 1 + used * 3)
    out += [" POSITION                                       TOTAL-FORCE (eV/Angst)",
            " -----------------------------------------------------------------------------------",
            "      0.00000      0.00000      0.00000         %.6f      0.000000      0.000000" % fmax,
            " -----------------------------------------------------------------------------------",
            "     LOOP+:  cpu time     %.4f: real time     %.4f" % (t_ion, t_ion)]
    osz.append("   %d F= -.10820773E+02 E0= -.10820773E+02  d E =-.108208E+02" % k)
    coords[1][0] += 0.002
    lat = [[x * vscale for x in r] for r in lat]
    xd.append("Direct configuration=     %d" % k)
    xd += ["  %.8f  %.8f  %.8f" % tuple(c) for c in coords]
if conv:
    out.append(" reached required accuracy - stopping structural energy minimisation")

def poscar_text():
    L = [pos[0], pos[1]] + ["   %.12f   %.12f   %.12f" % tuple(r) for r in lat] + pos[5:8]
    L += ["  %.12f  %.12f  %.12f" % tuple(c) for c in coords]
    return "\n".join(L) + "\n"

open("OSZICAR", "w").write("\n".join(osz) + "\n")
if steps > 0:
    open("CONTCAR", "w").write(poscar_text())
    open("XDATCAR", "w").write("\n".join(xd) + "\n")
if oom:
    open("OUTCAR", "w").write("\n".join(out) + "\n")
    jid = os.environ.get("SLURM_JOB_ID", "0")
    if tmo:
        sys.stderr.write("slurmstepd: error: *** JOB %s ON fake01 CANCELLED AT "
                         "2026-09-24T03:00:00 DUE TO TIME LIMIT ***\n" % jid)
    else:
        sys.stderr.write("slurmstepd: error: Detected 1 oom_kill event in StepId=%s.0. "
                         "Some of the step tasks have been OOM Killed.\n" % jid)
        sys.stderr.write("srun: error: fake01: task 3: Out Of Memory\n")
    if wpart:
        open("WAVECAR", "wb").write(b"\0" * (wsize // 2))
    if killjob:
        # the job goes: /usr/bin/time, and the chain's body above it
        import signal
        t = os.getppid()
        body = int(open("/proc/%d/stat" % t).read().split(")")[1].split()[1])
        for pid in (body, t):
            try: os.kill(pid, signal.SIGKILL)
            except OSError: pass
    sys.exit(137)
open("WAVECAR", "wb").write(b"\0" * (wsize // 2 if wpart else wsize))
out += [" General timing and accounting informations for this job:",
        " ========================================================",
        "                   Maximum memory used (kb):      %d." % maxkb,
        "                   Average memory used (kb):          N/A"]
open("OUTCAR", "w").write("\n".join(out) + "\n")
open("vasprun.xml", "w").write("<modeling></modeling>\n")
sys.exit(0)
EOS
    chmod +x "$f/bin/"*
    echo "$d"
}

_ch_fake(){ echo "$1.fake"; }

# ch_run DIR [chain args...]      the launcher, on a "login node"
ch_run(){
    local d="$1" f; shift; f=$(_ch_fake "$d")
    ( cd "$d" && env -u SLURM_JOB_ID PATH="$f/bin:/usr/bin:/bin" FAKE_DIR="$f" \
          FAKE_MAXTIME="${FAKE_MAXTIME:-UNLIMITED}" WOLFPACK_CLUSTER_CONF="$f/cluster.conf" \
          HOME="$f" bash "$CH_TK" --mode relax "$@" )
}

# ch_last_jid DIR                 the job the chain most recently submitted
ch_last_jid(){ tail -1 "$(_ch_fake "$1")/submitted" 2>/dev/null; }

# ch_chunk DIR                    run the chunk the chain last submitted, as
#                                 SLURM would: its own job id, its granted
#                                 memory, stdout/stderr into VASP-chain-<jid>.*
ch_chunk(){
    local d="$1" f jid mem; f=$(_ch_fake "$d"); jid=$(ch_last_jid "$d")
    [[ -n $jid ]] || { echo "no submitted chunk" >&2; return 99; }
    mem=$(grep -oP '^#SBATCH --mem-per-cpu=\K[0-9]+' "$f/submitted.$jid")
    # a finished job is no longer in the queue; its submission marker must be
    # older than anything it wrote (mtime granularity is one second)
    touch -d '-5 seconds' "$d/wolfpack_chain/RUNNING" 2>/dev/null
    ( cd "$d" && env PATH="$f/bin:/usr/bin:/bin" FAKE_DIR="$f" SLURM_JOB_ID="$jid" \
          SLURM_MEM_PER_CPU="$mem" SLURM_SUBMIT_DIR="$d" \
          WOLFPACK_CLUSTER_CONF="$f/cluster.conf" HOME="$f" \
          bash "$CH_TK" --mode relax --chunk-body > "VASP-chain-$jid.out" 2> "VASP-chain-$jid.err" )
}

# ch_die DIR                      the chunk dies WITH its job: the body runs its
#                                 pre-VASP edits, VASP runs, then everything is
#                                 killed (the plan line must say killjob=1)
#                                 The shell's own "Killed" notice for that
#                                 death is expected, and is not let into the log.
ch_die(){ { ch_chunk "$1"; } 2>/dev/null; return 0; }

ch_plan(){ echo "$2" >> "$(_ch_fake "$1")/plan"; }
ch_sacct(){ printf '%s\n' "${@:3}" > "$(_ch_fake "$1")/sacct.$2"; }
ch_alive(){ echo "$2" >> "$(_ch_fake "$1")/alive"; }
ch_state(){ sed -n "s/^$2=\"\(.*\)\"$/\1/p" "$1/wolfpack_chain/chain.env" | head -1; }
ch_job(){ grep -oP "^#SBATCH --$2=\K\S+" "$1/wolfpack_chain/slurm_chunk.sh" 2>/dev/null | head -1; }
ch_nsub(){ grep -c . "$(_ch_fake "$1")/submitted" 2>/dev/null || echo 0; }
