# test_37_lplane

> LPLANE as the VASP wiki sets it: from NGZ, the band group and the network; written, and checked by vasp-test

## 1. Definition

Checks the three pieces that handle `LPLANE`:

- `wolfpack_hw.sh` reads the interconnect from a fake `/sys`;
- `vasp-recommend-slurm` sets LPLANE per layout, writes it into the INCAR, and
  records it for vasp-test;
- vasp-test's helper checks it on a benchmark OUTCAR.

## 2. Purpose

[LPLANE](https://vasp.at/wiki/LPLANE) = .TRUE. (the default) distributes the
real-space grid in z-planes. The page's rule: ".TRUE. should only be used if NGZ
is at least 3×(number of nodes)/NPAR". Its "nodes" are MPI ranks (the page
predates NCORE), so the rule reads NGZ ≥ 3 × NCORE, the ranks sharing one
band's FFT. On "a LINUX cluster linked by a relatively slow network, LPLANE must
be set to .TRUE.".

Before 2026-09-25 the recommender read "nodes" as compute nodes:
`3 × nodes / NPAR` is below 1 for any layout on one node, so the rule never
fired. Its LPLANE was also never written into the INCAR, so vasp-test
benchmarked VASP's default whatever was recommended. And the network was not
known at all.

## 3. How it is executed

```
tests/run_all.sh test_37_lplane
```

Fake `/sys` trees for six networks; `lplane_for()` called directly; three
recommendations on a fabricated dry run (1 k-point, 480 bands, 48-core nodes)
whose NGZ is set by the test; a benchmark OUTCAR for the helper. Seconds.

## 4. Expected results

| case | expected |
|---|---|
| two InfiniBand ports, one ACTIVE | `infiniband`, the ACTIVE one and its rate |
| `hfi1_0`; a port with link layer Ethernet; `/sys/class/cxi/cxi0` | `omnipath`; `roce`; `slingshot` |
| no RDMA device, `eno1` at 1000 Mb/s, a virtual one at -1 | `ethernet`, 1000 Mb/s |
| nothing in `/sys/class` | `unknown` |
| NGZ 28, NCORE 4 | .TRUE. (28 ≥ 12) |
| NGZ 20, NCORE 8 | .FALSE. (20 < 24) |
| the same on 1 Gbit Ethernet | no setting allowed: the layout goes |
| the same on 10 Gbit Ethernet | the NGZ rule alone (the page speaks of 1 Gbit) |
| no grid in the dry run | the VASP default, saying so |
| NGZ 96 | .TRUE. with its reason; the interconnect printed; LPLANE = .TRUE. written into an INCAR that said .FALSE.; `lplane=".TRUE."` in the state |
| NGZ 12, the chosen NCORE > 4 | .FALSE., written |
| NGZ 12 on 1 Gbit Ethernet | .TRUE., with only NCORE ≤ 4 left, and the reason printed |
| vasp-test: a benchmark with NGZ 28, NCORE 4, LREAL = Auto | an `[LPLANE]` block: as run and as recommended; NGZ and NCORE from the OUTCAR, the rule holding; the real-space projectors' total and max/min per rank as VASP 6.5.1 prints them (735.12 KBytes, 185.50 / 182.75, ×1.015); the node's network next to the profile's |
| NGZ 20, NCORE 8, run with .TRUE. | a warning quoting the page |
| a compute node on Ethernet, a profile saying InfiniBand | said, with `vasp-configure --interconnect ethernet` and what to re-run |

## 5. Obtained results

All twenty-three as expected. With the previous recommender and helper, 17 of
the 23 fail (the 6 that pass are `wolfpack_hw.sh`'s, which is new).

**What it changes in practice**, on 42 fabricated dry runs (NGZ from 24 to 144,
1/8/41 k-points, caps of 96 and 240 cores, 48-core nodes, InfiniBand): **6 of
42 recommendations change.**

- **NGZ 24, 240 cores.** The previous version chose NCORE = 12 with .TRUE.,
  which breaks the rule (3 × 12 = 36 > 24): the case this fixes. The new one
  chooses NCORE = 16 with .FALSE.; the existing NCORE rule (≈ √ranks) outweighs
  the small preference for .TRUE.
- **NGZ 36 and 60, 96 cores.** The previous version's NCORE = 24 won on +6
  points of "LPLANE .TRUE. satisfies the rule" for a setting that did not
  (3 × 24 = 72 > 36). Without those points the existing rules choose NCORE = 1
  on the same 48 ranks.

Measured with the final scoring, including the small preference for .TRUE.; it
changes none of the 42 against the version without it.

The real-space projector block was checked on a real VASP 6.5.1 run before
being parsed: the wiki calls it "real space projector functions"; VASP prints
"real space projection operators:". The pattern accepts both.

## 6. Pass / fail criterion

Exact: detected kinds and details, the rule's output and reason, the INCAR line,
the state line.

## 7. Verdict

See `logs/run.log`.

## Sources

- LPLANE — <https://vasp.at/wiki/LPLANE>
- NPAR's default is "available ranks", equivalent to NCORE = 1 —
  <https://vasp.at/wiki/NPAR>
- NCORE: "how many MPI ranks collaborate on a single band, parallelizing the
  FFTs for that band" — <https://vasp.at/wiki/NCORE>
- sysfs: `/sys/class/infiniband/<dev>/ports/<n>/{link_layer,state,rate}` and
  `/sys/class/net/<if>/speed` — Linux kernel ABI documentation
  (`Documentation/ABI/stable/sysfs-class-infiniband`, `sysfs-class-net`)
