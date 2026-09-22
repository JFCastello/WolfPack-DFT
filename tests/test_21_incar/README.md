# test_21_incar

> the INCAR editor: the user's layout survives every edit, in both copies

## 1. Definition

Applies each of the editor's four rules to an INCAR laid out the way the
toolkit's template lays one out, and checks what the file looks like
afterwards. Then runs the gate that compares the editor's **two**
implementations against each other.

## 2. Purpose

Five places in the toolkit used to edit an INCAR, each with its own regex and
its own idea of where a new tag goes. None of it was wrong for VASP, which does
not care about order or sections. It was wrong for the person who has to read
the file afterwards — and an INCAR that no longer reads like the one you wrote
is an INCAR you stop trusting.

The second half is the one that decays quietly. There are **two**
implementations of the same rules: pure awk for the job scripts, which run on a
compute node with only VASP's modules loaded, and Python for the tools that
have it. Two implementations of one rule set are two chances to be wrong
differently, so the Python side carries a gate that compares the tables.
`publish_public.sh` runs it as a release gate; this test runs the same gate,
and then checks the gate can still fail.

## 3. How it is executed

```
tests/run_all.sh test_21_incar
```

Sources `wolfpack_incar.sh` directly and calls its functions. Seconds; no VASP.

## 4. Expected results

| rule | expected |
|---|---|
| 1 — tag already active | value replaced **where it sits**, alignment kept, its own trailing comment kept unless a new note is given |
| 2 — tag absent, section present | appended to the end of **that section** |
| 3 — tag absent, section absent | the section is created, in canonical order; a file with **no** headers gets none |
| 4 — commenting out | `#` in front, in place, never deleted; reads back as unset |
| the drift gate | the two tables agree — **and** a deliberately altered table is detected |

That last line matters: a gate that cannot fail is not a gate, so the test
feeds it a table it has broken on purpose and requires it to notice.

## 5. Obtained results

All sixteen as expected. `ENCUT` is replaced on its own line 6 with no
duplicate below; `EDIFF` lands inside *Electronic Relaxation*, not at the
bottom of the file; a created `Parallelization` section appears in canonical
order; a headerless file stays headerless; the tables agree, and the altered
one is caught.

No package bug was found here. Three assertions failed on the first run; all
three were **mine**.


## 6. Pass / fail criterion

Exact, by line number and by content. There is nothing approximate in this
test: a tag is either in its section or it is not.

## 7. Verdict

**PASSED** — 16 assertions, 0 failed. See `logs/run.log`.

## Sources

None needed: the layout rules are this package's own, stated at the top of
`wolfpack_incar.sh` and `wolfpack_incar.py`, and the test checks the code
against that stated contract. VASP itself is indifferent to INCAR order —
<https://www.vasp.at/wiki/index.php/INCAR> — which is precisely why nothing but
a test like this would notice the layout decaying.
