#!/usr/bin/env bash
#
# vasp_clean.sh   (invoked on PATH as: vasp-clean)
#               — Clean heavy intermediate files from VASP calculation folders.
#
# By default, removes large files that are not typically needed for
# post-processing while preserving every file essential for analysis
# (vasprun.xml, OUTCAR, CONTCAR, CHGCAR, DOSCAR, EIGENVAL, PROCAR, ...).
#
# Usage: vasp-clean [OPTIONS] [DIR...]
#

set -euo pipefail

VERSION="1.0"
PROGRAM="vasp-clean"

# ------------------------------------------------------------------
# Files lists
# ------------------------------------------------------------------

# Heavy files removed by DEFAULT (safe to delete after a calculation;
# none of these are required by standard post-processing tools).
DEFAULT_REMOVE=(
    "WAVECAR"      # wavefunctions — huge, almost never needed
    "CHG"          # intermediate charge density (CHGCAR is the keeper)
    "TMPCAR"       # temporary
    "vasprun.tmp"  # temporary
    "PCDAT"        # pair-correlation (MD), regenerable
    "WAVEDER"      # wavefunction derivatives (optics restart)
    "STOPCAR"      # stop flag, leftover
    "REPORT"       # MD report file, can be large
    "HILLSPOT"     # metadynamics restart
)

# Files removed ONLY with --aggressive
# (still safe to remove, but may be useful for some post-processing).
AGGRESSIVE_REMOVE=(
    "CHGCAR"       # full charge density (kept by default: Bader, NSCF...)
    "LOCPOT"       # local potential (workfunctions)
    "ELFCAR"       # electron localization function
    "PROCAR"       # projected bands (vasprun.xml usually has equivalent info)
    "DOSCAR"       # DOS (vasprun.xml has it)
    "EIGENVAL"     # eigenvalues (vasprun.xml has it)
    "XDATCAR"      # trajectory (MD/relax)
    "AECCAR0"      # all-electron charge density
    "AECCAR1"
    "AECCAR2"
)

# ------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------
DRY_RUN=0
RECURSIVE=0
AGGRESSIVE=0
FORCE=0
ALLOW_RUNNING_CHAIN=0
VERBOSE=0
DIRS=()

# Colors only if stdout is a terminal
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    CYAN=$'\033[36m'
    RED=$'\033[31m'
    RESET=$'\033[0m'
else
    BOLD="" DIM="" GREEN="" YELLOW="" CYAN="" RED="" RESET=""
fi

# ------------------------------------------------------------------
# Help
# ------------------------------------------------------------------
usage() {
    cat <<EOF
${BOLD}$PROGRAM v$VERSION${RESET} — Clean heavy files from VASP calculations

${BOLD}USAGE${RESET}
  $PROGRAM [OPTIONS] [DIR...]

  If no DIR is given, the current directory is used.

${BOLD}REMOVED BY DEFAULT${RESET}
  WAVECAR  CHG  TMPCAR  vasprun.tmp  PCDAT  WAVEDER  STOPCAR  REPORT  HILLSPOT
  .wolfpack/   (hidden pipeline scratch + old SLURM logs; safe once slurm.sh exists)

${BOLD}REMOVED WITH --aggressive${RESET}
  CHGCAR  LOCPOT  ELFCAR  PROCAR  DOSCAR  EIGENVAL  XDATCAR  AECCAR0/1/2

${BOLD}ALWAYS PRESERVED${RESET}
  INCAR  POSCAR  CONTCAR  KPOINTS  POTCAR  OUTCAR  OSZICAR  vasprun.xml
  IBZKPT  + anything not in the lists above

${BOLD}OPTIONS${RESET}
  -n, --dry-run       Show what would be deleted, don't delete anything
  -r, --recursive     Look for VASP folders recursively under DIR
  -a, --aggressive    Also remove CHGCAR, LOCPOT, ELFCAR, etc.
  -f, --force         Don't ask for confirmation (use with care)
  --allow-running-chain
                      Clean even where a chunked run is live. Refused by default
                      because WAVECAR, which is on the removal list, is that
                      run's restart object between chunks. -f does NOT override
                      this: -f skips a prompt, this is a correctness guard.
  -v, --verbose       Print extra info
  -h, --help          This help
  -V, --version       Print version

${BOLD}EXAMPLES${RESET}
  $PROGRAM                     # clean current dir (asks for confirmation)
  $PROGRAM -n .                # dry-run on current dir
  $PROGRAM -r ./relax_runs     # clean all VASP folders under relax_runs/
  $PROGRAM -a -f calc1 calc2   # aggressive clean of two folders, no prompt

EOF
}

# ------------------------------------------------------------------
# Arg parsing
# ------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)    DRY_RUN=1; shift ;;
        -r|--recursive)  RECURSIVE=1; shift ;;
        -a|--aggressive) AGGRESSIVE=1; shift ;;
        -f|--force)      FORCE=1; shift ;;
        --allow-running-chain) ALLOW_RUNNING_CHAIN=1; shift ;;
        -v|--verbose)    VERBOSE=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        -V|--version)    echo "$PROGRAM $VERSION"; exit 0 ;;
        --)              shift; while [[ $# -gt 0 ]]; do DIRS+=("$1"); shift; done ;;
        -*)              echo "${RED}Unknown option: $1${RESET}" >&2; usage; exit 1 ;;
        *)               DIRS+=("$1"); shift ;;
    esac
done

[[ ${#DIRS[@]} -eq 0 ]] && DIRS=(".")

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

# A directory is "VASP-like" if it contains at least one of the
# canonical input/output files.
is_vasp_dir() {
    local d="$1"
    [[ -f "$d/INCAR"       || -f "$d/POSCAR"     ||
       -f "$d/OUTCAR"      || -f "$d/vasprun.xml" ]]
}

human_size() {
    # human-readable size of a file OR directory; "-" if missing
    [[ -e "$1" ]] && du -sh "$1" 2>/dev/null | awk '{print $1}' || echo "-"
}

human_total() {
    # human readable from a kB integer
    local kb="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B $((kb*1024))
    else
        echo "${kb}K"
    fi
}

# Print list of files (full paths) to remove in directory $1
gather_targets() {
    local d="$1"
    local targets=("${DEFAULT_REMOVE[@]}")
    if [[ $AGGRESSIVE -eq 1 ]]; then
        targets+=("${AGGRESSIVE_REMOVE[@]}")
    fi

    local f
    local found=()
    for f in "${targets[@]}"; do
        [[ -f "$d/$f" ]] && found+=("$d/$f")
    done

    # also catch gzipped versions e.g. WAVECAR.gz, CHGCAR.gz
    for f in "${targets[@]}"; do
        [[ -f "$d/$f.gz" ]] && found+=("$d/$f.gz")
    done

    # hidden pipeline scratch/state dir (vasp-dry-run/recommend/test). Pure
    # scratch + old SLURM logs once you have slurm.sh + report.out, so it is
    # always safe to remove. It is a directory, so clean_dir uses 'rm -rf'.
    [[ -d "$d/.wolfpack" ]] && found+=("$d/.wolfpack")

    if [[ ${#found[@]} -gt 0 ]]; then
        printf '%s\n' "${found[@]}"
    fi
}

# Clean a single VASP directory
# Is a chunked run still live in this directory?
#
# Such a run keeps its restart objects -- WAVECAR above all -- in the calculation
# folder between jobs, and WAVECAR is in DEFAULT_REMOVE. Deleting it mid-run makes
# every later chunk restart from scratch, so the run silently never converges. A
# stale marker (node crash, scancel) must not block cleaning forever, so the
# scheduler is asked whether the job is genuinely still there.
chain_is_running() {
    local d="$1" env="$1/wolfpack_chain/chain.env" jid
    [[ -f "$env" ]] || return 1
    grep -qE '^[[:space:]]*chain_state="?running"?' "$env" 2>/dev/null || return 1
    jid="$(tr -dc '0-9' < "$d/wolfpack_chain/RUNNING" 2>/dev/null)"
    [[ -n "$jid" ]] || return 1
    command -v squeue >/dev/null 2>&1 || return 0      # no scheduler -> stay cautious
    [[ -n "$(squeue -h -j "$jid" 2>/dev/null)" ]]
}

clean_dir() {
    local d="$1"

    if ! is_vasp_dir "$d"; then
        [[ $VERBOSE -eq 1 ]] && echo "${DIM}skip (not VASP): $d${RESET}"
        return 0
    fi

    # Checked HERE, per directory, and not once in main(): with -r over a parent
    # this is what stops one command from wrecking every chain underneath it.
    #
    # -f does NOT override. -f suppresses the confirmation prompt, which is a
    # convenience; this is a correctness guard, and the two must not share a flag.
    # A chunk directory of vasp-relax-loop (wolfpack_chain/NNN, NNN.tryK) holds
    # the running VASP and the restart files of the next chunk: it belongs to
    # the chain, and is refused while that chain is live.
    local _real _root
    _real="$(readlink -f "$d")"
    if [[ $_real == */wolfpack_chain*/* ]]; then
        _root="${_real%%/wolfpack_chain*}"
        if (( ! ALLOW_RUNNING_CHAIN )) && chain_is_running "$_root"; then
            echo "${YELLOW}!${RESET} ${BOLD}$d${RESET}: a directory of a live chunked run; refusing." >&2
            return 0
        fi
    fi

    if (( ! ALLOW_RUNNING_CHAIN )) && chain_is_running "$d"; then
        local _jid; _jid="$(tr -dc '0-9' < "$d/wolfpack_chain/RUNNING" 2>/dev/null)"
        echo "${YELLOW}!${RESET} ${BOLD}$d${RESET}: a chunked run is live here (job ${_jid}); refusing." >&2
        echo "  ${DIM}Its WAVECAR is the restart object between chunks and is on the removal list.${RESET}" >&2
        echo "  ${DIM}Stop it first, or pass --allow-running-chain if you are sure.${RESET}" >&2
        return 0
    fi

    local files=()
    mapfile -t files < <(gather_targets "$d")

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "${GREEN}✓${RESET} ${BOLD}$d${RESET}: already clean"
        return 0
    fi

    echo ""
    echo "${BOLD}${CYAN}▸ $d${RESET}"

    local total_kb=0
    local f size kb
    for f in "${files[@]}"; do
        size=$(human_size "$f")
        printf "    %-8s  %s\n" "$size" "$(basename "$f")"
        kb=$(du -sk "$f" 2>/dev/null | awk '{print $1}'); kb=${kb//[^0-9]/}
        total_kb=$((total_kb + ${kb:-0}))
    done
    echo "    ${DIM}---------------${RESET}"
    printf "    %-8s  %s\n" "$(human_total "$total_kb")" "${BOLD}total${RESET}"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "    ${YELLOW}(dry-run — nothing removed)${RESET}"
        return 0
    fi

    if [[ $FORCE -eq 0 ]]; then
        read -r -p "    Delete these files? [y/N] " ans
        case "$ans" in
            y|Y|yes|YES|Yes) ;;
            *) echo "    ${YELLOW}skipped${RESET}"; return 0 ;;
        esac
    fi

    for f in "${files[@]}"; do
        rm -rf -- "$f"           # -r so the .wolfpack/ dir is removed too
        [[ $VERBOSE -eq 1 ]] && echo "    ${DIM}rm $f${RESET}"
    done
    echo "    ${GREEN}cleaned (~$(human_total "$total_kb") freed)${RESET}"
}

# Process one path (file/dir/recursive)
process_path() {
    local p="$1"
    if [[ ! -d "$p" ]]; then
        echo "${RED}not a directory: $p${RESET}" >&2
        return 1
    fi

    if [[ $RECURSIVE -eq 1 ]]; then
        # iterate every subdirectory; clean_dir will filter non-VASP ones. A
        # chain's own directories (wolfpack_chain*/) are left to the chain: it
        # keeps only what the next chunk needs.
        while IFS= read -r -d '' sub; do
            clean_dir "$sub"
        done < <(find "$p" \( -type d -name 'wolfpack_chain*' -prune \) -o \( -type d -print0 \))
    else
        clean_dir "$p"
    fi
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
echo "${BOLD}$PROGRAM v$VERSION${RESET}"
[[ $DRY_RUN    -eq 1 ]] && echo "  mode: ${YELLOW}dry-run${RESET}"
[[ $AGGRESSIVE -eq 1 ]] && echo "  mode: ${YELLOW}aggressive${RESET} (also removing CHGCAR/LOCPOT/ELFCAR/...)"
[[ $FORCE      -eq 1 ]] && echo "  mode: ${YELLOW}force${RESET} (no prompts)"
[[ $RECURSIVE  -eq 1 ]] && echo "  mode: ${YELLOW}recursive${RESET}"

for d in "${DIRS[@]}"; do
    process_path "$d"
done

echo ""
echo "${GREEN}Done.${RESET}"
