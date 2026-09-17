#!/usr/bin/env bash
###############################################################################
# install.sh   --  WolfPack-DFT toolkit installer
#
# WHAT IT DOES
#   1. Symlinks every toolkit script into a bin directory on your $PATH
#      (default: ~/.local/bin), using the canonical command name -- so e.g.
#      `vasp-clean` invokes vasp_clean.sh, `vasp-test` invokes vasp_test.sh, etc.
#   2. Creates a conda environment with every Python dependency the toolkit
#      needs (numpy, scipy, matplotlib, pymatgen) plus the optional `glow`
#      Markdown renderer used by `wolfpack`.
#   3. Makes sure the bin directory is on your $PATH (adds a small block to
#      your shell rc file if it is not).
#   4. Runs `vasp-configure` to build your cluster profile: your email, the
#      VASP module(s) to load (auto-detected from `module avail`), your debug
#      and main partition names, cores/node, memory/node and the max cores you
#      may request. Those values flow into every SLURM script the toolkit emits.
#   5. Records exactly what it did in a manifest so `uninstall.sh` can undo it.
#
# USAGE
#   ./install.sh                 # full install + interactive cluster wizard
#   ./install.sh --email me@x.edu # pre-fill the notification email
#   ./install.sh --env myenv     # install Python deps into env 'myenv'
#   ./install.sh --no-conda      # only symlink scripts; skip all conda work
#   ./install.sh --bin-dir DIR   # symlink into DIR instead of ~/.local/bin
#   ./install.sh --no-path       # do not touch any shell rc file
#   ./install.sh --no-configure  # skip the cluster wizard (run vasp-configure later)
#   ./install.sh -y              # no prompts; auto-detect cluster + accept defaults
#   ./install.sh --help
#
# The scripts are NOT copied -- they are symlinked in place, so the toolkit
# keeps working from this directory and `git pull` updates every command at
# once. Do not delete this directory after installing.
###############################################################################
set -uo pipefail

# --------------------------------------------------------------------------- #
# Canonical mapping:  command-name  ->  source file in this directory.
# Edit here (and only here) if you add a script.  The command name is what you
# type in the terminal; the file is what lives in the toolkit directory.
# --------------------------------------------------------------------------- #
COMMAND_MAP=(
    "vasp-configure|vasp_configure.sh"
    "vasp-dry-run|vasp_dry_run.sh"
    "vasp-test|vasp_test.sh"
    "vasp-recommend-slurm|vasp_recommend_slurm.py"
    "vasp-diagnose|vasp_diagnose.sh"
    "vasp-check|vasp_check.sh"
    "vasp-clean|vasp_clean.sh"
    "vasp-nuke|vasp_nuke.sh"
    "run-nscf-steps|run_nscf_steps.sh"
    "run-scf-steps|run_scf_steps.sh"
    "collect-u-data|collect_u_data.sh"
    "vasp-calculate-u|vasp_calculate_u.py"
    "vasp-plot-fatbandsdos|vasp_plot_fatbandsdos.py"
    "vasp-quick-plots|vasp_quick_plots.sh"
    "build-supercell|build_supercell.py"
    "wolfpack|wolfpack.sh"
)

# Commands this toolkit USED to install under a different name.  Their symlinks
# are removed on install (only when they point into this toolkit) so a rename
# never leaves a dangling command behind in $BIN_DIR.
RETIRED_COMMANDS=(
    "my-shortcuts"          # renamed 2026-08 -> wolfpack (wolfpack --help)
)

# Conda packages required by the Python scripts (channel: conda-forge).
CONDA_PKGS=(python numpy scipy matplotlib pymatgen)
# Optional extras (best-effort; install failure is not fatal).
CONDA_PKGS_OPTIONAL=(glow)

# --------------------------------------------------------------------------- #
# Defaults / configuration
# --------------------------------------------------------------------------- #
SRC_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BIN_DIR="$HOME/.local/bin"
ENV_NAME="wolfpack-dft"
DO_CONDA=1
DO_PATH=1
DO_CONFIGURE=1
ASSUME_YES=0
INSTALL_EMAIL=""
SHARE_DIR="$HOME/.local/share/wolfpack-dft"
MANIFEST="$SHARE_DIR/install_manifest.txt"
CONFIG_FILE="$HOME/.config/wolfpack-dft/cluster.conf"
PATH_TAG_OPEN="# >>> WolfPack-DFT >>>"
PATH_TAG_CLOSE="# <<< WolfPack-DFT <<<"

c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
info()  { printf '%s\n' "${c_bold}==>${c_rst} $*"; }
ok()    { printf '%s\n' "    ${c_grn}OK${c_rst}   $*"; }
warn()  { printf '%s\n' "    ${c_yel}WARN${c_rst} $*" >&2; }
err()   { printf '%s\n' "    ${c_red}ERROR${c_rst} $*" >&2; }

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'; exit 0; }

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin-dir)  BIN_DIR="${2:?--bin-dir needs a path}"; shift 2 ;;
        --env)      ENV_NAME="${2:?--env needs a name}"; shift 2 ;;
        --email)    INSTALL_EMAIL="${2:?--email needs a value}"; shift 2 ;;
        --no-conda) DO_CONDA=0; shift ;;
        --no-path)  DO_PATH=0; shift ;;
        --no-configure) DO_CONFIGURE=0; shift ;;
        -y|--yes)   ASSUME_YES=1; shift ;;
        -h|--help)  usage ;;
        *) err "Unknown option: $1"; echo "Try: ./install.sh --help" >&2; exit 2 ;;
    esac
done

confirm() {  # confirm "question" -> 0 if yes
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local reply
    read -r -p "    $1 [Y/n] " reply || return 1
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# --------------------------------------------------------------------------- #
# Sanity checks
# --------------------------------------------------------------------------- #
info "WolfPack-DFT installer"
echo "    toolkit directory : $SRC_DIR"
echo "    bin directory     : $BIN_DIR"
echo "    conda env         : $([[ $DO_CONDA -eq 1 ]] && echo "$ENV_NAME" || echo '(skipped)')"
echo

missing=0
for entry in "${COMMAND_MAP[@]}"; do
    file="${entry#*|}"
    if [[ ! -e "$SRC_DIR/$file" ]]; then
        err "missing source file: $file"; missing=1
    fi
done
[[ $missing -eq 0 ]] || { err "Aborting: toolkit files are incomplete."; exit 1; }

# --------------------------------------------------------------------------- #
# 1. Symlink the commands
# --------------------------------------------------------------------------- #
info "Linking commands into $BIN_DIR"
mkdir -p "$BIN_DIR" "$SHARE_DIR"

# Start (re)writing the manifest.
{
    echo "# WolfPack-DFT install manifest -- generated $(date -Iseconds)"
    echo "INSTALL_DIR=$SRC_DIR"
    echo "BIN_DIR=$BIN_DIR"
} > "$MANIFEST"

linked=0
for entry in "${COMMAND_MAP[@]}"; do
    cmd="${entry%%|*}"; file="${entry#*|}"
    target="$SRC_DIR/$file"
    link="$BIN_DIR/$cmd"

    chmod +x "$target" 2>/dev/null || true

    if [[ -e "$link" && ! -L "$link" ]]; then
        warn "$cmd exists and is NOT a symlink -- leaving it untouched."
        continue
    fi
    ln -sfn "$target" "$link"
    echo "SYMLINK=$link" >> "$MANIFEST"
    printf '    %-22s -> %s\n' "$cmd" "$file"
    linked=$((linked + 1))
done
ok "$linked commands linked."

# Drop symlinks left by earlier versions under an old command name.  Only ours
# are touched: the link must resolve into $SRC_DIR (or be dangling into it).
retired=0
for cmd in "${RETIRED_COMMANDS[@]}"; do
    link="$BIN_DIR/$cmd"
    [[ -L "$link" ]] || continue
    dest="$(readlink "$link")"
    case "$dest" in
        "$SRC_DIR"/*) rm -f "$link"
                      printf '    %-22s (retired, removed)\n' "$cmd"
                      retired=$((retired + 1)) ;;
    esac
done
(( retired > 0 )) && ok "$retired retired command(s) removed."
echo

# --------------------------------------------------------------------------- #
# 2. Conda dependencies
# --------------------------------------------------------------------------- #
if [[ $DO_CONDA -eq 1 ]]; then
    info "Installing Python dependencies into conda env '$ENV_NAME'"
    CONDA_BIN=""
    if command -v mamba >/dev/null 2>&1; then CONDA_BIN="mamba"
    elif command -v conda >/dev/null 2>&1; then CONDA_BIN="conda"; fi

    if [[ -z "$CONDA_BIN" ]]; then
        warn "Neither 'mamba' nor 'conda' found on PATH -- skipping Python deps."
        warn "Install Miniconda/Miniforge, then re-run:  ./install.sh"
        echo "ENV_CREATED=no" >> "$MANIFEST"
    else
        echo "    using: $CONDA_BIN"
        env_exists=0
        if conda env list 2>/dev/null | awk '{print $1}' | grep -qxF "$ENV_NAME"; then
            env_exists=1
        fi

        if [[ $env_exists -eq 1 ]]; then
            info "Env '$ENV_NAME' already exists -- installing/updating packages in it."
            "$CONDA_BIN" install -y -n "$ENV_NAME" -c conda-forge "${CONDA_PKGS[@]}"
            conda_rc=$?
            echo "ENV_CREATED=no" >> "$MANIFEST"   # do not let uninstall delete a pre-existing env
        else
            "$CONDA_BIN" create -y -n "$ENV_NAME" -c conda-forge "${CONDA_PKGS[@]}"
            conda_rc=$?
            [[ $conda_rc -eq 0 ]] && echo "ENV_CREATED=yes" >> "$MANIFEST" \
                                  || echo "ENV_CREATED=no"  >> "$MANIFEST"
        fi
        echo "ENV_NAME=$ENV_NAME" >> "$MANIFEST"

        if [[ ${conda_rc:-1} -eq 0 ]]; then
            ok "Core Python deps installed: ${CONDA_PKGS[*]}"
            # Optional extras -- never fatal.
            if "$CONDA_BIN" install -y -n "$ENV_NAME" -c conda-forge \
                    "${CONDA_PKGS_OPTIONAL[@]}" >/dev/null 2>&1; then
                ok "Optional extras installed: ${CONDA_PKGS_OPTIONAL[*]}"
            else
                warn "Optional extras (${CONDA_PKGS_OPTIONAL[*]}) not installed -- harmless."
            fi
        else
            err "conda failed (exit $conda_rc). Scripts are linked but Python deps are missing."
        fi
    fi
    echo
else
    info "Skipping conda dependencies (--no-conda)."
    echo "ENV_CREATED=no" >> "$MANIFEST"
    echo
fi

# --------------------------------------------------------------------------- #
# 3. Ensure BIN_DIR is on PATH
# --------------------------------------------------------------------------- #
PATH_EDITED="no"
if [[ $DO_PATH -eq 1 ]]; then
    if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
        ok "$BIN_DIR is already on your PATH."
    else
        rc="$HOME/.bashrc"; [[ -n "${ZSH_VERSION:-}" ]] && rc="$HOME/.zshrc"
        info "Adding $BIN_DIR to PATH in $rc"
        if grep -qF "$PATH_TAG_OPEN" "$rc" 2>/dev/null; then
            ok "PATH block already present in $rc."
        else
            {
                echo ""
                echo "$PATH_TAG_OPEN"
                echo "export PATH=\"$BIN_DIR:\$PATH\""
                echo "$PATH_TAG_CLOSE"
            } >> "$rc"
            PATH_EDITED="$rc"
            ok "PATH updated. Run 'source $rc' or open a new shell to pick it up."
        fi
    fi
else
    info "Skipping PATH setup (--no-path)."
fi
echo "PATH_EDITED=$PATH_EDITED" >> "$MANIFEST"
echo

# --------------------------------------------------------------------------- #
# 4. Cluster profile (email, VASP modules, partitions, cores, memory)
# --------------------------------------------------------------------------- #
# Does this machine look like an HPC cluster (SLURM / module system present)?
is_cluster() {
    command -v sbatch >/dev/null 2>&1 || command -v sinfo >/dev/null 2>&1 \
        || type module >/dev/null 2>&1 || type ml >/dev/null 2>&1 \
        || [[ -n "${LMOD_CMD:-}" ]]
}

CONFIGURED="no"
if [[ $DO_CONFIGURE -eq 1 ]] && ! is_cluster; then
    info "No SLURM / module system detected — skipping cluster setup."
    echo "    The plotting tools (vasp-plot-fatbandsdos, vasp-quick-plots) and"
    echo "    the analysis tools work fine WITHOUT a cluster, so you can install"
    echo "    here and plot from copied calculation folders."
    echo "    Run ${c_bold}vasp-configure${c_rst} later if you move onto a cluster."
elif [[ $DO_CONFIGURE -eq 1 ]]; then
    info "Configuring your cluster (partitions, VASP modules, email, limits)"
    configure_cmd=("$SRC_DIR/vasp_configure.sh")
    [[ -n "$INSTALL_EMAIL" ]] && configure_cmd+=(--email "$INSTALL_EMAIL")
    if [[ $ASSUME_YES -eq 1 ]]; then
        # Non-interactive install: detect + defaults, no prompts.
        if "${configure_cmd[@]}" --non-interactive; then CONFIGURED="yes"; fi
        echo "    (re-run 'vasp-configure' any time to adjust these values.)"
    else
        echo "    A short wizard will detect your VASP modules and SLURM"
        echo "    partitions and ask you to confirm. Press Enter to accept a"
        echo "    detected/default value."
        if confirm "Run cluster configuration now?"; then
            "${configure_cmd[@]}" && CONFIGURED="yes"
        else
            echo "    Skipped. Run ${c_bold}vasp-configure${c_rst} before submitting jobs."
        fi
    fi
else
    info "Skipping cluster configuration (--no-configure)."
    echo "    Run ${c_bold}vasp-configure${c_rst} later to set email/partitions/modules."
fi
[[ "$CONFIGURED" == "yes" ]] && echo "CONFIG_FILE=$CONFIG_FILE" >> "$MANIFEST"
echo

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #
info "${c_grn}Installation complete.${c_rst}"
echo "    Manifest: $MANIFEST"
[[ "$CONFIGURED" == "yes" ]] && echo "    Cluster profile: $CONFIG_FILE"
if [[ $DO_CONDA -eq 1 ]]; then
    echo
    echo "    To use the Python tools (vasp-calculate-u, build-supercell,"
    echo "    vasp-plot-fatbandsdos), activate the environment first:"
    echo "        ${c_bold}conda activate $ENV_NAME${c_rst}"
fi
echo
echo "    Quick check (after opening a new shell):"
echo "        wolfpack --help       # print the toolkit README"
echo "        vasp-check --help"
echo "        vasp-configure --show # review your cluster profile"
echo
echo "    To remove everything later:  ./uninstall.sh"
