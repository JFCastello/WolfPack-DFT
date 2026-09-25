#!/usr/bin/env bash
# vasp-scf-loop: the guards that stop a chain from starting
# when it cannot possibly work. Every one of these is a run that would consume
# queue time and produce nothing, so refusing early IS the feature.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/chain_math"; rm -rf "$W"; mkdir -p "$W"
CH="$TK_DIR/vasp_chain.sh"

_calc(){ # _calc DIR "INCAR body"   -- a folder that looks like a finished stage 2
    local d="$W/$1"; mkdir -p "$d/.wolfpack"
    cp "$CASES/Si/POSCAR" "$d/POSCAR"
    printf 'Auto\n0\nGamma\n4 4 4\n0 0 0\n' > "$d/KPOINTS"
    printf '  TITEL  = synthetic test fixture -- not a VASP potential\n' > "$d/POTCAR"
    cat > "$d/INCAR"
    cat > "$d/slurm_vasptest.sh" <<EOS
#!/bin/bash
#SBATCH --job-name=x
#SBATCH --partition=local
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=4
#SBATCH --mem-per-cpu=500
#SBATCH --time=00:20:00
/usr/bin/time -v srun --cpu-bind=cores vasp_std
EOS
    printf 'stage="test"\ntest_avg_loop="2.0"\ntest_ranks="4"\ntest_cpu_eff="90"\ntest_startup_s="10"\n' \
        > "$d/.wolfpack/state.env"
    echo "$d"
}

# --- the mode must match the INCAR -----------------------------------------
# A relaxation INCAR handed to the SCF chain would have its NELM chunked while
# the ions keep moving: every chunk boundary truncates an electronic loop and
# the forces that move the ions next are wrong. It has to refuse.
d=$(_calc relax_to_scf <<'EOF'
NSW = 50
IBRION = 2
ISIF = 3
NELM = 60
EDIFF = 1E-6
ENCUT = 520
EOF
)
must_refuse "vasp-scf-loop refuses a RELAXATION INCAR" "relaxation, not a static|NSW" \
    bash -c "cd '$d' && '$CH' --mode scf </dev/null"

# A relaxation is vasp-relax-loop's, a different script: vasp_chain.sh is the
# SCF chain only.
d=$(_calc relax_mode <<'EOF'
NSW = 0
NELM = 200
EOF
)
must_refuse "vasp_chain.sh refuses the relax mode and names vasp-relax-loop" "vasp-relax-loop" \
    bash -c "cd '$d' && '$CH' --mode relax </dev/null"

# --- molecular dynamics cannot be chunked ----------------------------------
# IBRION=0 carries velocities and thermostat state that no restart file keeps.
# Chunking it silently restarts the thermostat every boundary.
d=$(_calc md <<'EOF'
IBRION = 0
NSW = 1000
POTIM = 2.0
NELM = 60
ENCUT = 520
EOF
)
must_refuse "a molecular-dynamics run is refused, not chunked" "molecular dynamics|velocit" \
    bash -c "cd '$d' && '$CH' --mode scf </dev/null"

# --- the walltime must leave room to compute -------------------------------
d=$(_calc tiny <<'EOF'
NSW = 0
NELM = 200
EDIFF = 1E-6
ENCUT = 520
EOF
)
must_refuse "a walltime with no room to compute is refused" "no room to compute|walltime" \
    bash -c "cd '$d' && '$CH' --mode scf --walltime 5 </dev/null"

# --- the measured rate is required, not guessed ----------------------------
d=$(_calc nomeasure <<'EOF'
NSW = 0
NELM = 200
EDIFF = 1E-6
ENCUT = 520
EOF
)
printf 'stage="test"\n' > "$d/.wolfpack/state.env"     # no test_avg_loop
must_refuse "a chain refuses to size itself without a MEASURED per-step time" \
    "no measured per-step|vasp-test" \
    bash -c "cd '$d' && '$CH' --mode scf </dev/null"

# --- the pipeline must have run ---------------------------------------------
d=$(_calc noslurm <<'EOF'
NSW = 0
NELM = 200
EDIFF = 1E-6
ENCUT = 520
EOF
)
rm -f "$d/slurm_vasptest.sh"
must_refuse "a chain refuses when stage 2 never produced a job script" "slurm|pipeline first" \
    bash -c "cd '$d' && '$CH' --mode scf </dev/null"

# --- not a calculation directory -------------------------------------------
mkdir -p "$W/empty"
must_refuse "a chain refuses outside a calculation folder" "no INCAR" \
    bash -c "cd '$W/empty' && '$CH' --mode scf </dev/null"

# Anything that slipped past a guard may have queued a chain. Do not leave it.
command -v scancel >/dev/null 2>&1 && \
    SLURM_CONF="$TESTBED_ROOT/slurm.conf" scancel -u "$USER" 2>/dev/null || true
exit $(( FAIL_N > 0 ))
