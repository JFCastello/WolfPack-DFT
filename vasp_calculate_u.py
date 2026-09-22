#!/usr/bin/env python3
"""
vasp_calculate_u.py  (invoked on PATH as: vasp-calculate-u)
              --  Stage 4 of 4: Cococcioni linear-response Hubbard U
====================================================================
Reads U_data.dat (written by collect_u_data.sh) and computes the
effective Hubbard U parameter by a linear fit of the response functions:

    chi_0 = d(dN_NSCF) / d(alpha)   (non-self-consistent response slope)
    chi   = d(dN_SCF)  / d(alpha)   (self-consistent response slope)
    U     = 1/chi - 1/chi_0         (Cococcioni & de Gironcoli, PRB 2005)

INPUT
    U_data.dat  --  must be in the current working directory.
                    Columns: alpha(eV)  N_NSCF  N_SCF  dN_NSCF  dN_SCF
                    where dN = N(alpha) - N_GS (occupation change from
                    ground state). This file is produced by collect_u_data.sh.

USAGE
    cd <your_U_calculation_directory>
    python vasp_calculate_u.py

OUTPUT
    Prints one line:  U = X.XXX eV

WORKFLOW  (4-step Cococcioni linear-response U on a SLURM cluster)
    Step 1:  run_nscf_steps.sh  --  submit NSCF perturbation jobs
    Step 2:  run_scf_steps.sh   --  submit SCF response jobs
    Step 3:  collect_u_data.sh  --  gather d/f-occupations into U_data.dat
    Step 4:  vasp_calculate_u.py       --  linear fit -> U           <-- THIS STEP

NOTES
    - The fit uses numpy.polyfit (degree 1) with a free intercept, which
      is more honest than forcing the line through zero for finite grids.
    - Columns 2 and 3 of U_data.dat (N_NSCF and N_SCF averages) are read
      but not used here; only columns 4 and 5 (dN_NSCF, dN_SCF) matter.
    - Reference: Cococcioni & de Gironcoli, Phys. Rev. B 71, 035105 (2005).
"""

import argparse
import sys

import numpy as np

_p = argparse.ArgumentParser(
    prog="vasp-calculate-u",
    description="Linear-response Hubbard U from U_data.dat "
                "(Cococcioni & de Gironcoli, PRB 71, 035105 (2005)).",
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog=__doc__)
_p.add_argument("-f", "--file", default="U_data.dat",
                help="the table written by collect-u-data (default: U_data.dat)")
# Parsed BEFORE anything is read, so `--help` answers instead of crashing with
# a FileNotFoundError about a file the user has never heard of.
_args = _p.parse_args()

try:
    data = np.loadtxt(_args.file, unpack=True, ndmin=2)
except FileNotFoundError:
    sys.exit(f"error: {_args.file} not found.\n"
             "       It is written by collect-u-data, which reads the OUTCARs of\n"
             "       the alpha-perturbed runs. Run that first, in this folder.")
except ValueError as exc:
    sys.exit(f"error: {_args.file} is not a table this can read ({exc}).\n"
             "       Expected 5 whitespace-separated columns:\n"
             "           alpha(eV)  N_NSCF  N_SCF  dN_NSCF  dN_SCF")

if len(data) < 5:
    sys.exit(f"error: {_args.file} has {len(data)} column(s), expected 5:\n"
             "           alpha(eV)  N_NSCF  N_SCF  dN_NSCF  dN_SCF")
alpha, _, _, dN_nscf, dN_scf = data[:5]

# A slope needs at least two points, and at least two DISTINCT alphas: a fit
# through one point, or through several at the same alpha, is not a response.
if np.size(alpha) < 2 or np.unique(alpha).size < 2:
    sys.exit(f"error: {_args.file} has fewer than two distinct alpha values, so\n"
             "       there is no slope to fit. The linear response needs a range\n"
             "       of alpha (typically -0.2 .. +0.2 eV).")

chi0 = np.polyfit(alpha, dN_nscf, 1)[0]
chi = np.polyfit(alpha, dN_scf, 1)[0]

# U = chi^-1 - chi_0^-1.
#
# The sign hinges on which way the occupation moves, and it is easy to get
# backwards by reasoning instead of looking. VASP's own worked example settles
# it: perturbing with LDAUU = LDAUJ = +0.10 eV makes the d occupancy of the
# perturbed site RISE, 8.439 -> 8.488 electrons, so dN > 0 for alpha > 0 and
# BOTH response slopes are POSITIVE:
#
#     chi_0 = 0.050/0.1 = 0.50 (eV)^-1     non-self-consistent (ICHARG=11)
#     chi   = 0.014/0.1 = 0.14 (eV)^-1     self-consistent
#     U     = 1/chi - 1/chi_0                  -> positive
#
# Screening makes chi SMALLER than chi_0, so 1/chi > 1/chi_0 and U comes out
# positive, as a Hubbard U on a 3d oxide must.
#     https://vasp.at/wiki/Calculate_U_for_LSDA%2BU
for name, val in (("chi_0 (non-self-consistent)", chi0), ("chi (self-consistent)", chi)):
    if val == 0.0:
        sys.exit(f"error: {name} fitted to exactly zero, so 1/{name.split()[0]} is\n"
                 "       infinite and U is undefined. The occupations do not respond\n"
                 "       to alpha at all -- check that the perturbed runs actually\n"
                 "       differ from the ground state, and that the right site and\n"
                 "       orbital were collected.")

U = 1.0 / chi - 1.0 / chi0
print(f"chi_0 = {chi0:.6f} e/eV   (non-self-consistent response)")
print(f"chi   = {chi:.6f} e/eV   (self-consistent response)")
print(f"U = {U:.3f} eV")
