#!/usr/bin/env python3
"""
wolfpack_incar.py -- edit an INCAR the way the user laid it out.

Not a command: a library the toolkit's Python tools import. The shell tools
carry the same table and the same rules in wolfpack_incar.sh; running this file
directly compares the two and exits non-zero if they have drifted apart
(publish_public.sh runs it as a release gate).

==================================================================
WHY THIS EXISTS
==================================================================
Five places in the toolkit used to edit an INCAR, each with its own regex and
its own idea of where a new tag goes. They all appended to the bottom of the
file, so a MAGMOM landed under "Parallelization" and a KPAR under "Write
flags". vasp-test went further and appended a banner plus a block of duplicate
tags, relying on VASP taking the LAST occurrence.

None of that is wrong for VASP, which does not care about order or sections.
It is wrong for the person who has to read the file afterwards, and an INCAR
that no longer reads like the one you wrote is an INCAR you stop trusting.

So: a tag goes in its section. Only there. The section headers, the comment
character and the column alignment are taken from the file itself, so a file
with no sections stays a file with no sections.

==================================================================
THE RULES
==================================================================
1. The tag is already there (active)  -> its value is replaced where it sits.
   Indentation is preserved. Its trailing comment is kept unless a new note is
   given, because that comment is usually the user's own note to themselves.

2. The tag is absent, its section exists -> appended to the END of that
   section's block, after the last tag in it.

3. The tag is absent and so is its section -> the section is created, with its
   header, in the canonical position relative to the sections that DO exist.
   A file with no section headers at all gets none: the tag is appended plainly.

4. Commented out -> a '#' goes in front of the existing line, in place. The
   line is never deleted, because the value it held is evidence.

5. Alignment follows the file. Where the file has none, it follows the layout
   this toolkit's own template uses: '=' at column 7, comment at column 23.
"""

import re

# --------------------------------------------------------------------------- #
# Which section each tag belongs to.
# --------------------------------------------------------------------------- #
# Order matters twice over: it is the order sections are created in, and the
# order they are searched. A tag missing from this table is appended at the end
# of the file rather than guessed at -- putting ENCUTGW under "Write flags"
# because it starts with E would be worse than leaving it at the bottom.
INCAR_SECTIONS = [
    ("Startup job description", [
        "SYSTEM", "ISTART", "ICHARG", "ISPIN", "LASPH", "METAGGA", "GGA",
        "MAGMOM", "NUPDOWN", "LSORBIT", "LNONCOLLINEAR", "SAXIS",
        "LHFCALC", "AEXX", "HFSCREEN",
    ]),
    ("Electronic Relaxation", [
        "PREC", "ENCUT", "ENAUG", "ALGO", "NELM", "NELMIN", "NELMDL", "EDIFF",
        "LREAL", "LMAXMIX", "NBANDS", "AMIX", "BMIX", "AMIX_MAG", "BMIX_MAG",
        "IMIX", "ADDGRID", "LDAU", "LDAUTYPE", "LDAUL", "LDAUU", "LDAUJ",
        "LDAUPRINT",
    ]),
    ("Ionic relaxation", [
        "IBRION", "POTIM", "ISIF", "NSW", "EDIFFG", "ISYM", "NFREE", "SMASS",
        "MDALGO", "TEBEG", "TEEND",
    ]),
    ("DOS related values", [
        "ISMEAR", "SIGMA", "EFERMI", "NEDOS", "EMIN", "EMAX",
    ]),
    ("Write flags", [
        "LWAVE", "LCHARG", "LORBIT", "LVTOT", "LVHAR", "LELF", "LAECHG",
    ]),
    ("Parallelization", [
        "NCORE", "KPAR", "NPAR", "NSIM", "LPLANE", "LSCALU", "LSCALAPACK",
        "MAXMEM",
    ]),
]

HEADER_DASHES = 45      # "!" + 45 dashes + " " + name, as the template writes it
KEY_COL = 7             # '=' sits here when the key is short enough
NOTE_COL = 23           # '!' sits here


def section_of(key):
    """The section a tag belongs in, or None when the table does not know it."""
    k = key.upper()
    for name, keys in INCAR_SECTIONS:
        if k in keys:
            return name
    return None


def comment_char(text):
    """The character this INCAR uses for a TRAILING comment ('!' or '#').

    Only trailing comments are counted: a file can annotate with '!' while
    commenting whole tags out with '#', and it is the annotation style that the
    lines written here have to match.
    """
    trailing = re.findall(r"=[ \t]*\S+[ \t]+([!#])", text)
    return "!" if trailing.count("!") > trailing.count("#") else "#"


def format_line(key, value, note="", cc="!", indent="", cols=None):
    """One INCAR line, aligned to `cols` = (column of '=', column of the note).

    Without `cols` it falls back to the layout this toolkit's template uses.
    Callers pass the columns they measured from the file, because a block that
    lines its '=' up at column 6 should keep doing so after an edit -- reflowing
    it to some canonical width is exactly the kind of churn that makes a file
    stop looking like the one you wrote.
    """
    key, value = str(key), str(value)
    eq_col, note_col = cols or (KEY_COL, NOTE_COL)
    lhs = key.ljust(max(eq_col, len(key) + 1)) + "= "
    if not note:
        return f"{indent}{lhs}{value}"
    pad = max(1, note_col - len(indent) - len(lhs) - len(value))
    return f"{indent}{lhs}{value}{' ' * pad}{cc} {note}"


def _columns_of(line):
    """(column of '=', column of the trailing comment) for one INCAR line."""
    m = re.match(r"^[ \t]*\w+[ \t]*(=)[ \t]*\S", line)
    if not m:
        return None
    eq = m.start(1) - (len(line) - len(line.lstrip()))
    c = re.search(r"\S[ \t]+([!#])", line)
    note = None
    if c:
        note = c.start(1) - (len(line) - len(line.lstrip()))
    return (eq, note if note is not None else NOTE_COL)


def _section_columns(lines, start, end):
    """The alignment the tags between `start` and `end` already agree on."""
    seen = {}
    for line in lines[start:end]:
        c = _columns_of(line)
        if c:
            seen[c] = seen.get(c, 0) + 1
    return max(seen, key=seen.get) if seen else None


def _active(lines, key):
    """Index of the ACTIVE line for KEY, or None.

    Anchored so that a leading '#' or '!' does not match -- a commented-out tag
    is not the tag -- and so that NELM does not swallow NELMIN: after the name
    only blanks may precede the '='.
    """
    pat = re.compile(rf"^([ \t]*){re.escape(key)}[ \t]*=", re.IGNORECASE)
    for i, line in enumerate(lines):
        m = pat.match(line)
        if m:
            return i
    return None


def _headers(lines):
    """[(line index, section name)] for every section header in the file."""
    out = []
    for i, line in enumerate(lines):
        m = re.match(r"^[ \t]*[!#]-{3,}[ \t]*(.+?)[ \t]*$", line)
        if m:
            out.append((i, m.group(1).strip()))
    return out


def _canon_index(name):
    for i, (sec, _) in enumerate(INCAR_SECTIONS):
        if sec.lower() == name.lower():
            return i
    return None


def _end_of_section(lines, start):
    """Index just past the last tag line of the section beginning at `start`.

    Trailing blank lines belong to the gap between sections, not to the section,
    so they are skipped back over: a tag appended here lands under the last tag,
    not after the blank line that separates the blocks.
    """
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if re.match(r"^[ \t]*[!#]-{3,}", lines[i]):
            end = i
            break
    while end > start + 1 and not lines[end - 1].strip():
        end -= 1
    return end


def set_tag(text, key, value, note=""):
    """Set KEY = VALUE, in its own section. Returns the new text."""
    cc = comment_char(text)
    lines = text.split("\n")

    idx = _active(lines, key)
    if idx is not None:
        indent = re.match(r"^([ \t]*)", lines[idx]).group(1)
        keep = note
        if not keep:
            m = re.search(r"[!#][ \t]*(.*)$", lines[idx].split("=", 1)[1])
            keep = m.group(1).strip() if m else ""
        lines[idx] = format_line(key, value, keep, cc, indent,
                                 _columns_of(lines[idx]))
        return "\n".join(lines)

    want = section_of(key)
    heads = _headers(lines)

    # No sections at all, or no home for this tag: plain append, as before.
    if not heads or want is None:
        out = "\n".join(lines).rstrip("\n")
        line = format_line(key, value, note, cc)
        return (out + "\n" + line + "\n") if out else line + "\n"

    for start, name in heads:
        if name.lower() == want.lower():
            end = _end_of_section(lines, start)
            line = format_line(key, value, note, cc,
                               cols=_section_columns(lines, start, end))
            lines.insert(end, line)
            return "\n".join(lines)

    line = format_line(key, value, note, cc)

    # The section is missing: create it before the first section that comes
    # AFTER it in the canonical order, so the file keeps the template's shape.
    mine = _canon_index(want)
    at = len(lines)
    for start, name in heads:
        ci = _canon_index(name)
        if ci is not None and mine is not None and ci > mine:
            at = start
            break
    header = cc + "-" * HEADER_DASHES + " " + want
    block = [header, line, ""]
    if at < len(lines):
        lines[at:at] = block
    else:
        while lines and not lines[-1].strip():
            lines.pop()
        lines += [""] + block[:2] + [""]
    return "\n".join(lines)


def comment_tag(text, key, why=""):
    """Comment an ACTIVE KEY out where it sits, keeping the value on record."""
    cc = comment_char(text)
    lines = text.split("\n")
    idx = _active(lines, key)
    if idx is None:
        return text
    indent = re.match(r"^([ \t]*)", lines[idx]).group(1)
    body = lines[idx][len(indent):]
    lines[idx] = f"{indent}# {body}" + (f"   {cc} {why}" if why else "")
    return "\n".join(lines)


def get_tag(text, key):
    """The value of an ACTIVE KEY, comment stripped, or None."""
    lines = text.split("\n")
    idx = _active(lines, key)
    if idx is None:
        return None
    return re.split(r"[!#]", lines[idx].split("=", 1)[1], 1)[0].strip()


def _check_shell_table(sh_path):
    """Compare this table with the one in wolfpack_incar.sh.

    Two implementations of the same rules in two languages is a deliberate
    choice -- the shell tools edit the INCAR from inside a compute job that
    loads only VASP's modules, so they cannot import this file. The cost of
    that choice is drift, so it is checked rather than hoped for.
    """
    import re as _re
    text = open(sh_path).read()
    m = _re.search(r"WP_INCAR_SECTIONS='(.*?)'", text, _re.S)
    if not m:
        return ["wolfpack_incar.sh: WP_INCAR_SECTIONS not found"]
    sh = []
    for line in m.group(1).strip().split("\n"):
        name, keys = line.split("|", 1)
        sh.append((name.strip(), keys.split()))
    problems = []
    if [n for n, _ in sh] != [n for n, _ in INCAR_SECTIONS]:
        problems.append(f"section order differs:\n  py: {[n for n, _ in INCAR_SECTIONS]}"
                        f"\n  sh: {[n for n, _ in sh]}")
    for (pn, pk), (sn, sk) in zip(INCAR_SECTIONS, sh):
        if pn == sn and pk != sk:
            problems.append(f"'{pn}': py has {sorted(set(pk) - set(sk))} extra, "
                            f"sh has {sorted(set(sk) - set(pk))} extra")
    for const, pat in (("HEADER_DASHES", r"WP_INCAR_DASHES=(\d+)"),
                       ("KEY_COL", r"WP_INCAR_KEY_COL=(\d+)"),
                       ("NOTE_COL", r"WP_INCAR_NOTE_COL=(\d+)")):
        mm = _re.search(pat, text)
        if not mm or int(mm.group(1)) != globals()[const]:
            problems.append(f"{const}: py={globals()[const]} sh={mm.group(1) if mm else '?'}")
    return problems


if __name__ == "__main__":
    import os
    import sys as _sys
    sh = _sys.argv[1] if len(_sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.realpath(__file__)), "wolfpack_incar.sh")
    bad = _check_shell_table(sh)
    for b in bad:
        print(b, file=_sys.stderr)
    print("INCAR layout tables agree" if not bad else "INCAR layout tables DRIFTED",
          file=_sys.stderr)
    _sys.exit(1 if bad else 0)
