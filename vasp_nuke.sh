#!/bin/bash
###############################################################################
# vasp_nuke.sh
#
# Delete ALL VASP output files from a directory; leave inputs untouched.
# This is a fast, no-questions-asked nuke intended for cleaning up before a
# rerun. For a safer, selective cleanup with dry-run, recursive mode, and
# per-file size reporting, use vasp-clean instead.
#
# FILES REMOVED
#   CHG  CHGCAR  CONTCAR  DOSCAR  EIGENVAL  IBZKPT  OSZICAR  OUTCAR
#   PCDAT  PROCAR  REPORT  vasprun.xml  WAVECAR  XDATCAR  WAVEDER
#   vaspout.h5  LOCPOT  ELFCAR  PROOUT  TMPCAR  HILLSPOT  PENALTYPOT
#   CHGCAR.tmp  WAVECAR.tmp   .wolfpack/ (hidden pipeline scratch + state)
#
# FILES PRESERVED
#   INCAR  POSCAR  POTCAR  KPOINTS  and everything else not listed above.
#
# USAGE
#   vasp-nuke                  # clean the current directory
#   vasp-nuke path/to/calc     # clean a specific directory
#
# SEE ALSO
#   vasp-clean  -- smarter cleanup: safe defaults, --dry-run, --recursive,
#                  --aggressive mode, per-file size report, confirmation prompt
###############################################################################

dir="${1:-.}"

cd "$dir" || exit 1

# A chunked run keeps WAVECAR and CONTCAR live in this folder between jobs; both
# are on the list below. Nuking them mid-run makes every later chunk restart from
# scratch, so the run silently never converges.
#
# This script takes no options and asks nothing, which is exactly why a hard stop
# belongs here: there is no prompt to think twice at. A stale marker (node crash,
# scancel) must not block forever, so the scheduler is asked whether the job is
# genuinely still there.
if [[ -f wolfpack_chain/chain.env ]] \
   && grep -qE '^[[:space:]]*chain_state="?running"?' wolfpack_chain/chain.env 2>/dev/null; then
    _jid="$(tr -dc '0-9' < wolfpack_chain/RUNNING 2>/dev/null)"
    _live=0
    if [[ -n "$_jid" ]]; then
        if command -v squeue >/dev/null 2>&1; then
            [[ -n "$(squeue -h -j "$_jid" 2>/dev/null)" ]] && _live=1
        else
            _live=1                              # no scheduler -> stay cautious
        fi
    fi
    if (( _live )); then
        {
            echo "REFUSING: a chunked run is live in $dir (job ${_jid})."
            echo "  WAVECAR and CONTCAR are its restart objects between chunks and are on"
            echo "  the removal list below. Nuking them would strand the run."
            echo "  Stop it first, then re-run this."
        } >&2
        exit 2
    fi
fi

rm -f CHG CHGCAR CONTCAR DOSCAR EIGENVAL IBZKPT OSZICAR OUTCAR \
      PCDAT PROCAR REPORT vasprun.xml WAVECAR XDATCAR WAVEDER \
      vaspout.h5 LOCPOT ELFCAR PROOUT TMPCAR HILLSPOT PENALTYPOT \
      CHGCAR.tmp WAVECAR.tmp
rm -rf .wolfpack          # hidden pipeline scratch/state + old SLURM logs

echo "VASP output files removed from $dir."
