# Test fixtures

Committed inputs for the tests in `tests/`. Everything here is generated from a
textbook silicon cell, so it carries no unpublished research and no licensed
VASP data, and it can live in the public repository.

## `dryrun_OUTCAR_Si_72k`

A real `vasp_std --dry-run` OUTCAR: 2-atom Si, a 12x12x12 mesh, **72
irreducible k-points**, 9 bands.

Small cell, dense mesh. That is the shape that makes `KPAR = NKPTS` the
best-scoring layout, and therefore the shape in which a k-point group is a
**single rank**. `compute_request_geometry`'s "one k-group per node" rule --
written for GW, where a group is many ranks and splitting one costs cross-node
chi/W traffic -- then asked for one node per rank:

    #SBATCH --nodes=72
    #SBATCH --ntasks=72

3456 cores allocated to run 72. On a real cluster that job never starts
(`AssocMaxNodePerJobLimit`); here SLURM refuses it as
`Node count specification invalid`. With the rule fixed it comes out as
`--nodes=2 --ntasks=72`.

None of the ordinary OUTCARs have this shape, which is why the bug shipped.

## `cluster.conf.48core`

A profile shaped like an HPC partition -- 48-core nodes, a 240-core account cap
-- so the tests exercise multi-node geometries rather than a laptop's single
node.
