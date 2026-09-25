#!/bin/bash
###############################################################################
# wolfpack.sh   (invoked on PATH as: wolfpack)
#
# Entry point / quick-reference for the WolfPack-DFT toolkit.  Prints the
# project guides, rendered with 'glow' when available, plain otherwise.
#
# The guides live next to this script (the ~/.local/bin symlink is resolved
# back to the toolkit directory), so the command works from any folder and no
# matter where you cloned the toolkit.
#
# USAGE
#   wolfpack                 # the toolkit README (same as --help)
#   wolfpack --help | -h     # the toolkit README
#   wolfpack --plots         # the plotting guide (PlotReadme.md)
#   wolfpack --list          # one-line list of every installed command
#   wolfpack --where         # print the toolkit directory and exit
#   wolfpack --help | less   # paginate the output
#
# (Replaces the former 'my-shortcuts' command.)
###############################################################################

# Resolve the real path of this script even when invoked through a symlink in
# ~/.local/bin, then look for the guides in the same directory.
src="${BASH_SOURCE[0]}"
while [[ -h "$src" ]]; do
    target="$(readlink "$src")"
    if [[ "$target" == /* ]]; then src="$target"; else src="$(dirname "$src")/$target"; fi
done
script_dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"

# Render a Markdown guide: 'glow' if installed, plain cat otherwise.
show_doc() {
    local name="$1" doc=""
    # Search order: alongside the resolved script, then the legacy install dir.
    for candidate in "$script_dir/$name" "$HOME/Useful_scripts/$name"; do
        [[ -f "$candidate" ]] && { doc="$candidate"; break; }
    done
    if [[ -z "$doc" ]]; then
        echo "$name not found next to the toolkit (looked in $script_dir)." >&2
        return 1
    fi
    if command -v glow >/dev/null 2>&1; then glow "$doc"; else cat "$doc"; fi
}

# One-line summary of every command the toolkit installs.  Kept here (not in
# install.sh) so it works even when the toolkit is run straight from the repo.
list_commands() {
    cat <<'EOF'
WolfPack-DFT commands

  SETUP
    vasp-configure          Build/refresh the cluster profile (partitions, VASP, policy)
    wolfpack                This guide  (wolfpack --help / --plots / --list)

  PARALLELIZATION PIPELINE  (run in a folder with INCAR KPOINTS POSCAR POTCAR)
    vasp-dry-run            STAGE 1  1-rank dry run -> .wolfpack/dryrun_OUTCAR
    vasp-recommend-slurm    STAGE 2  KPAR/NCORE/NPAR + memory + slurm.sh
    vasp-test               STAGE 3  benchmark the fixed config -> slurm_vasptest.sh

  CHUNKED RUNS  (for queues that punish a long walltime)
    vasp-scf-loop           Converge an SCF as a chain of short, self-resubmitting jobs
    vasp-relax-loop         A relaxation as a chain of jobs of NSW ionic steps each, every
                            one asking the walltime its steps are estimated to need
    backfill-study          How long this job waits in the queue, at its walltime and others,
                            predicted with your fairshare; and your fairshare now

  DIAGNOSIS
    vasp-diagnose           Why did a run die?  (OOM/TIME/CRASH) + data salvage
    vasp-check              What a run produced, as data: convergence, forces, gap, moments + checks

  THE QUEUE
    vasp-slurm-report       What a finished job actually cost (CPU/mem/time efficiency)

  PLOTTING
    vasp-quick-plots        One-shot publication plots (bands / DOS / Wannier90)
    vasp-plot-fatbandsdos   Fat bands + projected DOS

  UTILITIES
    run-scf-steps           Chained SCF workflow
    run-nscf-steps          Chained NSCF (bands/DOS) workflow
    collect-u-data          Gather data for a Hubbard-U fit
    vasp-calculate-u        Linear-response U from the collected data
    build-supercell         Build a plain supercell from a POSCAR
    build-magnetic-configs  Enumerate the inequivalent spin orderings of a POSCAR
                            into one ready-to-run folder each
    vasp-clean              Remove regenerable outputs (keeps inputs)
    vasp-nuke               Remove everything except the inputs

  Full documentation:  wolfpack --help        Plotting guide:  wolfpack --plots
EOF
}

case "${1:-}" in
    ""|-h|--help|help)
        show_doc "Readme.md" ;;
    --plots|--plotting|plots)
        show_doc "PlotReadme.md" ;;
    --list|-l|list)
        list_commands ;;
    --where|--dir)
        echo "$script_dir" ;;
    *)
        echo "wolfpack: unknown option '$1'" >&2
        echo "Try: wolfpack --help | --plots | --list | --where" >&2
        exit 2 ;;
esac
