# test_16_chain_live

> vasp-scf-loop's restart: an SCF cut in two vs one run, same energy, fewer steps

## 1. Definition

Runs the same static SCF twice: once straight through, and once cut after 8
electronic steps and restarted with the tags `vasp-scf-loop` writes at a
boundary. It compares the final energies, and how many steps the restart
needed.

## 2. Purpose

`vasp-scf-loop` exists to cut a long SCF into short jobs that fit a queue. Its
value rests on one claim:

> splitting the calculation changes the answer by nothing.

That cannot be verified by reading code. The restart the chain writes is
`ISTART = 1` (read the WAVECAR), `ICHARG = 0` (the density from those
wavefunctions) and `NELMDL = 0` (no non-self-consistent delay on a restart).
This test runs exactly those tags.

A restart that silently lost the WAVECAR would still converge to the same
energy, just from scratch. So the step count is checked too: a restart that
used the wavefunctions needs fewer steps than a cold start.

The relaxation's counterpart is `test_33_chain_live_e2e`, which runs
`vasp-relax-loop` itself against a direct relaxation.

## 3. How it is executed

```
tests/run_all.sh test_16_chain_live
```

Silicon, 2 atoms, 6×6×6 k-points. Four VASP runs on 4 ranks; about a minute.

- **direct**: `NELM = 40`, straight through.
- **chunked**: `NELM = 8`, then `NELM = 40` with `ISTART = 1`, `ICHARG = 0`,
  `NELMDL = 0` from its own WAVECAR. The boundary is done by hand, so the
  comparison isolates the **restart** from the scheduler.
- **the control**: the same restart, the same tags, with no WAVECAR to read.

## 4. Expected results

The same energy, to numerical precision: the restart reads the wavefunctions
the first half wrote. Fewer steps after the restart than the control needs.

The control is not the direct run: that one pays 5 non-self-consistent steps
(`NELMDL = -5`, VASP's default for a cold start) that a restart with
`NELMDL = 0` does not, so a restart that ignored the WAVECAR could still come in
under it.

## 5. Obtained results

```
the SCF really was split                     8 then 4 electronic steps
chunked and direct SCF agree in energy       |dE| = 0.00e+00 eV
the restart used the WAVECAR                 4 steps, against 11 with no WAVECAR
```

The energy agrees to the last printed digit.

## 6. Pass / fail criterion

| quantity | tolerance | why |
|---|---|---|
| SCF energy | 1e-4 eV | a restart from the same wavefunctions has no excuse |
| steps after the restart | fewer than the control's | the control is a restart from scratch with the same tags |

## 7. Verdict

**PASSED** — 3 assertions, 0 failed. See `logs/run.log`.

## Sources

- `ISTART` — <https://www.vasp.at/wiki/index.php/ISTART>
- `ICHARG` — <https://www.vasp.at/wiki/index.php/ICHARG>
- `NELMDL` — <https://www.vasp.at/wiki/index.php/NELMDL>
