#!/usr/bin/env bash
# vasp-clean and vasp-nuke delete things. The only question that matters is
# what they will NOT delete, and whether they can be made to delete it by a
# plausible mistake.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/clean_nuke"; rm -rf "$W"; mkdir -p "$W"

INPUTS="INCAR POSCAR KPOINTS POTCAR"
OUTPUTS="CHG CHGCAR CONTCAR DOSCAR EIGENVAL OSZICAR OUTCAR vasprun.xml WAVECAR XDATCAR"

_populate(){ local d="$1"; mkdir -p "$d/.wolfpack"
    for f in $INPUTS $OUTPUTS; do echo "content of $f" > "$d/$f"; done
    echo "my own notes" > "$d/notes.txt"
    echo "my own script" > "$d/run_me.sh"
    echo "state" > "$d/.wolfpack/state.env"; }

_survives(){ local d="$1" label="$2"; shift 2
    local gone=""
    for f in "$@"; do [[ -e "$d/$f" ]] || gone="$gone $f"; done
    [[ -z "$gone" ]] && pass "$label" || fail "$label -- DELETED:$gone"; }

# --- vasp-clean: the inputs and the user's own files are untouchable --------
d="$W/clean"; _populate "$d"
( cd "$d" && timeout 60 bash "$TK_DIR/vasp_clean.sh" -y >clean.log 2>&1 ) || true
_survives "$d" "vasp-clean leaves every VASP INPUT in place" $INPUTS
_survives "$d" "vasp-clean leaves the user's own files alone" notes.txt run_me.sh

# --- vasp-nuke: same promise, bigger blast radius --------------------------
d="$W/nuke"; _populate "$d"
( cd "$d" && timeout 60 bash "$TK_DIR/vasp_nuke.sh" >nuke.log 2>&1 ) || true
_survives "$d" "vasp-nuke leaves every VASP INPUT in place" $INPUTS
_survives "$d" "vasp-nuke leaves the user's own files alone" notes.txt run_me.sh
# and it must actually have done its job
[[ -e "$d/OUTCAR" || -e "$d/WAVECAR" ]] \
    && fail "vasp-nuke left the outputs it exists to remove" \
    || pass "vasp-nuke removed the VASP outputs"

# --- a live chunked run must STOP it ---------------------------------------
# WAVECAR and CONTCAR are the restart objects between chunks. Nuking them
# mid-chain strands the run, and the chain cannot tell it happened.
# The job id must be a job SLURM actually has. vasp-nuke asks squeue, and it
# is RIGHT to: a chain.env left saying "running" after the job died is exactly
# the stale state that should NOT block a cleanup. Writing a made-up id here
# tests nothing -- squeue says "no such job", nuke concludes the chain is dead,
# and deleting is the correct answer. So submit a real one.
d="$W/live"; _populate "$d"; mkdir -p "$d/wolfpack_chain"
if ! have_slurm; then
    skip "no slurmctld -- the live-chain refusal goes untested"
else
export SLURM_CONF="$TESTBED_ROOT/slurm.conf"
_part=$(sinfo -h -o %P | head -1 | tr -d '*')
_jid=$(sbatch --parsable -p "$_part" -n 1 -t 00:05:00 -o /dev/null \
       --wrap 'sleep 300' 2>/dev/null)
if [[ -z "$_jid" ]]; then
    skip "could not submit a probe job -- the live-chain refusal goes untested"
else
for _ in $(seq 1 20); do [[ -n "$(squeue -h -j "$_jid" 2>/dev/null)" ]] && break; sleep 1; done
printf 'chain_state="running"\n' > "$d/wolfpack_chain/chain.env"
echo "$_jid" > "$d/wolfpack_chain/RUNNING"
out=$(cd "$d" && timeout 60 bash "$TK_DIR/vasp_nuke.sh" 2>&1); rc=$?
if (( rc == 0 )); then
    fail "vasp-nuke ran while a chunked run was live"
else
    grep -qiE "refus|live|running|strand" <<<"$out" \
        && pass "vasp-nuke refuses while a chunked run is live, and says why" \
        || fail "vasp-nuke refused without explaining: $(tail -1 <<<"$out" | cut -c1-70)"
fi
_survives "$d" "the live run's restart objects survive the refusal" WAVECAR CONTCAR

# The mirror image: the SAME chain.env, but the job is gone. A stale "running"
# must not block a cleanup forever.
scancel "$_jid" 2>/dev/null
for _ in $(seq 1 30); do [[ -z "$(squeue -h -j "$_jid" 2>/dev/null)" ]] && break; sleep 1; done
# A cancelled job sits in COMPLETING (CG) while its epilog runs, and squeue
# still lists it. On this testbed -- multiple-slurmd with cgroups disabled --
# it can stay there for minutes. vasp-nuke is RIGHT to treat a job SLURM still
# lists as live, so waiting longer would not make this a valid test of the
# stale case; it needs an id SLURM genuinely does not know.
_gone="$_jid"
if [[ -n "$(squeue -h -j "$_gone" 2>/dev/null)" ]]; then
    _gone=$(( _jid + 900000 ))
    info "    job $_jid is still COMPLETING; using never-issued id $_gone instead"
fi
d2="$W/stale"; _populate "$d2"; mkdir -p "$d2/wolfpack_chain"
printf 'chain_state="running"\n' > "$d2/wolfpack_chain/chain.env"
echo "$_gone" > "$d2/wolfpack_chain/RUNNING"
( cd "$d2" && timeout 60 bash "$TK_DIR/vasp_nuke.sh" >stale.log 2>&1 ) || true
[[ -e "$d2/WAVECAR" ]] \
    && fail "a STALE 'running' chain blocks cleanup forever" \
    || pass "a stale 'running' chain whose job is gone does not block cleanup"
fi
fi

# --- a directory that is not a calculation ---------------------------------
# Running either of these in the wrong place is the mistake that costs data.
d="$W/notacalc"; mkdir -p "$d"
echo "an important document" > "$d/thesis.tex"
echo "some data" > "$d/results.csv"
( cd "$d" && timeout 60 bash "$TK_DIR/vasp_nuke.sh" >n.log 2>&1 ) || true
_survives "$d" "vasp-nuke in a non-calculation directory touches nothing" thesis.tex results.csv
( cd "$d" && timeout 60 bash "$TK_DIR/vasp_clean.sh" -y >c.log 2>&1 ) || true
_survives "$d" "vasp-clean in a non-calculation directory touches nothing" thesis.tex results.csv

# --- a directory that does not exist ---------------------------------------
must_refuse "vasp-nuke refuses a directory that does not exist" "." \
    bash "$TK_DIR/vasp_nuke.sh" "$W/does_not_exist_at_all"
exit $(( FAIL_N > 0 ))
