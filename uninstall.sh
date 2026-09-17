#!/usr/bin/env bash
###############################################################################
# uninstall.sh   --  WolfPack-DFT toolkit uninstaller (nuclear)
#
# Completely removes every trace of the toolkit that install.sh created:
#   1. All command symlinks in the bin directory (~/.local/bin/...).
#   2. The conda environment -- ONLY if install.sh created it for you
#      (a pre-existing env you chose is left alone unless you pass --purge-env).
#   3. The PATH block install.sh added to your shell rc file.
#   4. The cluster profile (~/.config/wolfpack-dft) and the manifest / state
#      directory (~/.local/share/wolfpack-dft).
#   5. A legacy ~/Useful_scripts install directory, if it is clearly ours.
#
# It does NOT delete this toolkit source directory unless you pass --purge-repo.
#
# USAGE
#   ./uninstall.sh                # remove everything (asks before destructive steps)
#   ./uninstall.sh -y             # remove everything, no prompts
#   ./uninstall.sh --keep-env     # keep the conda environment
#   ./uninstall.sh --purge-env    # remove the conda env even if it pre-existed
#   ./uninstall.sh --purge-repo   # ALSO delete this toolkit source directory
#   ./uninstall.sh --help
###############################################################################
set -uo pipefail

SHARE_DIR="$HOME/.local/share/wolfpack-dft"
MANIFEST="$SHARE_DIR/install_manifest.txt"
PATH_TAG_OPEN="# >>> WolfPack-DFT >>>"
PATH_TAG_CLOSE="# <<< WolfPack-DFT <<<"

# Canonical command names -- fallback list used when no manifest is present.
KNOWN_COMMANDS=(
    vasp-configure vasp-dry-run vasp-test vasp-recommend-slurm vasp-check
    vasp-clean vasp-nuke run-nscf-steps run-scf-steps collect-u-data
    vasp-calculate-u vasp-plot-fatbandsdos vasp-quick-plots build-supercell
    wolfpack my-shortcuts
)

# Cluster profile written by vasp-configure (removed on uninstall).
CONFIG_DIR="$HOME/.config/wolfpack-dft"

ASSUME_YES=0
KEEP_ENV=0
PURGE_ENV=0
PURGE_REPO=0

c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
info() { printf '%s\n' "${c_bold}==>${c_rst} $*"; }
ok()   { printf '%s\n' "    ${c_grn}removed${c_rst} $*"; }
warn() { printf '%s\n' "    ${c_yel}WARN${c_rst} $*" >&2; }
usage(){ sed -n '2,28p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)     ASSUME_YES=1; shift ;;
        --keep-env)   KEEP_ENV=1; shift ;;
        --purge-env)  PURGE_ENV=1; shift ;;
        --purge-repo) PURGE_REPO=1; shift ;;
        -h|--help)    usage ;;
        *) warn "Unknown option: $1"; echo "Try: ./uninstall.sh --help" >&2; exit 2 ;;
    esac
done

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local reply
    read -r -p "    $1 [y/N] " reply || return 1
    [[ "$reply" =~ ^[Yy] ]]
}

# --------------------------------------------------------------------------- #
# Load manifest values (if present)
# --------------------------------------------------------------------------- #
INSTALL_DIR=""; BIN_DIR="$HOME/.local/bin"; ENV_NAME=""; ENV_CREATED="no"; PATH_EDITED="no"
MANIFEST_SYMLINKS=()

if [[ -f "$MANIFEST" ]]; then
    info "Reading manifest: $MANIFEST"
    while IFS= read -r line; do
        case "$line" in
            INSTALL_DIR=*) INSTALL_DIR="${line#INSTALL_DIR=}" ;;
            BIN_DIR=*)     BIN_DIR="${line#BIN_DIR=}" ;;
            ENV_NAME=*)    ENV_NAME="${line#ENV_NAME=}" ;;
            ENV_CREATED=*) ENV_CREATED="${line#ENV_CREATED=}" ;;
            PATH_EDITED=*) PATH_EDITED="${line#PATH_EDITED=}" ;;
            CONFIG_FILE=*) CONFIG_DIR="$(dirname "${line#CONFIG_FILE=}")" ;;
            SYMLINK=*)     MANIFEST_SYMLINKS+=("${line#SYMLINK=}") ;;
        esac
    done < "$MANIFEST"
else
    warn "No manifest found -- falling back to removing known command names from $BIN_DIR."
fi
echo

info "About to remove the WolfPack-DFT toolkit installation."
if ! confirm "Proceed?"; then echo "    Aborted."; exit 0; fi
echo

# --------------------------------------------------------------------------- #
# 1. Remove command symlinks
# --------------------------------------------------------------------------- #
info "Removing command symlinks"
removed=0
if [[ ${#MANIFEST_SYMLINKS[@]} -gt 0 ]]; then
    for link in "${MANIFEST_SYMLINKS[@]}"; do
        if [[ -L "$link" ]]; then
            rm -f "$link" && { ok "$link"; removed=$((removed+1)); }
        fi
    done
else
    # Fallback: only remove a symlink if it points at a *.sh/*.py/vasp-clean file
    # whose directory looks like the toolkit (contains vasp_recommend_slurm.py).
    for cmd in "${KNOWN_COMMANDS[@]}"; do
        link="$BIN_DIR/$cmd"
        if [[ -L "$link" ]]; then
            tgt="$(readlink -f "$link" 2>/dev/null)"
            tgtdir="$(dirname "$tgt" 2>/dev/null)"
            if [[ -n "$tgtdir" && -e "$tgtdir/vasp_recommend_slurm.py" ]]; then
                rm -f "$link" && { ok "$link"; removed=$((removed+1)); }
            else
                warn "$link does not resolve into a toolkit dir -- left in place."
            fi
        fi
    done
fi
[[ $removed -eq 0 ]] && warn "No command symlinks found to remove."
echo

# --------------------------------------------------------------------------- #
# 2. Remove the conda environment
# --------------------------------------------------------------------------- #
if [[ -n "$ENV_NAME" && $KEEP_ENV -eq 0 ]]; then
    if [[ "$ENV_CREATED" == "yes" || $PURGE_ENV -eq 1 ]]; then
        CONDA_BIN=""
        command -v mamba >/dev/null 2>&1 && CONDA_BIN="mamba"
        [[ -z "$CONDA_BIN" ]] && command -v conda >/dev/null 2>&1 && CONDA_BIN="conda"
        if [[ -n "$CONDA_BIN" ]]; then
            info "Removing conda environment '$ENV_NAME'"
            if confirm "Delete conda env '$ENV_NAME'?"; then
                "$CONDA_BIN" env remove -y -n "$ENV_NAME" \
                    && ok "conda env $ENV_NAME" \
                    || warn "Could not remove env '$ENV_NAME' (already gone?)."
            else
                warn "Kept conda env '$ENV_NAME'."
            fi
        else
            warn "conda/mamba not found -- cannot remove env '$ENV_NAME'."
        fi
        echo
    else
        info "Conda env '$ENV_NAME' pre-existed before install -- keeping it."
        echo "    (use --purge-env to delete it anyway.)"
        echo
    fi
fi

# --------------------------------------------------------------------------- #
# 3. Remove the PATH block from the shell rc file
# --------------------------------------------------------------------------- #
strip_path_block() {
    local rc="$1"
    [[ -f "$rc" ]] || return 0
    grep -qF "$PATH_TAG_OPEN" "$rc" || return 0
    info "Removing PATH block from $rc"
    local tmp; tmp="$(mktemp)"
    # Delete the tagged block (and a single blank line immediately before it).
    sed "/^${PATH_TAG_OPEN}\$/,/^${PATH_TAG_CLOSE}\$/d" "$rc" > "$tmp"
    # Collapse a trailing blank line left behind, then install.
    awk 'NR>1 && prev=="" && $0=="" {next} {print; prev=$0}' "$tmp" > "$tmp.2"
    mv "$tmp.2" "$rc"; rm -f "$tmp"
    ok "PATH block from $rc"
}
if [[ "$PATH_EDITED" != "no" && -n "$PATH_EDITED" ]]; then
    strip_path_block "$PATH_EDITED"
else
    # No manifest, or PATH not edited -- check the usual rc files anyway.
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile"; do
        strip_path_block "$rc"
    done
fi
echo

# --------------------------------------------------------------------------- #
# 4. Remove a legacy ~/Useful_scripts directory if it is clearly ours
# --------------------------------------------------------------------------- #
LEGACY="$HOME/Useful_scripts"
if [[ -d "$LEGACY" && -e "$LEGACY/vasp_recommend_slurm.py" ]]; then
    info "Found legacy install dir: $LEGACY"
    if confirm "Delete $LEGACY and everything in it?"; then
        rm -rf "$LEGACY" && ok "$LEGACY"
    else
        warn "Kept $LEGACY."
    fi
    echo
fi

# --------------------------------------------------------------------------- #
# 5. Remove the cluster profile (vasp-configure) and the state directory
# --------------------------------------------------------------------------- #
if [[ -d "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR" && ok "$CONFIG_DIR  (cluster profile)"
fi
if [[ -d "$SHARE_DIR" ]]; then
    rm -rf "$SHARE_DIR" && ok "$SHARE_DIR"
fi

# --------------------------------------------------------------------------- #
# 6. Optionally delete the toolkit source directory itself
# --------------------------------------------------------------------------- #
SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
TARGET_REPO="${INSTALL_DIR:-$SELF_DIR}"
if [[ $PURGE_REPO -eq 1 ]]; then
    echo
    info "Purging toolkit source directory: $TARGET_REPO"
    if confirm "PERMANENTLY delete $TARGET_REPO?"; then
        # Delete from outside the tree so the running script is not pulled away.
        ( cd /tmp && rm -rf "$TARGET_REPO" ) && echo "    ${c_grn}removed${c_rst} $TARGET_REPO"
    else
        warn "Kept $TARGET_REPO."
    fi
fi

echo
info "${c_grn}WolfPack-DFT has been uninstalled.${c_rst}"
[[ $PURGE_REPO -eq 0 ]] && echo "    (The toolkit source directory $TARGET_REPO was left in place;
    re-run with --purge-repo to delete it too, or remove it by hand.)"
echo "    Open a new shell so the PATH change takes effect."
