#!/bin/bash
###############################################################################
# vasp_dry_run.sh   (invoked on PATH as: vasp-dry-run)
#
# Submit a one-rank VASP dry run to your cluster's DEBUG partition. The
# resulting OUTCAR feeds vasp_recommend_slurm.py (vasp-recommend-slurm), which
# uses it to predict memory and suggest the best parallelization setup.
#
# CLUSTER PROFILE
#   Partition, notification email and the VASP module(s) to load all come from
#   the profile written by `vasp-configure` (~/.config/wolfpack-dft/cluster.conf).
#   If no profile exists, built-in example defaults are used.
#
# WHAT IT DOES
#   Renders a SELF-CONTAINED job script (slurm_dryrun.sh) with the resolved
#   #SBATCH directives and module-load lines baked in, and submits it. The job
#   runs "vasp_std --dry-run" on 1 MPI rank inside a hidden .wolfpack/ work dir
#   (so your folder stays clean), captures the memory table to
#   .wolfpack/dryrun_OUTCAR, and STARTS the combined report.out.
#
# PIPELINE (run these three, in order, with NO arguments and NO manual steps):
#   vasp-dry-run            # STAGE 1: dry run  -> .wolfpack/dryrun_OUTCAR, report.out
#   vasp-recommend-slurm    # STAGE 2: reads that OUTCAR -> slurm.sh + report.out
#   vasp-test               # STAGE 3: validates the config -> updates slurm.sh
#
#   Final folder: INCAR KPOINTS POSCAR POTCAR  slurm_dryrun.sh slurm_vasptest.sh
#                 slurm.sh  report.out          (intermediates live in .wolfpack/)
#
# USAGE
#   cd <dir with INCAR / POSCAR / POTCAR / KPOINTS>
#   vasp-dry-run            # writes ./slurm_dryrun.sh and submits it
###############################################################################
#SBATCH --job-name=vasp_dryrun
#SBATCH -n 1
#SBATCH --ntasks-per-node=1
#SBATCH -c 1
#SBATCH --mem-per-cpu=8000
#SBATCH -t 00:10:00
#SBATCH -o vasp_dryrun_%j.out
#SBATCH -e vasp_dryrun_%j.err
# (the normal entry point `vasp-dry-run` renders slurm_dryrun.sh instead, taking
#  the walltime from WP_TEST_WALLTIME_MIN; these in-file directives apply only if
#  you run `sbatch vasp-dry-run` directly. SLURM parses them before any shell
#  runs, so they CANNOT read the profile -- hence a deliberately small 10 min,
#  which fits under any site's debug cap. The probe itself exits in seconds.)

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,31p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'
    exit 0
fi

set -uo pipefail

# --- Load the cluster profile (if present) --------------------------------- #
_wp_conf="${WOLFPACK_CLUSTER_CONF:-$HOME/.config/wolfpack-dft/cluster.conf}"
# shellcheck source=/dev/null
[[ -f "$_wp_conf" ]] && source "$_wp_conf"

# --- The profile is REQUIRED, not optional --------------------------------- #
# Every value below is a FACT ABOUT THIS CLUSTER that vasp-configure asks the
# user for: partition names, cores per node, RAM per node, the debug walltime
# cap. Falling back to a built-in number means silently running with someone
# else's hardware -- and the numbers disagreed between tools (cores/node
# defaulted to 256 here and 128 in another script), so the "safe default" was
# not even self-consistent. A wrong guess does not fail fast either: SLURM
# accepts the job and the sizing is quietly wrong. So: if the answer is not in
# the profile, stop and say which answer is missing.
_wp_require(){
    local missing=() v
    for v in "$@"; do [[ -z "${!v:-}" ]] && missing+=("$v"); done
    (( ${#missing[@]} == 0 )) && return 0
    {
        echo
        echo "=============================================================================="
        echo " CANNOT RUN -- this cluster has not been configured"
        echo "=============================================================================="
        echo " These values describe YOUR cluster and cannot be guessed:"
        for v in "${missing[@]}"; do echo "     ${v}"; done
        echo
        if [[ -f "$_wp_conf" ]]; then
            echo " A profile exists at"
            echo "     ${_wp_conf}"
            echo " but does not define them. Re-run the wizard to fill them in:"
        else
            echo " No profile found at"
            echo "     ${_wp_conf}"
            echo " Create one (asks a handful of questions, once per cluster):"
        fi
        echo "     vasp-configure"
        echo "=============================================================================="
        echo
    } >&2
    exit 2
}

_wp_require WP_DEBUG_PARTITION WP_TEST_WALLTIME_MIN WP_VASP_STD


# Emit the resolved module-load command lines (single source of truth: used both
# to bake them into the rendered job script and to load them in the fallback).
_wp_module_block() {
    if [[ -n "${WP_VASP_MODULES:-}" ]]; then
        local cmd="${WP_MODULE_CMD:-ml}"
        if [[ "${WP_MODULE_PURGE:-1}" == "1" ]]; then
            [[ "$cmd" == "module" ]] && echo "module purge" || echo "ml purge"
        fi
        if [[ "$cmd" == "module" ]]; then echo "module load ${WP_VASP_MODULES}"
        else echo "ml ${WP_VASP_MODULES}"; fi
    else
        # No modules configured. Emit none.
        #
        # This used to fall back to the modules of the machine this toolkit
        # was first written on (gcc/14.2.0-zen4-y, vasp/6.4.3-...). On a
        # cluster where WP_VASP_MODULES is empty ON PURPOSE -- because
        # WP_VASP_STD is an absolute path, or because the site has no module
        # system at all -- that loaded a STRANGER'S VASP over the one that
        # was benchmarked, silently, and the run measured one binary while
        # production used another.
        echo "# (no modules configured in your cluster profile)"
    fi
}

# --- Submit side: render a self-contained job script and submit it --------- #
if [[ -z "${SLURM_JOB_ID:-}" ]]; then
    if ! command -v sbatch >/dev/null 2>&1; then
        echo "ERROR: sbatch not found. Run this on a cluster login node." >&2
        exit 1
    fi
    part="${WP_DEBUG_PARTITION:-debug}"
    # A non-collinear / spin-orbit run needs the vasp_ncl binary: vasp_std cannot
    # do it. vasp-configure asks for WP_VASP_NCL and saved it, but nothing ever
    # read it, so an LSORBIT run was probed with vasp_std and failed on the spot.
    if grep -qiE '^[[:space:]]*(LSORBIT|LNONCOLLINEAR)[[:space:]]*=[[:space:]]*\.?T' INCAR 2>/dev/null; then
        exe="${WP_VASP_NCL:-vasp_ncl}"
    else
        exe="${WP_VASP_STD:-vasp_std}"
    fi
    # Walltime and memory come from the cluster profile, like every other field
    # in this header. They used to be hardcoded at 30 min / 8000 MB, so a site
    # configured for a 20-minute debug cap had its dry run REJECTED by SLURM --
    # vasp-configure asked the question and the answer was ignored.
    # The dry run is a 1-rank probe that exits in seconds; it only needs to fit
    # inside the debug partition's cap, so it shares WP_TEST_WALLTIME_MIN.
    _dr_min="${VASP_DRYRUN_WALLTIME_MIN:-${WP_TEST_WALLTIME_MIN:-30}}"
    _dr_min="${_dr_min%%.*}"; _dr_min="${_dr_min//[!0-9]/}"; _dr_min="${_dr_min:-30}"
    (( _dr_min < 1 )) && _dr_min=1
    _dr_time=$(printf '%02d:%02d:00' $((_dr_min/60)) $((_dr_min%60)))
    # The 1-rank probe asks for a flat 8 GB, which is generous for a job that
    # exits before it allocates -- but it has to be something the partition can
    # actually give. A node with less RAM than that refuses the job outright
    # ("Memory specification can not be satisfied"), and the stage that is
    # supposed to be the cheap, always-works one becomes the one that never
    # starts. The profile already knows the node size: cap against it, keeping
    # a little back for the OS.
    _dr_mem="${VASP_DRYRUN_MEM_MB:-${WP_DRYRUN_MEM_MB:-8000}}"
    _dr_mem="${_dr_mem//[!0-9]/}"; _dr_mem="${_dr_mem:-8000}"
    _dr_node="${WP_DEBUG_MEM_PER_NODE_MB:-${WP_MAIN_MEM_PER_NODE_MB:-0}}"
    _dr_node="${_dr_node//[!0-9]/}"; _dr_node="${_dr_node:-0}"
    if (( _dr_node > 0 )); then
        _dr_cap=$(( _dr_node - 512 )); (( _dr_cap < 256 )) && _dr_cap=$(( _dr_node ))
        (( _dr_mem > _dr_cap )) && _dr_mem=$_dr_cap
    fi
    (( _dr_mem < 256 )) && _dr_mem=256
    mkdir -p .wolfpack                       # so SLURM can place its log there
    job="$PWD/slurm_dryrun.sh"
    {
        echo "#!/bin/bash"
        echo "#SBATCH --job-name=vasp_dryrun"
        echo "#SBATCH --partition=${part}"
        echo "#SBATCH --ntasks=1"
        echo "#SBATCH --ntasks-per-node=1"
        echo "#SBATCH --cpus-per-task=1"
        echo "#SBATCH --mem-per-cpu=${_dr_mem}"
        echo "#SBATCH --time=${_dr_time}"
        if [[ -n "${WP_EMAIL:-}" ]]; then
            echo "#SBATCH --mail-user=${WP_EMAIL}"
            echo "#SBATCH --mail-type=ALL"
        fi
        echo "#SBATCH --output=.wolfpack/dryrun-%j.out"
        echo "#SBATCH --error=.wolfpack/dryrun-%j.err"
        echo ""
        echo "# Generated by vasp-dry-run on $(date -Iseconds) -- STAGE 1/3."
        echo 'cd "$SLURM_SUBMIT_DIR" || exit 1'
        echo 'mkdir -p .wolfpack'
        echo ""
        echo "# --- modules (resolved from your cluster profile) ---"
        _wp_module_block
        echo ""
        echo "# Run the dry run in a throwaway dir so the calc folder stays clean."
        echo 'rm -rf .wolfpack/dryrun_run; mkdir -p .wolfpack/dryrun_run'
        echo 'cp -f INCAR POSCAR POTCAR KPOINTS .wolfpack/dryrun_run/ 2>/dev/null'
        echo "( cd .wolfpack/dryrun_run && srun -n 1 ${exe} --dry-run ) \\"
        echo "    > .wolfpack/dryrun.log 2>&1"
        echo 'cp -f .wolfpack/dryrun_run/OUTCAR .wolfpack/dryrun_OUTCAR 2>/dev/null'
        echo 'rm -rf .wolfpack/dryrun_run'
        echo ""
        echo '# --- summarise + START the combined report.out (stage 1) ---'
        echo '_oc=.wolfpack/dryrun_OUTCAR'
        echo "_nk=\$(grep -m1 -oE 'NKPTS *= *[0-9]+' \"\$_oc\" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
        echo "_nb=\$(grep -m1 -oE 'NBANDS *= *[0-9]+' \"\$_oc\" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
        echo "_mk=\$(grep -m1 'total amount of memory used by VASP MPI-rank0' \"\$_oc\" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
        echo "_mb=\$([[ -n \"\$_mk\" ]] && awk \"BEGIN{printf \\\"%.0f\\\", \$_mk/1024}\" || echo '?')"
        echo '{'
        echo '  echo "================================================================================"'
        echo '  echo "                        WolfPack-DFT pipeline report"'
        echo '  echo "  dir : $SLURM_SUBMIT_DIR"'
        echo '  echo "  date: $(date)"'
        echo '  echo "================================================================================"'
        echo '  echo ""'
        echo '  echo "################################################################################"'
        echo '  echo "#  STAGE 1/3 -- DRY RUN  (vasp-dry-run, job $SLURM_JOB_ID)"'
        echo '  echo "################################################################################"'
        echo '  echo ""'
        # Say what was actually captured. This used to print
        # "OK (memory table captured)" whenever the OUTCAR was non-empty, and
        # then "VASP table / rank : ? MB" two lines below it -- claiming a
        # measurement it did not have. `vasp_std --dry-run` exits BEFORE it
        # allocates anything, so it never prints a memory table at all; the
        # sizing that follows is formulas, and the report has to say so.
        echo '  if [[ ! -s "$_oc" ]]; then'
        echo '    echo "  status            : FAILED -- no OUTCAR produced."'
        echo '    echo "  check modules/inputs; log at .wolfpack/dryrun.log"'
        echo '  else'
        echo '    echo "  NKPTS / NBANDS    : ${_nk:-?} / ${_nb:-?}"'
        echo '    echo "  captured to       : .wolfpack/dryrun_OUTCAR"'
        echo '    if [[ -n "$_mk" ]]; then'
        echo '      echo "  status            : OK (memory table captured)"'
        echo '      echo "  VASP table / rank : ${_mb} MB  (rank-0; real RSS is larger)"'
        echo '    else'
        echo '      echo "  status            : OK (dimensions captured; NO memory table)"'
        echo '      echo "  memory            : not measured here. A dry run exits before"'
        echo '      echo "                      VASP allocates, so there is nothing to read."'
        echo '      echo "                      vasp-recommend-slurm will size from formulas,"'
        echo '      echo "                      which is a GUESS -- vasp-test measures the"'
        echo '      echo "                      real value and that one is authoritative."'
        echo '    fi'
        echo '    echo ""'
        echo '    echo "  Next: run  vasp-recommend-slurm  (no arguments)."'
        echo '  fi'
        echo '} > report.out'
        echo ""
        echo '# --- pipeline state for the next stage ---'
        echo '{ echo "# WolfPack-DFT pipeline state"; echo '"'"'stage="dryrun"'"'"'; echo '"'"'dryrun_outcar=".wolfpack/dryrun_OUTCAR"'"'"'; } > .wolfpack/state.env'
        echo 'echo "STAGE 1 done. Now run: vasp-recommend-slurm"'
    } > "$job"
    chmod +x "$job"
    echo "Wrote job script : $job" >&2
    echo "Submitting 1-rank VASP dry run to partition '${part}' ..." >&2
    exec sbatch "$job"
fi

# --- Direct-sbatch fallback (`sbatch vasp-dry-run`): run the dry run inline -- #
cd "$SLURM_SUBMIT_DIR" || exit 1
while IFS= read -r _ml; do eval "$_ml" 2>/dev/null || true; done < <(_wp_module_block)
srun -n 1 "${WP_VASP_STD:-vasp_std}" --dry-run
