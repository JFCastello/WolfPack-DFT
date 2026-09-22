#!/usr/bin/env bash
###############################################################################
# vasp_configure.sh   (invoked on PATH as: vasp-configure)
#
# Build the WolfPack-DFT *cluster profile* -- the small file that tells the
# SLURM-emitting tools (vasp-recommend-slurm, vasp-dry-run, vasp-test) how YOUR
# cluster looks, so they stop being hard-wired to one machine:
#
#   * your notification email,
#   * which VASP to use -- a module OR a locally compiled build on the filesystem
#     (both are auto-detected and offered in one numbered menu),
#   * the names of your debug and main partitions,
#   * cores-per-node and memory-per-node for each,
#   * the maximum number of cores you may request.
#
# Detected values (Lmod/Environment-Modules, sinfo, sacctmgr) are offered as
# defaults; you confirm or edit every one. The result is written to
#
#       ~/.config/wolfpack-dft/cluster.conf   (override with --conf / $WOLFPACK_CLUSTER_CONF)
#
# a plain KEY="value" file, sourced by the shell scripts and parsed by
# vasp-recommend-slurm. Re-run any time to update it.
#
# CUSTOM (build-it-yourself) VASP
#   A locally compiled VASP is a binary on the filesystem, not a module. It is
#   auto-detected under common roots (override with WP_VASP_BUILD_ROOTS) and shown
#   in the version menu as "[custom] ...". It needs a base module for runtime libs,
#   plus either a self-contained wrapper or an extra LD_LIBRARY_PATH. A build can
#   describe itself with a sidecar "<exe>.wpmeta" (KEY=value), e.g.:
#       VASP_EXE=/path/vasp_std_w90       VASP_MODULES=compiler mpi vasp/x-runtime
#       VASP_LD_LIBRARY_PATH=/libA:/libB  VASP_FEATURES=wannier90,hdf5,openmp
#   vasp-configure reads it; otherwise it asks for the base module + LD path.
#
# USAGE
#   vasp-configure                    # interactive wizard
#   vasp-configure --non-interactive  # detect + defaults, no prompts
#   vasp-configure --vasp-modules "aocc/4.2.0 vasp/6.5.0-mpi-zen4-h"
#   vasp-configure --vasp-std /path/vasp_std_w90 --vasp-modules vasp/6.4.3-runtime
#   vasp-configure --show             # print the current profile and exit
#   vasp-configure --edit             # hand-edit the profile in $EDITOR
#   vasp-configure --verify           # load the config and check VASP launches
#   vasp-configure --help
#
# FLAGS (all optional; a provided value pre-fills the wizard / is used as-is
# in --non-interactive mode):
#   --email STR            --vasp-modules "STR"     --vasp-std NAME|PATH
#   --vasp-ld-path "DIR:DIR"  (extra LD_LIBRARY_PATH for a non-RPATH'd build)
#   --main-partition NAME  --debug-partition NAME
#   --main-cpus N          --debug-cpus N
#   --main-mem MB          --debug-mem MB           --max-cores N
#   --debug-max-cores N       (core cap for the vasp-test benchmark job)
#   --chunk-walltime MIN      (walltime of ONE chunk of a chained relax/SCF;
#                              vasp-relax-loop --walltime overrides it per run)
#   --chunk-margin MIN        (minutes kept at the end of a chunk so VASP can
#                              close its ionic step; raised to 8% of the
#                              walltime when that is larger)
#   --main-mem-margin F       (fraction of a MAIN node's RAM left free; 0.02 = 98% usable)
#   --debug-mem-margin F      (same for DEBUG nodes)
#   --module-cmd {ml,module}
#   --conf PATH            --non-interactive | -y    --show  --edit  --verify
#
# IF A JOB DIES WITH "execve(): vasp_std: No such file or directory"
#   The configured modules don't put vasp_std on PATH (usually a missing
#   compiler/MPI prerequisite). No reinstall needed:
#       vasp-configure --verify   # report whether VASP launches with your config
#       vasp-configure            # re-run and set the module line (add the compiler)
#       vasp-configure --edit     # hand-edit WP_VASP_MODULES
###############################################################################
set -uo pipefail

CONF="${WOLFPACK_CLUSTER_CONF:-$HOME/.config/wolfpack-dft/cluster.conf}"
INTERACTIVE=1; SHOW_ONLY=0; EDIT_ONLY=0; VERIFY_ONLY=0

c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cya=$'\033[36m'; c_rst=$'\033[0m'
info() { printf '%s\n' "${c_bold}==>${c_rst} $*"; }
note() { printf '%s\n' "    ${c_cya}$*${c_rst}"; }
warn() { printf '%s\n' "    ${c_yel}WARN${c_rst} $*" >&2; }
usage(){ sed -n '2,60p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'; exit 0; }

# --------------------------------------------------------------------------- #
# Profile variables (pre-seeded by flags / detection / prompts)
# --------------------------------------------------------------------------- #
WP_EMAIL=""; WP_MODULE_CMD=""; WP_MODULE_PURGE="1"; WP_VASP_MODULES=""
WP_VASP_STD="vasp_std"; WP_VASP_GAM="vasp_gam"; WP_VASP_NCL="vasp_ncl"
WP_VASP_LD_LIBRARY_PATH=""        # extra LD_LIBRARY_PATH for non-RPATH'd custom builds
WP_EXTRA_ENV="export OMP_NUM_THREADS=1;export MKL_NUM_THREADS=1"
WP_MAIN_PARTITION=""; WP_DEBUG_PARTITION=""
WP_MAIN_CPUS_PER_NODE=""; WP_DEBUG_CPUS_PER_NODE=""
WP_MAIN_MEM_PER_NODE_MB=""; WP_DEBUG_MEM_PER_NODE_MB=""
WP_MAIN_NUMA_CORES=""; WP_MAX_CORES=""
# Pipeline policy (asked in section 7; not hardcoded in the stage scripts).
WP_TEST_WALLTIME_MIN=""    # debug/test partition walltime cap (min); VASP runs this minus the analysis margin
WP_CHUNK_WALLTIME_MIN=""   # walltime of ONE chunk of a chained relax/SCF (min)
WP_CHUNK_MARGIN_MIN=""     # minutes kept at the end of a chunk so VASP can stop cleanly
WP_MEM_UTIL_MIN=""         # cluster's minimum memory-utilisation policy (fraction, e.g. 0.80)
WP_MEM_UTIL=""             # sizing TARGET the tools aim for (= policy + 1% buffer)
# Memory head-room kept free per node, as a FRACTION of the node's RAM (replaces the
# old absolute WP_DEBUG_RESERVE_GB): 0.02 => 98% of the node is usable. One value per
# partition, because a shared debug/login node usually needs more slack than main.
WP_MAIN_MEM_MARGIN=""      # fraction of a MAIN  node's RAM left free (0.02 = 98% usable)
WP_DEBUG_MEM_MARGIN=""     # fraction of a DEBUG node's RAM left free (0.05 = 95% usable)
WP_DEBUG_MAX_CORES=""      # cap on total cores a DEBUG/test job may request
WP_DEBUG_RESERVE_GB=""     # LEGACY (absolute GB): migrated into WP_DEBUG_MEM_MARGIN
WP_GW_NODE_FRAC=""         # GW SWEET: grow the GW request to this node fraction (speed vs queue); 0=need-based

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
# Every KEY-setting flag records WHICH key it set. With a profile already on
# disk that turns the flag into what its name promises -- set this one value,
# keep the rest -- instead of dropping the user into the full questionnaire.
# The wizard does not preload the existing profile, so without this, honouring
# `vasp-configure --debug-max-cores N` (which vasp-test itself tells people to
# run) meant re-detecting and overwriting every hand-tuned value in the file.
CLI_KEYS=()
_cli(){ printf -v "$1" '%s' "$2"; CLI_KEYS+=("$1"); }

# A value that may legitimately be EMPTY.
#
# "${2:?}" rejects an empty string as well as a missing one, so there was no way
# to say "this machine has no modules" -- `--vasp-modules ""` died with
# "parameter null or not set". That is not a corner case: it is every machine
# whose VASP is an absolute path rather than a module, including a laptop. And
# the empty value matters, because an absent module list used to make the job
# scripts fall back to the modules of the machine this toolkit was written on.
#
# Accept empty, but still refuse to swallow the NEXT FLAG as a value: with
# "${2?}" alone, `--vasp-modules --vasp-std /x` would set the module list to
# "--vasp-std".
_cli_may_be_empty(){                      # $1=var $2=flag $3=raw next arg
    local var="$1" flag="$2" val="${3-__WP_UNSET__}"
    if [[ "$val" == "__WP_UNSET__" ]]; then
        echo "ERROR: $flag needs a value (use '' for none)." >&2; exit 2
    fi
    if [[ "$val" == --* ]]; then
        echo "ERROR: $flag got '$val', which looks like another flag." >&2
        echo "       For 'none', write: $flag ''" >&2; exit 2
    fi
    _cli "$var" "$val"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --email)            _cli WP_EMAIL "${2:?}"; shift 2 ;;
        --module-cmd)       _cli WP_MODULE_CMD "${2:?}"; shift 2 ;;
        --vasp-modules)     _cli_may_be_empty WP_VASP_MODULES "--vasp-modules" "${2-__WP_UNSET__}"; shift 2 ;;
        --vasp-std)         _cli WP_VASP_STD "${2:?}"; shift 2 ;;
        --vasp-ld-path)     _cli_may_be_empty WP_VASP_LD_LIBRARY_PATH "--vasp-ld-path" "${2-__WP_UNSET__}"; shift 2 ;;
        --main-partition)   _cli WP_MAIN_PARTITION "${2:?}"; shift 2 ;;
        --debug-partition)  _cli WP_DEBUG_PARTITION "${2:?}"; shift 2 ;;
        --main-cpus)        _cli WP_MAIN_CPUS_PER_NODE "${2:?}"; shift 2 ;;
        --debug-cpus)       _cli WP_DEBUG_CPUS_PER_NODE "${2:?}"; shift 2 ;;
        --main-mem)         _cli WP_MAIN_MEM_PER_NODE_MB "${2:?}"; shift 2 ;;
        --debug-mem)        _cli WP_DEBUG_MEM_PER_NODE_MB "${2:?}"; shift 2 ;;
        --max-cores)        _cli WP_MAX_CORES "${2:?}"; shift 2 ;;
        --test-walltime)    _cli WP_TEST_WALLTIME_MIN "${2:?}"; shift 2 ;;
        --chunk-walltime)   _cli WP_CHUNK_WALLTIME_MIN "${2:?}"; shift 2 ;;
        --chunk-margin)     _cli WP_CHUNK_MARGIN_MIN "${2:?}"; shift 2 ;;
        --mem-util-min)     _cli WP_MEM_UTIL_MIN "${2:?}"; shift 2 ;;
        --main-mem-margin)  _cli WP_MAIN_MEM_MARGIN "${2:?}"; shift 2 ;;
        --debug-mem-margin) _cli WP_DEBUG_MEM_MARGIN "${2:?}"; shift 2 ;;
        --debug-max-cores)  _cli WP_DEBUG_MAX_CORES "${2:?}"; shift 2 ;;
        # legacy: absolute GB of debug head-room -> converted to a fraction below
        --debug-reserve)    _cli WP_DEBUG_RESERVE_GB "${2:?}"; shift 2 ;;
        --gw-node-frac)     _cli WP_GW_NODE_FRAC "${2:?}"; shift 2 ;;
        --conf)             CONF="${2:?}"; shift 2 ;;
        -y|--non-interactive) INTERACTIVE=0; shift ;;
        --show)             SHOW_ONLY=1; shift ;;
        --edit)             EDIT_ONLY=1; shift ;;
        --verify)           VERIFY_ONLY=1; shift ;;
        -h|--help)          usage ;;
        *) warn "Unknown option: $1"; echo "Try: vasp-configure --help" >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------------------- #
# One-shot setters: `--debug-max-cores 240` changes that value and nothing else
# --------------------------------------------------------------------------- #
# Only when a profile already exists. With no profile there is nothing to keep,
# so the flags seed the wizard as before. --show/--edit/--verify keep their own
# meaning. Rewriting in place (rather than re-emitting the file) preserves the
# header, the comments and every key this version does not know about.
_conf_set_key(){   # _conf_set_key FILE KEY VALUE
    local f="$1" k="$2" v="$3" line found=0 tmp
    tmp="$(mktemp)" || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ ^[[:space:]]*${k}= ]]; then
            printf '%s="%s"\n' "$k" "$v" >> "$tmp"; found=1
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$f"
    (( found )) || printf '%s="%s"\n' "$k" "$v" >> "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
}

if (( ${#CLI_KEYS[@]} > 0 )) && [[ -f "$CONF" ]] \
   && (( SHOW_ONLY == 0 && EDIT_ONLY == 0 && VERIFY_ONLY == 0 )); then
    info "Updating $CONF"
    for _k in "${CLI_KEYS[@]}"; do
        _conf_set_key "$CONF" "$_k" "${!_k}" \
            && echo "    ${_k}=\"${!_k}\"" \
            || { warn "could not update ${_k}"; exit 1; }
    done
    info "Done. Everything else in the profile is unchanged."
    exit 0
fi

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
ask() {  # ask VARNAME "prompt" "default" ["what it is and what reads it"]
    # The fourth argument is the point of this function beyond reading a line.
    # These questions decide how every job this toolkit writes is shaped, and a
    # bare "Max total cores per job [240]:" tells a first-time user nothing
    # about whether 240 is the machine's size or their allocation's limit --
    # two different numbers, and answering with the wrong one produces scripts
    # the scheduler rejects. So each question says what the value IS and which
    # command consumes it. Printed only when someone is there to read it.
    local __var="$1" __prompt="$2" __def="${3:-}" __why="${4:-}" __ans=""
    if [[ $INTERACTIVE -eq 0 ]]; then printf -v "$__var" '%s' "$__def"; return; fi
    if [[ -n "$__why" ]]; then
        printf '%s\n' "$__why" | fold -s -w 66 | sed "s/^/      ${c_cya}/;s/\$/${c_rst}/"
    fi
    # Print the prompt ourselves instead of using `read -p`. Bash suppresses a
    # -p prompt whenever stdin is not a terminal, so anyone feeding the wizard
    # from a pipe or a here-doc saw the explanations above with no question
    # attached to them. The answer still comes from stdin either way.
    if [[ -n "$__def" ]]; then printf '    %s [%s]: ' "$__prompt" "$__def" >&2
    else                       printf '    %s: '      "$__prompt"          >&2; fi
    read -r __ans || true
    printf -v "$__var" '%s' "${__ans:-$__def}"
    [[ -n "$__why" ]] && echo
}

# Make module / ml callable in this (possibly non-login) shell if we can.
if ! type module >/dev/null 2>&1 && ! type ml >/dev/null 2>&1; then
    for f in /etc/profile.d/lmod.sh /etc/profile.d/modules.sh \
             "${LMOD_PKG:-}/init/bash" "${MODULESHOME:-}/init/bash"; do
        [[ -n "$f" && -f "$f" ]] && { source "$f" 2>/dev/null && break; }
    done
fi
have_modules() { type module >/dev/null 2>&1 || type ml >/dev/null 2>&1; }
run_module()   { if type module >/dev/null 2>&1; then module "$@"
                 elif type ml >/dev/null 2>&1; then ml "$@"; else return 127; fi; }

# Auto-pick the loader command and keep it valid (only ml / module).
[[ -z "$WP_MODULE_CMD" ]] && { type ml >/dev/null 2>&1 && WP_MODULE_CMD=ml || WP_MODULE_CMD=module; }
case "$WP_MODULE_CMD" in ml|module) ;; *) WP_MODULE_CMD=ml ;; esac

# Load a module list ($1) and report whether the executable ($2, default
# vasp_std) lands on PATH. Runs in a throwaway subshell; 0=ok 1=fail 2=can't test.
verify_modules() {
    local mods="$1" exe="${2:-vasp_std}"
    [[ -z "$mods" ]] && return 2
    have_modules || return 2
    ( run_module purge >/dev/null 2>&1 || true
      # shellcheck disable=SC2086  (word-split the module list on purpose)
      if [[ "$WP_MODULE_CMD" == module ]]; then module load $mods >/dev/null 2>&1 || true
      else ml $mods >/dev/null 2>&1 || true; fi
      command -v "$exe" >/dev/null 2>&1 )
}

# Echo the Lmod error lines from loading $1 (for diagnostics).
diagnose_modules() {
    local mods="$1" err
    # shellcheck disable=SC2086
    err=$( { run_module purge
             if [[ "$WP_MODULE_CMD" == module ]]; then module load $mods; else ml $mods; fi
           } 2>&1 1>/dev/null )
    printf '%s\n' "$err" | grep -iE 'error|cannot be loaded|unknown|not found|conflict' | head -6
}

# List VASP modules from 'module avail'/'spider' (names only). Drops Lmod
# family placeholders like "vasp/" / "VASP/" (a trailing slash, no version) --
# those are not loadable and only clutter the menu.
detect_vasp_modules() {
    { run_module -t avail 2>&1; run_module -t spider 2>&1; } 2>/dev/null \
      | grep -iE 'vasp' \
      | sed -E 's/[[:space:]]*$//; s/\(default\)//I; s/:$//' \
      | grep -vE '^/|^[[:space:]]*$|/$' \
      | awk '{$1=$1; print}' | sort -u
}

# ----- CUSTOM (build-it-yourself) VASP installs ----------------------------- #
# A locally compiled VASP is NOT a module: it is a binary on the filesystem that
# needs (a) a base module for runtime libs (MPI/compiler) and (b) either a
# self-contained wrapper or some extra LD_LIBRARY_PATH for non-RPATH'd libs.
# Builds may drop a sidecar "<exe>.wpmeta" (KEY=value) describing how to launch:
#   VASP_EXE=/path/to/vasp_std_w90     VASP_MODULES=compiler/x mpi/y vasp/z-runtime
#   VASP_LD_LIBRARY_PATH=/libA:/libB   VASP_FEATURES=wannier90,hdf5,openmp

_meta()    { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }  # _meta FILE KEY
_shorten() { case "$1" in "$HOME"/*) printf '~%s\n' "${1#"$HOME"}";; *) printf '%s\n' "$1";; esac; }

# Scan WP_VASP_BUILD_ROOTS (space/colon list) or a default set of common roots
# for local VASP builds, so they show up in the version menu beside the modules.
# Output: "<exe-to-invoke><TAB><menu label>". Builds advertised by a .wpmeta are
# listed first (with their feature tags); bare vasp_std / *_w90 are listed too.
detect_custom_vasp() {
    local roots r meta exe ver feats dd
    if [[ -n "${WP_VASP_BUILD_ROOTS:-}" ]]; then roots="${WP_VASP_BUILD_ROOTS//:/ }"
    else
        # $HOME is not the only place a build lives. On many clusters the home is
        # small and VASP is compiled in a project or scratch area, so those are
        # scanned too when they exist and belong to this user.
        # $HOME is only ONE of the places to look, and on many clusters it is the
        # wrong one. Santos Dumont gives a user $HOME=/prj/<proj>/<user> while
        # the work area is /scratch/<proj>/<user> -- a DIFFERENT directory with
        # the same basename. Scanning $HOME there finds nothing while the build
        # sits in plain sight next to where the user is standing. So the bases
        # are: $HOME, the directory vasp-configure was invoked from and its
        # parent (people run it from their work tree), and the usual
        # project/scratch layouts INCLUDING the <area>/<project>/<user> form.
        local bases base extra
        bases="$HOME $PWD $(dirname "$PWD")"
        for base in /scratch /scratch[0-9]* /prj /work /lustre /gpfs /home /store /data; do
            [[ -d "$base" ]] || continue
            for extra in "$base/$USER" "$base"/*/"$USER"; do
                [[ -d "$extra" ]] && bases="$bases $extra"
            done
        done
        roots=""
        for base in $bases; do
            [[ -d "$base" ]] || continue
            # the conventional names directly under a base ...
            for extra in Vasp vasp VASP .local opt builds src sw software apps; do
                [[ -d "$base/$extra" ]] && roots="$roots $base/$extra"
            done
            # ... plus anything under it whose name mentions vasp
            for extra in "$base"/*[Vv][Aa][Ss][Pp]*; do
                [[ -d "$extra" ]] && roots="$roots $extra"
            done
        done
        # de-duplicate: the same directory can be reached by several bases
        roots="$(printf '%s\n' $roots | sort -u | tr '\n' ' ')"
    fi
    local -A seen=()
    for r in $roots; do                                  # (1) .wpmeta-described builds
        [[ -d "$r" ]] || continue
        while IFS= read -r meta; do
            exe="$(_meta "$meta" VASP_EXE)"; [[ -z "$exe" ]] && exe="${meta%.wpmeta}"
            [[ -e "$exe" && -z "${seen[$exe]:-}" ]] || continue
            seen[$exe]=1
            feats="$(_meta "$meta" VASP_FEATURES)"
            ver="$(printf '%s' "$exe" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
            printf '%s\t[custom] vasp %s%s -> %s\n' "$exe" "${ver:-?}" \
                   "${feats:+  ($feats)}" "$(_shorten "$exe")"
        done < <(find -L "$r" -maxdepth 8 -name '*.wpmeta' 2>/dev/null)
    done
    for r in $roots; do                                  # (2) bare binaries / wrappers
        [[ -d "$r" ]] || continue
        while IFS= read -r exe; do
            [[ -z "${seen[$exe]:-}" ]] || continue
            dd="$(dirname "$exe")"
            [[ -f "${exe}.wpmeta" || -f "${dd}/vasp_std.wpmeta" ]] && continue
            # prefer a wrapper: skip raw vasp_std if a *_w90 sits in the same dir
            [[ "$(basename "$exe")" == vasp_std ]] && compgen -G "${dd}/vasp_*_w90" >/dev/null 2>&1 && continue
            seen[$exe]=1
            ver="$(printf '%s' "$exe" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
            printf '%s\t[custom] vasp %s -> %s\n' "$exe" "${ver:-?}" "$(_shorten "$exe")"
        # A real VASP binary has NO extension: vasp_std, vasp_gam, vasp_ncl,
        # vasp_std_w90. Everything with a dot in the name is something else --
        # widening the filter to vasp_* started offering tools/vasp_potcarh5.py
        # as a VASP build, and picking it would leave every job unable to start.
        # Rejecting any basename containing a dot covers .py .sh .o .a .so.1
        # .f90 .mod .wpmeta in one rule, with no list to keep up to date.
        done < <(find -L "$r" -maxdepth 8 \( -type f -o -type l \) -perm -u+x \
                      -name 'vasp_*' ! -name '*.*' 2>/dev/null)
    done
}

# Configure a chosen custom build: read its .wpmeta if present (VASP_EXE,
# VASP_MODULES, VASP_LD_LIBRARY_PATH, VASP_FEATURES), else ask for the base
# module(s) and any extra LD_LIBRARY_PATH. Sets WP_VASP_STD / WP_VASP_MODULES /
# WP_VASP_LD_LIBRARY_PATH.
configure_custom() {
    local exe="$1" meta="" v_exe="" v_mods="" v_ld="" v_feats="" d m
    d="$(dirname "$exe")"
    for m in "${exe}.wpmeta" "${d}/$(basename "$exe").wpmeta" "${d}/vasp_std.wpmeta"; do
        [[ -f "$m" ]] && { meta="$m"; break; }
    done
    if [[ -n "$meta" ]]; then
        v_exe="$(_meta "$meta" VASP_EXE)"
        v_mods="$(_meta "$meta" VASP_MODULES)"
        v_ld="$(_meta "$meta" VASP_LD_LIBRARY_PATH)"
        v_feats="$(_meta "$meta" VASP_FEATURES)"
        note "read $(_shorten "$meta")${v_feats:+   (features: $v_feats)}"
    fi
    WP_VASP_STD="${v_exe:-$exe}"
    # A build directory holds vasp_std, vasp_gam and vasp_ncl side by side, but
    # only the chosen one was recorded -- GAM and NCL kept the bare default name.
    # Those are not on PATH for a self-compiled build, so the first gamma-only or
    # spin-orbit job dies with "execve(): vasp_gam: No such file or directory",
    # long after this wizard ran and with nothing pointing back to here. Adopt the
    # siblings that actually sit next to the binary the user picked.
    local _sib _dir _base
    _dir="$(dirname "$WP_VASP_STD")"; _base="$(basename "$WP_VASP_STD")"
    for _sib in gam ncl; do
        local _cand="${_dir}/${_base/_std/_${_sib}}"
        [[ "$_base" == *_std* && -x "$_cand" ]] || continue
        case "$_sib" in
            gam) WP_VASP_GAM="$_cand"; note "  sibling found   : $_cand" ;;
            ncl) WP_VASP_NCL="$_cand"; note "  sibling found   : $_cand" ;;
        esac
    done
    if [[ -n "$v_mods" ]]; then
        WP_VASP_MODULES="$v_mods"
    else
        note "A local build needs a base module for its runtime libs (MPI + compiler)."
        ask WP_VASP_MODULES "Base module(s) to load (blank if none)" ""
    fi
    if [[ -n "$v_ld" ]]; then
        WP_VASP_LD_LIBRARY_PATH="$v_ld"
    elif [[ -z "$meta" ]]; then
        note "If the binary is NOT RPATH'd and has no wrapper, list extra lib dirs"
        note "for LD_LIBRARY_PATH (colon-separated). Blank if it uses a wrapper."
        ask WP_VASP_LD_LIBRARY_PATH "Extra LD_LIBRARY_PATH (blank if none)" ""
    fi
    note "custom VASP exe : $WP_VASP_STD"
    note "  base modules  : ${WP_VASP_MODULES:-(none)}"
    [[ -n "$WP_VASP_LD_LIBRARY_PATH" ]] && note "  extra LD path : $WP_VASP_LD_LIBRARY_PATH"
}

# Verify a custom build: load the base modules + extra LD path, resolve the real
# ELF (follow a wrapper's 'exec ... vasp...'), and check every shared library
# resolves. 0=ok  1=missing libs  2=cannot test.
verify_custom_libs() {
    local exe="$1" real="$1"
    [[ -e "$exe" ]] || return 2
    if head -c2 "$exe" 2>/dev/null | grep -q '#!'; then          # a wrapper script
        real="$(grep -oE 'exec[[:space:]]+\S*vasp[^[:space:]]*' "$exe" 2>/dev/null | awk '{print $2}' | head -1)"
        [[ -n "$real" && -e "$real" ]] || real="$exe"
    fi
    command -v ldd >/dev/null 2>&1 || return 2
    ( run_module purge >/dev/null 2>&1 || true
      if [[ -n "$WP_VASP_MODULES" ]]; then
          # shellcheck disable=SC2086
          if [[ "$WP_MODULE_CMD" == module ]]; then module load $WP_VASP_MODULES >/dev/null 2>&1 || true
          else ml $WP_VASP_MODULES >/dev/null 2>&1 || true; fi
      fi
      [[ -n "$WP_VASP_LD_LIBRARY_PATH" ]] && export LD_LIBRARY_PATH="$WP_VASP_LD_LIBRARY_PATH:${LD_LIBRARY_PATH:-}"
      ! ldd "$real" 2>/dev/null | grep -qi 'not found' )
}

# --------------------------------------------------------------------------- #
# SLURM INTROSPECTION
# --------------------------------------------------------------------------- #
# Everything here asks SLURM instead of guessing. Three rules:
#
#   1. NOTHING is invented. A detector that cannot determine a value prints
#      nothing, and the wizard asks the user. A wrong guess about a cluster does
#      not fail fast -- SLURM accepts the job and the sizing is silently wrong --
#      so "no answer" is strictly better than "a plausible answer".
#
#   2. The MOST RESTRICTIVE limit wins. A job must satisfy the partition AND the
#      QOS AND the user's association simultaneously; any one of them can reject
#      it. Detecting only one (the old code read the association and ignored the
#      QOS entirely) means the cap looks larger than it is.
#
#   3. Every detected number carries its PROVENANCE, so the summary can say
#      which SLURM object imposed it and the user can check it.
#
# _WP_WHY collects "<value> <- <source>" notes for the last detector that ran.
# Provenance is written to a FILE, not a shell variable: detectors are called as
# $(detect_x), which runs them in a SUBSHELL, and a variable set there never
# reaches the caller. The file survives.
_WP_WHY_FILE="${TMPDIR:-/tmp}/.wolfpack-detect.$$"
_have(){ command -v "$1" >/dev/null 2>&1; }
_why_reset(){ : > "$_WP_WHY_FILE"; }
_why_add(){ printf '    %s\n' "$1" >> "$_WP_WHY_FILE"; }
wp_why(){ [[ -s "$_WP_WHY_FILE" ]] && cat "$_WP_WHY_FILE"; }
trap 'rm -f "$_WP_WHY_FILE"' EXIT

# --- time: SLURM accepts several spellings; normalise all to MINUTES -------- #
# "infinite"/"UNLIMITED"/"n/a" -> empty (no cap). Formats per sbatch(1):
#   minutes | minutes:seconds | hours:minutes:seconds
#   days-hours | days-hours:minutes | days-hours:minutes:seconds
_slurm_time_to_min(){
    local t="${1//[[:space:]]/}" d=0 rest
    [[ -z $t ]] && return 0
    case "${t,,}" in infinite|unlimited|n/a|none|-) return 0 ;; esac
    if [[ $t == *-* ]]; then d="${t%%-*}"; rest="${t#*-}"; else rest="$t"; fi
    [[ $d =~ ^[0-9]+$ ]] || d=0
    awk -v d="$d" -v r="$rest" 'BEGIN{
        n = split(r, a, ":")
        if (n == 3)      m = a[1]*60 + a[2] + (a[3] > 0 ? 1 : 0)   # HH:MM:SS
        else if (n == 2) m = a[1] + (a[2] > 0 ? 1 : 0)             # MM:SS
        else if (n == 1) m = (r == "" ? 0 : a[1])                  # MM  (or D- only)
        else             m = 0
        total = d*1440 + m
        if (total > 0) printf "%d", total }'
}

# --- TRES strings: "cpu=120,mem=500G,node=4" -> one field, memory in MB ----- #
_tres_field(){
    awk -v s="$1" -v k="$2" 'BEGIN{
        n = split(s, parts, ",")
        for (i = 1; i <= n; i++) {
            if (split(parts[i], kv, "=") != 2) continue
            if (tolower(kv[1]) != tolower(k)) continue
            v = kv[2]
            if (tolower(k) == "mem") {
                u = toupper(substr(v, length(v), 1))
                num = v + 0
                if      (u == "T") num *= 1024*1024
                else if (u == "G") num *= 1024
                else if (u == "K") num /= 1024
                printf "%d", num
            } else printf "%d", v + 0
            exit } }'
}

# --- scontrol show partition: one key ("MaxTime", "MaxNodes", ...) ---------- #
# scontrol prints space-separated Key=Value pairs across several lines.
_part_kv(){
    _have scontrol || return 0
    scontrol show partition "$1" 2>/dev/null \
      | tr ' ' '\n' | awk -F= -v k="$2" '$1==k && NF>=2 {print $2; exit}'
}

# --- a partition's node hardware, read from the NODES themselves ------------ #
# sinfo prints ONE LINE PER NODE-GROUP, so a heterogeneous partition yields
# several. Sizing to the LARGEST produces jobs that will not fit the smallest,
# and SLURM will simply never schedule them there -- so the safe common
# denominator is the MINIMUM, and a spread is reported rather than hidden.
_node_field(){   # _node_field <partition> <sinfo-format> -> "min max count"
    _have sinfo || return 0
    sinfo -h -p "$1" -o "$2" 2>/dev/null | grep -oE '[0-9]+' | sort -n \
      | awk 'NR==1{min=$1} {max=$1; n++} END{ if(n) printf "%d %d %d", min, max, n }'
}

# --- the QOS that apply to this user on this partition ---------------------- #
# The QOS that actually bind on THIS partition.
#
# A partition that declares QoS=<name> enforces that one, and it is the only one
# that applies there. The user's association also lists every QOS they MAY use
# elsewhere -- folding those in made 'main' inherit the debug queue's 20-minute
# wall and 96-core cap, because the most-restrictive rule then reached across
# partitions that have nothing to do with each other. So: the partition's own
# QoS wins outright, and the association list is consulted ONLY when the
# partition declares none.
_qos_names(){
    local part="$1" out
    out="$(_part_kv "$part" QoS)"
    case "${out,,}" in n/a|none|"") out="" ;; esac
    if [[ -z $out ]] && _have sacctmgr; then
        out="$(sacctmgr -nP show assoc user="$USER" format=QOS 2>/dev/null \
               | tr ',' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
    fi
    printf '%s\n' $out | sed '/^$/d' | sort -u
}
_qos_kv(){   # _qos_kv <qos> <format-field>
    _have sacctmgr || return 0
    sacctmgr -nP show qos "$1" format="$2" 2>/dev/null | head -1
}

# --- the user's association limits ----------------------------------------- #
_assoc_kv(){ _have sacctmgr || return 0
    sacctmgr -nP show assoc user="$USER" format="$1" 2>/dev/null | sed '/^$/d' | head -1; }

# --------------------------------------------------------------------------- #
# DETECTORS  (each prints ONE number, or nothing; _WP_WHY holds the provenance)
# --------------------------------------------------------------------------- #

# WALLTIME cap for a partition, in minutes. THE limit that was never detected:
# vasp-dry-run/vasp-test hardcoded 30 min, so a site capping debug at 20 had its
# jobs rejected with nothing in the toolkit able to notice.
detect_time_cap_min(){
    local part="$1" best="" v q
    _why_reset
    v="$(_slurm_time_to_min "$(_part_kv "$part" MaxTime)")"
    [[ -n $v ]] && { _why_add "${v} min <- partition '$part' MaxTime"; best="$v"; }
    v="$(_slurm_time_to_min "$(_assoc_kv MaxWall)")"
    [[ -n $v ]] && { _why_add "${v} min <- your association MaxWall"
                     [[ -z $best || $v -lt $best ]] && best="$v"; }
    while read -r q; do
        [[ -z $q ]] && continue
        v="$(_slurm_time_to_min "$(_qos_kv "$q" MaxWall)")"
        [[ -n $v ]] && { _why_add "${v} min <- QOS '$q' MaxWall"
                         [[ -z $best || $v -lt $best ]] && best="$v"; }
    done < <(_qos_names "$part")
    [[ -n $best ]] && printf '%d' "$best"
}

# Total CPUs one job may request. Partition size, association and QOS all bind.
detect_core_cap(){
    local part="$1" best="" v t q nodes cpn
    # Resolve cores/node FIRST: that detector clears the provenance log for its
    # own use, so calling it later would erase the notes collected here.
    cpn="$(detect_cpus_per_node "$part")"
    _why_reset
    for t in "$(_assoc_kv GrpTRES)" "$(_assoc_kv MaxTRES)"; do
        v="$(_tres_field "$t" cpu)"
        [[ -n $v && $v -gt 0 ]] && { _why_add "${v} cpu <- your association TRES"
                                     [[ -z $best || $v -lt $best ]] && best="$v"; }
    done
    while read -r q; do
        [[ -z $q ]] && continue
        for t in "$(_qos_kv "$q" MaxTRESPU)" "$(_qos_kv "$q" MaxTRES)" "$(_qos_kv "$q" GrpTRES)"; do
            v="$(_tres_field "$t" cpu)"
            [[ -n $v && $v -gt 0 ]] && { _why_add "${v} cpu <- QOS '$q'"
                                         [[ -z $best || $v -lt $best ]] && best="$v"; }
        done
    done < <(_qos_names "$part")
    # A partition's own ceiling: MaxNodes x cores-per-node, else its total CPUs.
    nodes="$(_part_kv "$part" MaxNodes)"
    if [[ $nodes =~ ^[0-9]+$ && $cpn =~ ^[0-9]+$ ]]; then
        v=$(( nodes * cpn ))
        _why_add "${v} cpu <- partition MaxNodes(${nodes}) x ${cpn} cores/node"
        [[ -z $best || $v -lt $best ]] && best="$v"
    else
        v="$(_part_kv "$part" TotalCPUs)"
        [[ $v =~ ^[0-9]+$ ]] && { _why_add "${v} cpu <- partition TotalCPUs"
                                  [[ -z $best || $v -lt $best ]] && best="$v"; }
    fi
    [[ -n $best ]] && printf '%d' "$best"
}

# Cores per node. MINIMUM over the partition's nodes -- see _node_field.
detect_cpus_per_node(){
    _why_reset
    local part="$1" r; r="$(_node_field "$part" "%c")" || return 0
    [[ -z $r ]] && return 0
    set -- $r
    _why_add "$1 cores/node <- sinfo -p '$part' (min over nodes)"
    (( $2 != $1 )) && _why_add "heterogeneous: nodes range $1..$2 cores; using the MINIMUM so a job fits any of them"
    printf '%d' "$1"
}

# RAM per node (MB), likewise the minimum, and clamped by MaxMemPerNode.
detect_mem_per_node(){
    _why_reset
    local part="$1" r v; r="$(_node_field "$part" "%m")" || return 0
    [[ -z $r ]] && return 0
    set -- $r
    local best="$1"
    _why_add "${best} MB/node <- sinfo -p '$part' RealMemory (min over nodes)"
    (( $2 != best )) && _why_add "heterogeneous: nodes range $1..$2 MB; using the MINIMUM"
    v="$(_part_kv "$part" MaxMemPerNode)"
    if [[ $v =~ ^[0-9]+$ ]] && (( v > 0 && v < best )); then
        _why_add "${v} MB <- partition MaxMemPerNode (lower than the hardware)"; best="$v"
    fi
    printf '%d' "$best"
}

# Cores per NUMA domain: KPAR groups should not straddle one. Read from a real
# node in the partition rather than from this login node, whose topology differs.
detect_numa_cores(){
    _why_reset
    local part="$1" node cps
    _have sinfo && _have scontrol || return 0
    node="$(sinfo -h -p "$part" -o "%N" 2>/dev/null | head -1)"
    [[ -z $node ]] && return 0
    node="$(scontrol show hostnames "$node" 2>/dev/null | head -1)"
    [[ -z $node ]] && return 0
    cps="$(scontrol show node "$node" 2>/dev/null | tr ' ' '\n' \
           | awk -F= '$1=="CoresPerSocket" && NF>=2 {print $2; exit}')"
    [[ $cps =~ ^[0-9]+$ ]] && (( cps > 0 )) || return 0
    _why_add "${cps} cores/socket <- scontrol show node ${node}"
    printf '%d' "$cps"
}

# Max nodes per job, if the partition or a QOS says so.
detect_node_cap(){
    local part="$1" best="" v q
    _why_reset
    v="$(_part_kv "$part" MaxNodes)"
    [[ $v =~ ^[0-9]+$ ]] && { _why_add "${v} nodes <- partition MaxNodes"; best="$v"; }
    while read -r q; do
        [[ -z $q ]] && continue
        v="$(_tres_field "$(_qos_kv "$q" MaxTRESPU)" node)"
        [[ -n $v && $v -gt 0 ]] && { _why_add "${v} nodes <- QOS '$q'"
                                     [[ -z $best || $v -lt $best ]] && best="$v"; }
    done < <(_qos_names "$part")
    [[ -n $best ]] && printf '%d' "$best"
}

sinfo_partitions() { _have sinfo && sinfo -h -o "%P" 2>/dev/null; }
default_partition() { sinfo_partitions | tr ' ' '\n' | grep '\*' | tr -d '* ' | head -1; }
guess_debug_part()  { sinfo_partitions | tr ' *' '\n\n' | grep -iE 'debug|devel|test|short' | head -1; }
# Back-compat names used by the wizard body below.
cpus_of(){ detect_cpus_per_node "$1"; }
mem_of(){  detect_mem_per_node  "$1"; }
detect_max_cores(){ detect_core_cap "${1:-$WP_MAIN_PARTITION}"; }

# --------------------------------------------------------------------------- #
# --show : print the current profile and exit
# --------------------------------------------------------------------------- #
if [[ $SHOW_ONLY -eq 1 ]]; then
    if [[ -f "$CONF" ]]; then info "Cluster profile: $CONF"; cat "$CONF"
    else warn "No profile at $CONF. Run 'vasp-configure' to create one."; exit 1; fi
    exit 0
fi

# --------------------------------------------------------------------------- #
# --edit : open the profile in $EDITOR (create defaults first if missing)
# --------------------------------------------------------------------------- #
if [[ $EDIT_ONLY -eq 1 ]]; then
    if [[ ! -f "$CONF" ]]; then
        info "No profile yet — generating defaults to edit ($CONF)"
        "$0" --non-interactive --conf "$CONF" >/dev/null 2>&1 || true
    fi
    editor="${VISUAL:-${EDITOR:-}}"
    [[ -z "$editor" ]] && editor="$(command -v nano || command -v vim || command -v vi || echo vi)"
    info "Opening $CONF in '$editor' (edit, e.g., WP_VASP_MODULES) ..."
    "$editor" "$CONF"
    [[ -f "$CONF" ]] && { info "Saved. Current profile:"; cat "$CONF"; }
    exit 0
fi

# --------------------------------------------------------------------------- #
# --verify : load the configured modules and check the VASP executable appears.
# (The quickest way to diagnose an "execve(): vasp_std: No such file" failure.)
# --------------------------------------------------------------------------- #
if [[ $VERIFY_ONLY -eq 1 ]]; then
    [[ -f "$CONF" ]] && source "$CONF" \
        || { warn "no profile at $CONF — run 'vasp-configure' first."; exit 1; }
    case "$WP_MODULE_CMD" in ml|module) ;; *) WP_MODULE_CMD=ml ;; esac
    exe="${WP_VASP_STD:-vasp_std}"
    if [[ "$exe" == */* ]]; then                      # custom build: verify shared libs
        info "Verifying CUSTOM VASP build from $CONF"
        echo "    exe          : $exe"
        echo "    base modules : ${WP_VASP_MODULES:-(none)}  [$WP_MODULE_CMD]"
        [[ -n "${WP_VASP_LD_LIBRARY_PATH:-}" ]] && echo "    extra LD path: $WP_VASP_LD_LIBRARY_PATH"
        verify_custom_libs "$exe"; rc=$?
        case "$rc" in
            0) info "${c_grn}OK${c_rst}: every shared library of '$exe' resolves."; exit 0 ;;
            2) warn "could not test here (need ldd + the module system on a login node)."; exit 2 ;;
            *) warn "FAILED: some shared libraries are 'not found' for '$exe'."
               warn "Add the missing lib dirs:  vasp-configure --vasp-ld-path \"/dirA:/dirB\""
               warn "or point WP_VASP_STD at a wrapper that sets LD_LIBRARY_PATH itself."
               exit 1 ;;
        esac
    fi
    info "Verifying VASP modules from $CONF"
    echo "    modules : ${WP_VASP_MODULES:-(none)}  [$WP_MODULE_CMD]"
    echo "    exe     : $exe"
    [[ -z "${WP_VASP_MODULES:-}" ]] && { warn "no modules configured (WP_VASP_MODULES empty)."; exit 1; }
    have_modules || { warn "no module system here — run --verify on a cluster login node."; exit 2; }
    if verify_modules "$WP_VASP_MODULES" "$exe"; then
        info "${c_grn}OK${c_rst}: '$exe' is available after loading your modules."
        exit 0
    fi
    warn "FAILED: after loading your modules, '$exe' is NOT on PATH."
    warn "Jobs will die with 'execve(): $exe: No such file or directory'."
    echo "    Lmod said:"; diagnose_modules "$WP_VASP_MODULES" | sed 's/^/      /'
    echo
    echo "    Fix: vasp-configure   (set the module line, add the compiler/MPI)"
    echo "         vasp-configure --edit   (edit WP_VASP_MODULES by hand)"
    exit 1
fi

# --------------------------------------------------------------------------- #
# Wizard
# --------------------------------------------------------------------------- #
info "WolfPack-DFT cluster configuration"
echo "    profile file : $CONF"
[[ $INTERACTIVE -eq 0 ]] && echo "    mode         : non-interactive (detect + defaults)"
echo

# ---- 1. email ----
info "Notification email (used as #SBATCH --mail-user in emitted scripts)"
: "${WP_EMAIL:=$(git config --get user.email 2>/dev/null || echo "${EMAIL:-}")}"
ask WP_EMAIL "Email (blank = no mail line)" "$WP_EMAIL" \
    "Where SLURM mails job start/end. Blank leaves the --mail-user line out of every generated script."
echo

# ---- 2. VASP version (module OR local build) ----
# Pick a VASP module, OR a locally compiled build found on the filesystem (both
# appear in one numbered menu). If a module needs a compiler/MPI loaded first you
# give it SEPARATELY and it is prepended. A custom build instead needs a base
# module for runtime libs + (a wrapper or an extra LD path), captured here.
info "VASP version to use"
if [[ -z "$WP_VASP_MODULES" && $INTERACTIVE -eq 1 ]]; then
    have_modules && note "module command: $WP_MODULE_CMD"
    mapfile -t VASP_CANDS   < <(have_modules && detect_vasp_modules)
    mapfile -t CUSTOM_CANDS < <(detect_custom_vasp)
    n_mod=${#VASP_CANDS[@]}; n_cus=${#CUSTOM_CANDS[@]}
    if (( n_mod + n_cus > 0 )); then
        echo "    Detected VASP versions on this system:"
        i=1
        for c in "${VASP_CANDS[@]}";   do printf "      %2d) %s\n" "$i" "$c"; i=$((i+1)); done
        for c in "${CUSTOM_CANDS[@]}"; do printf "      %2d) %s\n" "$i" "${c#*$'\t'}"; i=$((i+1)); done
        echo "       m) type the whole module line manually"
        echo "       s) skip (no module)"
        read -r -p "    Choose [1]: " pick || true; pick="${pick:-1}"
        if [[ "$pick" =~ ^[Ss]$ ]]; then
            WP_VASP_MODULES=""
        elif [[ "$pick" =~ ^[Mm]$ ]]; then
            ask WP_VASP_MODULES "Whole module line to load (space-separated)" ""
        elif [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>=1 && pick<=n_mod )); then
            chosen="${VASP_CANDS[pick-1]}"
            note "Many clusters require a compiler/MPI loaded BEFORE the VASP module"
            note "(e.g. aocc/4.2.0, gcc/13, intel/2024). Enter it (loaded first), or blank."
            ask PREREQ "Module(s) to load before $chosen (blank if none)" ""
            WP_VASP_MODULES="${PREREQ:+$PREREQ }$chosen"
            note "module line -> $WP_VASP_MODULES"
        elif [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>n_mod && pick<=n_mod+n_cus )); then
            entry="${CUSTOM_CANDS[pick-n_mod-1]}"
            configure_custom "${entry%%$'\t'*}"
        else
            warn "invalid choice; type the module line below."
            ask WP_VASP_MODULES "Whole module line to load (space-separated)" ""
        fi
    else
        warn "no VASP module or local build detected -- type the module line below"
        warn "(or set WP_VASP_BUILD_ROOTS to your build dir and re-run to auto-find it)."
        ask WP_VASP_MODULES "Whole module line to load for VASP (space-separated)" ""
    fi
fi
ask WP_VASP_STD "VASP std executable" "$WP_VASP_STD" \
    "The binary every generated job runs. A bare name is looked up on PATH after the modules load; an absolute path skips PATH entirely, which is what a custom build needs."

# Informational check -- never blocks, never loops.
if [[ "$WP_VASP_STD" == */* ]]; then                 # custom build: check its libs
    if verify_custom_libs "$WP_VASP_STD"; then
        note "checked: every shared library of '$WP_VASP_STD' resolves."
    else
        case $? in
            2) note "skipped lib check (no ldd / module system on this host)." ;;
            *) warn "some shared libraries are 'not found' for '$WP_VASP_STD' --"
               warn "add their dirs with --vasp-ld-path, or point at a wrapper. (--verify to retest)" ;;
        esac
    fi
elif [[ -n "$WP_VASP_MODULES" ]] && have_modules; then
    if verify_modules "$WP_VASP_MODULES" "$WP_VASP_STD"; then
        note "checked: '$WP_VASP_STD' is on PATH after loading these modules."
    else
        warn "could NOT confirm '$WP_VASP_STD' loads from these modules:"
        diagnose_modules "$WP_VASP_MODULES" | sed 's/^/      Lmod: /'
        warn "likely a missing compiler/MPI prerequisite. Re-run 'vasp-configure'"
        warn "and enter it, or test/fix with: vasp-configure --verify / --edit"
    fi
fi
echo

# ---- 3. partitions ----
info "SLURM partitions"
if [[ $INTERACTIVE -eq 1 ]] && command -v sinfo >/dev/null 2>&1; then
    parts="$(sinfo_partitions | tr '\n' ' ')"
    [[ -n "$parts" ]] && note "partitions on this cluster: $parts"
fi
: "${WP_MAIN_PARTITION:=$(default_partition)}"; : "${WP_MAIN_PARTITION:=main}"
: "${WP_DEBUG_PARTITION:=$(guess_debug_part)}"; : "${WP_DEBUG_PARTITION:=$WP_MAIN_PARTITION}"
ask WP_MAIN_PARTITION  "MAIN (production) partition name"   "$WP_MAIN_PARTITION" \
    "Where production jobs are submitted. vasp-recommend-slurm sizes every layout against this partition's nodes."
ask WP_DEBUG_PARTITION "DEBUG (short/test) partition name"  "$WP_DEBUG_PARTITION" \
    "Where the vasp-test benchmark runs: a short queue with quick turnaround. Name the MAIN partition here if your site has no separate debug queue -- the test is still sized by the DEBUG limits below."
echo

# ---- 4. per-partition node specs ----
info "Node resources (cores / memory per node)"
# No invented numbers. A detector that cannot answer leaves the value empty and
# `ask` prompts with a blank default, so the user supplies the fact rather than
# inheriting someone else's hardware.
_probe(){ local __v="$1" __part="$2" __fn="$3"
    [[ -n "${!__v}" ]] && return 0
    local got; got="$($__fn "$__part")"
    [[ -n $got ]] && { printf -v "$__v" '%s' "$got"; note "  ${__v}=${got}"; wp_why; }
}
_probe WP_MAIN_CPUS_PER_NODE    "$WP_MAIN_PARTITION"  detect_cpus_per_node
_probe WP_MAIN_MEM_PER_NODE_MB  "$WP_MAIN_PARTITION"  detect_mem_per_node
_probe WP_DEBUG_CPUS_PER_NODE   "$WP_DEBUG_PARTITION" detect_cpus_per_node
_probe WP_DEBUG_MEM_PER_NODE_MB "$WP_DEBUG_PARTITION" detect_mem_per_node
_probe WP_MAIN_NUMA_CORES       "$WP_MAIN_PARTITION"  detect_numa_cores
ask WP_MAIN_CPUS_PER_NODE    "MAIN  cores per node"        "$WP_MAIN_CPUS_PER_NODE" \
    "Cores on one MAIN node. The rank counts vasp-recommend-slurm offers are multiples of this, because VASP expects ranks to fill one node before the next is used."
ask WP_MAIN_MEM_PER_NODE_MB  "MAIN  memory per node (MB)"  "$WP_MAIN_MEM_PER_NODE_MB" \
    "RAM on one MAIN node. Decides how many ranks fit per node once vasp-test has measured the real per-rank memory."
ask WP_DEBUG_CPUS_PER_NODE   "DEBUG cores per node"        "$WP_DEBUG_CPUS_PER_NODE" \
    "Cores on one DEBUG node -- the size of the machine the benchmark actually runs on."
ask WP_DEBUG_MEM_PER_NODE_MB "DEBUG memory per node (MB)"  "$WP_DEBUG_MEM_PER_NODE_MB" \
    "RAM on one DEBUG node. The benchmark asks for as much of it as the margin below allows, because its job is to find the memory ceiling."
echo

# ---- 5. max cores ----
info "Maximum cores you may request (account / QOS cap)"
detected_max="$(detect_core_cap "$WP_MAIN_PARTITION")"
if [[ -n "$detected_max" ]]; then note "  detected cap: ${detected_max} cores"; wp_why
else note "  no cap found in SLURM -- please supply one."; fi
: "${WP_MAX_CORES:=$detected_max}"
ask WP_MAX_CORES "Max total cores per job" "$WP_MAX_CORES" \
    "The most cores ONE production job may hold. This is your allocation's limit, not the machine's size. vasp-recommend-slurm REFUSES to recommend a layout above it rather than write a script the scheduler would reject."
echo

# ---- 5b. DEBUG/test job cap ----
# The test benchmark runs on the DEBUG configuration.  When the DEBUG partition IS
# the MAIN one (a cluster with no separate debug queue), this cap is what still keeps
# the test job small -- vasp-test always honours the DEBUG numbers, whatever partition
# they name.
info "DEBUG/test job limits (used by vasp-test even if DEBUG == MAIN partition)"
if [[ "$WP_DEBUG_PARTITION" == "$WP_MAIN_PARTITION" ]]; then
    note "DEBUG partition == MAIN ('$WP_MAIN_PARTITION'): tests will run there, but"
    note "vasp-test will still obey the DEBUG core cap and DEBUG memory margin below."
fi
# This is NOT "the largest job SLURM would accept" -- it is "how big should the
# validation benchmark be". Those differ by orders of magnitude: a site may allow
# 2400 cores on its dev queue, but the benchmark only has to reproduce the chosen
# KPAR x NCORE long enough to measure memory and parallel efficiency, inside a
# short dev walltime. Sizing it to the site maximum would queue a 2400-rank job
# for a 15-minute measurement. So the SLURM limit is an upper bound, and the
# benchmark is capped at two nodes, which is what the test actually needs.
_dbg_allowed="$(detect_core_cap "$WP_DEBUG_PARTITION")"
if [[ -n $_dbg_allowed ]]; then note "  SLURM would allow: ${_dbg_allowed} cores"; wp_why; fi
_dbg_bench=$(( ${WP_DEBUG_CPUS_PER_NODE:-0} * 2 ))
if [[ -n $_dbg_allowed ]] && (( _dbg_bench > _dbg_allowed )); then _dbg_bench=$_dbg_allowed; fi
if (( _dbg_bench > 0 )); then
    note "  benchmark size   : ${_dbg_bench} cores (2 x ${WP_DEBUG_CPUS_PER_NODE}/node)"
    note "                     the test only has to reproduce KPAR x NCORE, not fill the queue"
fi
: "${WP_DEBUG_MAX_CORES:=$_dbg_bench}"
ask WP_DEBUG_MAX_CORES "Max total cores for a DEBUG/test job" "$WP_DEBUG_MAX_CORES" \
    "The same cap for the vasp-test benchmark, so a test can never quietly grow into a production-sized job."
echo

# ---- 6b. pipeline policy (was hardcoded in the stage scripts) ----
info "Pipeline policy (walltime, memory utilisation, magic spike, memory margins)"
# THE limit that was never detected. vasp-dry-run/vasp-test hardcoded 30 minutes,
# so a site capping its debug queue at 20 had every probe rejected by SLURM with
# nothing in the toolkit able to see why. Read it from the partition, the QOS and
# the association, and take the smallest.
_wall="$(detect_time_cap_min "$WP_DEBUG_PARTITION")"
if [[ -n $_wall ]]; then
    note "  detected DEBUG walltime cap: ${_wall} min"; wp_why
    # Sit just under the cap: a job asking for exactly MaxTime is accepted, but
    # leaving a minute of slack avoids losing the in-job analysis step to a
    # kill at the boundary.
    (( _wall > 5 )) && _wall=$(( _wall - 1 ))
fi
: "${WP_TEST_WALLTIME_MIN:=$_wall}"
# Same defaults vasp-chain falls back to (DEF_WALLTIME_MIN / DEF_MARGIN_MIN).
: "${WP_CHUNK_WALLTIME_MIN:=600}"
: "${WP_CHUNK_MARGIN_MIN:=5}"
: "${WP_MEM_UTIL_MIN:=0.80}"
: "${WP_GW_NODE_FRAC:=0.67}"
# Memory margins are FRACTIONS of a node's RAM left free (0.02 => 98% usable).
# Migrate a legacy absolute WP_DEBUG_RESERVE_GB into the debug fraction.
if [[ -z "$WP_DEBUG_MEM_MARGIN" && -n "$WP_DEBUG_RESERVE_GB" && "$WP_DEBUG_MEM_PER_NODE_MB" -gt 0 ]]; then
    WP_DEBUG_MEM_MARGIN="$(awk -v g="$WP_DEBUG_RESERVE_GB" -v m="$WP_DEBUG_MEM_PER_NODE_MB" \
        'BEGIN{ f=(g*1024.0)/m; if(f<0)f=0; if(f>0.5)f=0.5; printf "%.3f", f }')"
    note "converted legacy debug reserve ${WP_DEBUG_RESERVE_GB} GB -> margin ${WP_DEBUG_MEM_MARGIN}"
fi
: "${WP_MAIN_MEM_MARGIN:=0.02}"
: "${WP_DEBUG_MEM_MARGIN:=0.05}"
ask WP_TEST_WALLTIME_MIN  "DEBUG/test walltime cap (min)" "$WP_TEST_WALLTIME_MIN" \
    "Walltime of the vasp-test benchmark job. VASP gets this minus about 90 s, which is what the in-job memory analysis needs to read sacct and write the report."
ask WP_CHUNK_WALLTIME_MIN "Chunk walltime (min)" "$WP_CHUNK_WALLTIME_MIN" \
    "Walltime of ONE chunk when a long relaxation or SCF is split by vasp-relax-loop / vasp-scf-loop. Shorter chunks backfill into the queue sooner; longer ones mean fewer queue waits and fewer restarts. Asking for N minutes is a ceiling, not a duration: a chunk ends as soon as its step budget is spent."
ask WP_CHUNK_MARGIN_MIN   "Chunk end margin (min)" "$WP_CHUNK_MARGIN_MIN" \
    "Time kept free at the end of each chunk so VASP can finish the ionic step it is on and write its WAVECAR before SLURM kills the job. Raised to 8% of the chunk walltime when that is larger."
ask WP_MEM_UTIL_MIN       "Minimum memory-utilisation policy (fraction)"                    "$WP_MEM_UTIL_MIN" \
    "Your site's rule for how much of the RAM a job requests it must actually use. Memory requests are sized so measured usage lands at or above this."
ask WP_MAIN_MEM_MARGIN    "MAIN  node memory margin (fraction left free)"           "$WP_MAIN_MEM_MARGIN" \
    "Fraction of a MAIN node's RAM left unrequested, for the operating system and the job's own overhead. 0.02 means 98% of the node is offered to VASP."
ask WP_DEBUG_MEM_MARGIN   "DEBUG node memory margin (fraction left free)"           "$WP_DEBUG_MEM_MARGIN" \
    "The same for DEBUG nodes, larger by default because the benchmark deliberately runs close to the ceiling."
ask WP_GW_NODE_FRAC       "GW SWEET node fraction (0 = need-based)" "$WP_GW_NODE_FRAC" \
    "GW and RPA only: grows a GW request up to this share of a node so it batches faster, leaving the rest for backfill. 0 sizes it strictly to what the run needs."
# Clamp the margins into a sane range so a typo cannot wipe out a node's memory.
for _mv in WP_MAIN_MEM_MARGIN WP_DEBUG_MEM_MARGIN; do
    printf -v "$_mv" '%s' "$(awk -v x="${!_mv}" 'BEGIN{ x=x+0; if(x<0)x=0; if(x>0.5)x=0.5; printf "%.3f", x }')"
done
# Tools aim 1% ABOVE the policy floor so a slightly-low real usage still clears it.
WP_MEM_UTIL="$(awk -v m="$WP_MEM_UTIL_MIN" 'BEGIN{t=m+0.01; if(t>0.95)t=0.95; printf "%.2f", t}')"
echo

# ---- 6. write the profile ----
# A non-RPATH'd custom build needs its extra lib dirs on LD_LIBRARY_PATH at run
# time. Fold that into WP_EXTRA_ENV (which every job script already emits AFTER
# the module load) so no other script needs to change; WP_EXTRA_ENV is written
# single-quoted below so the literal $LD_LIBRARY_PATH survives 'source'.
if [[ -n "$WP_VASP_LD_LIBRARY_PATH" ]]; then
    WP_EXTRA_ENV='export LD_LIBRARY_PATH='"$WP_VASP_LD_LIBRARY_PATH"':$LD_LIBRARY_PATH;'"$WP_EXTRA_ENV"
fi
mkdir -p "$(dirname "$CONF")"
# Read back any WP_* assignment the wizard does not manage, so the rewrite
# below can put it back verbatim (value kept exactly as written, quotes and all).
declare -A _PRESERVED_VAL=(); _PRESERVED_KEYS=""
if [[ -f "$CONF" ]]; then
    _managed=" WP_EMAIL WP_MODULE_CMD WP_MODULE_PURGE WP_VASP_MODULES WP_VASP_STD \
WP_VASP_GAM WP_VASP_NCL WP_VASP_LD_LIBRARY_PATH WP_EXTRA_ENV WP_MAIN_PARTITION \
WP_DEBUG_PARTITION WP_MAIN_CPUS_PER_NODE WP_DEBUG_CPUS_PER_NODE \
WP_MAIN_MEM_PER_NODE_MB WP_DEBUG_MEM_PER_NODE_MB WP_MAIN_NUMA_CORES WP_MAX_CORES \
WP_TEST_WALLTIME_MIN WP_CHUNK_WALLTIME_MIN WP_CHUNK_MARGIN_MIN WP_MEM_UTIL_MIN \
WP_MEM_UTIL WP_GW_NODE_FRAC WP_DEBUG_MAX_CORES \
WP_MAIN_MEM_MARGIN WP_DEBUG_MEM_MARGIN "
    while IFS= read -r _line; do
        [[ "$_line" =~ ^[[:space:]]*(WP_[A-Za-z0-9_]+)=(.*)$ ]] || continue
        _k="${BASH_REMATCH[1]}"; _v="${BASH_REMATCH[2]}"
        [[ "$_managed" == *" $_k "* ]] && continue
        _PRESERVED_VAL["$_k"]="$_v"; _PRESERVED_KEYS+=" $_k"
    done < "$CONF"
    [[ -n "$_PRESERVED_KEYS" ]] && \
        note "keeping hand-added setting(s):$_PRESERVED_KEYS"
fi

{
    echo "# WolfPack-DFT cluster profile -- generated by vasp-configure on $(date -Iseconds)"
    echo "# Sourced by the shell job scripts and parsed by vasp-recommend-slurm."
    echo "# Re-run 'vasp-configure' to regenerate, or edit by hand (KEY=\"value\")."
    echo
    for k in WP_EMAIL WP_MODULE_CMD WP_MODULE_PURGE WP_VASP_MODULES \
             WP_VASP_STD WP_VASP_GAM WP_VASP_NCL WP_VASP_LD_LIBRARY_PATH WP_EXTRA_ENV \
             WP_MAIN_PARTITION WP_DEBUG_PARTITION \
             WP_MAIN_CPUS_PER_NODE WP_DEBUG_CPUS_PER_NODE \
             WP_MAIN_MEM_PER_NODE_MB WP_DEBUG_MEM_PER_NODE_MB \
             WP_MAIN_NUMA_CORES WP_MAX_CORES \
             WP_TEST_WALLTIME_MIN WP_CHUNK_WALLTIME_MIN WP_CHUNK_MARGIN_MIN \
             WP_MEM_UTIL_MIN WP_MEM_UTIL \
             WP_GW_NODE_FRAC \
             WP_DEBUG_MAX_CORES WP_MAIN_MEM_MARGIN WP_DEBUG_MEM_MARGIN; do
        # WP_EXTRA_ENV may carry a literal $LD_LIBRARY_PATH -> single-quote it.
        if [[ "$k" == WP_EXTRA_ENV ]]; then printf "%s='%s'\n" "$k" "${!k}"
        else printf '%s="%s"\n' "$k" "${!k}"; fi
    done
    # Anything the user added by hand that this wizard does not know about.
    #
    # The header three lines up says "or edit by hand (KEY=value)". Taking that
    # invitation and then having the next `vasp-configure` truncate the file
    # back to the list above -- silently, with no diff and no warning -- is the
    # kind of data loss you only notice when a job behaves differently for no
    # visible reason. Keep them, and say they were kept.
    if [[ -n "${_PRESERVED_KEYS:-}" ]]; then
        echo
        echo "# Kept from your hand-edited profile (vasp-configure does not manage these):"
        for k in $_PRESERVED_KEYS; do
            printf '%s=%s\n' "$k" "${_PRESERVED_VAL[$k]}"
        done
    fi
} > "$CONF"

info "${c_grn}Wrote $CONF${c_rst}"
echo
echo "    email           : ${WP_EMAIL:-(none)}"
echo "    VASP modules    : ${WP_VASP_MODULES:-(none)}  [$WP_MODULE_CMD]"
[[ "$WP_VASP_STD" == */* ]]            && echo "    VASP exe (custom): $WP_VASP_STD"
[[ -n "$WP_VASP_LD_LIBRARY_PATH" ]]   && echo "    extra LD path   : $WP_VASP_LD_LIBRARY_PATH"
echo "    main partition  : $WP_MAIN_PARTITION  (${WP_MAIN_CPUS_PER_NODE} cores, ${WP_MAIN_MEM_PER_NODE_MB} MB/node)"
echo "    debug partition : $WP_DEBUG_PARTITION  (${WP_DEBUG_CPUS_PER_NODE} cores, ${WP_DEBUG_MEM_PER_NODE_MB} MB/node)"
echo "    max cores/job   : $WP_MAX_CORES"
echo "    test walltime   : ${WP_TEST_WALLTIME_MIN} min   mem policy: >=${WP_MEM_UTIL_MIN} (target ${WP_MEM_UTIL})"
echo "    chunk walltime  : ${WP_CHUNK_WALLTIME_MIN} min (margin ${WP_CHUNK_MARGIN_MIN} min)   -- one chunk of a chained relax/SCF"
echo "    mem margins     : main ${WP_MAIN_MEM_MARGIN} (=$(awk -v m=$WP_MAIN_MEM_MARGIN 'BEGIN{printf "%.0f", (1-m)*100}')% usable)"\
"   debug ${WP_DEBUG_MEM_MARGIN} (=$(awk -v m=$WP_DEBUG_MEM_MARGIN 'BEGIN{printf "%.0f", (1-m)*100}')% usable)"
echo "    debug max cores : $WP_DEBUG_MAX_CORES"
echo
echo "    These values now flow into vasp-recommend-slurm, vasp-dry-run and"
echo "    vasp-test. Re-run 'vasp-configure' (or --edit) any time to change them."
