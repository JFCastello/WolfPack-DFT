#!/usr/bin/env bash
# wolfpack_incar.sh -- edit an INCAR the way the user laid it out.  (LIBRARY)
# ============================================================================
# Not a command: sourced by the shell tools. The Python tools carry the same
# table and the same rules in wolfpack_incar.py; running THAT file directly
# compares the two tables and fails if they have drifted apart.
#
# WHY A SECOND IMPLEMENTATION INSTEAD OF CALLING THE PYTHON ONE:
#   vasp-chain and vasp-test edit the INCAR from INSIDE a compute job, and the
#   rendered job loads only VASP's modules. A python import there would be a
#   latent failure at 3am, at the exact moment the chain is trying to recover --
#   the same reasoning that keeps contcar_ok() in pure awk. So: pure awk/bash.
#
# THE RULES (identical to the Python side):
#   1. Tag already active      -> value replaced where it sits, alignment and
#                                 indentation kept, its own trailing comment
#                                 kept unless a new note is given.
#   2. Tag absent, section here-> appended to the END of that section's block,
#                                 aligned the way that block already aligns.
#   3. Tag absent, no section  -> the section is created in canonical order.
#                                 A file with no headers at all gets none.
#   4. Commented out           -> '#' in front, in place, never deleted.
#
# USAGE
#   source /path/to/wolfpack_incar.sh
#   wp_incar_set     INCAR MAGMOM "4*0.0 2*5.0" "AFM ordering"
#   wp_incar_comment INCAR NUPDOWN "would force all orderings to one moment"
#   wp_incar_get     INCAR NELM
# ============================================================================

# Section table. Keep in step with INCAR_SECTIONS in wolfpack_incar.py.
# Format: one "Section name|KEY KEY KEY" per line, in canonical order.
WP_INCAR_SECTIONS='Startup job description|SYSTEM ISTART ICHARG ISPIN LASPH METAGGA GGA MAGMOM NUPDOWN LSORBIT LNONCOLLINEAR SAXIS LHFCALC AEXX HFSCREEN
Electronic Relaxation|PREC ENCUT ENAUG ALGO NELM NELMIN NELMDL EDIFF LREAL LMAXMIX NBANDS AMIX BMIX AMIX_MAG BMIX_MAG IMIX ADDGRID LDAU LDAUTYPE LDAUL LDAUU LDAUJ LDAUPRINT
Ionic relaxation|IBRION POTIM ISIF NSW EDIFFG ISYM NFREE SMASS MDALGO TEBEG TEEND
DOS related values|ISMEAR SIGMA EFERMI NEDOS EMIN EMAX
Write flags|LWAVE LCHARG LORBIT LVTOT LVHAR LELF LAECHG
Parallelization|NCORE KPAR NPAR NSIM LPLANE LSCALU LSCALAPACK MAXMEM'

WP_INCAR_DASHES=45     # "!" + 45 dashes + " " + name, as the template writes it
WP_INCAR_KEY_COL=7     # '=' sits here when the key is short enough
WP_INCAR_NOTE_COL=23   # '!' sits here

# --------------------------------------------------------------------------- #
# incar_set FILE KEY VALUE [NOTE]
# --------------------------------------------------------------------------- #
wp_incar_set(){
    local f="$1" key="$2" val="$3" note="${4:-}" tmp
    [[ -f "$f" ]] || return 1
    tmp="$(mktemp)" || return 1
    awk -v KEY="$key" -v VAL="$val" -v NOTE="$note" \
        -v TABLE="$WP_INCAR_SECTIONS" -v DASHES="$WP_INCAR_DASHES" \
        -v KEYCOL="$WP_INCAR_KEY_COL" -v NOTECOL="$WP_INCAR_NOTE_COL" '
    function upper(s){ return toupper(s) }
    # the section KEY belongs to, "" when the table does not know it
    function section_of(k,   n,i,parts,name,keys,j,kk) {
        n = split(TABLE, parts, "\n")
        for (i = 1; i <= n; i++) {
            split(parts[i], kv, "|"); name = kv[1]
            j = split(kv[2], keys, " ")
            for (kk = 1; kk <= j; kk++) if (keys[kk] == upper(k)) return name
        }
        return ""
    }
    function canon_index(name,   n,i,parts,kv) {
        n = split(TABLE, parts, "\n")
        for (i = 1; i <= n; i++) { split(parts[i], kv, "|")
            if (tolower(kv[1]) == tolower(name)) return i }
        return 0
    }
    # one aligned line; eq/note are the columns this block already uses
    function fmt(k, v, nt, cc, ind, eq, nc,   lhs, pad) {
        lhs = k
        while (length(lhs) < (eq > length(k) ? eq : length(k) + 1)) lhs = lhs " "
        lhs = lhs "= "
        if (nt == "") return ind lhs v
        pad = nc - length(ind) - length(lhs) - length(v)
        if (pad < 1) pad = 1
        return ind lhs v sprintf("%" pad "s", "") cc " " nt
    }
    function eq_col(line,   s, p) {
        s = line; sub(/^[ \t]+/, "", s)
        if (s !~ /^[A-Za-z_][A-Za-z_0-9]*[ \t]*=/) return -1
        p = index(s, "="); return p - 1
    }
    function note_col(line,   s, p) {
        s = line; sub(/^[ \t]+/, "", s)
        p = match(s, /[^ \t][ \t]+[!#]/)
        if (p == 0) return NOTECOL
        return p + RLENGTH - 2
    }
    function indent_of(line,   s) { s = line; sub(/[^ \t].*$/, "", s); return s }
    function is_header(line) { return line ~ /^[ \t]*[!#]-{3,}[ \t]*[^ \t]/ }
    function header_name(line,   s) {
        s = line; sub(/^[ \t]*[!#]-+[ \t]*/, "", s); sub(/[ \t]+$/, "", s); return s
    }
    # ---- pass 1: learn the file -------------------------------------------
    NR == FNR {
        L[FNR] = $0; n = FNR
        s = $0; sub(/^[ \t]+/, "", s)
        if (toupper(s) ~ "^" toupper(KEY) "[ \t]*=") { if (!act) act = FNR }
        if (is_header($0)) { hpos[++nh] = FNR; hname[nh] = header_name($0) }
        if ($0 ~ /=[ \t]*[^ \t]+[ \t]+!/) bang++
        if ($0 ~ /=[ \t]*[^ \t]+[ \t]+#/) hash++
        next
    }
    END {
        cc = (bang > hash) ? "!" : "#"
        # 1. already there: replace in place, keeping its own columns
        if (act) {
            ind = indent_of(L[act]); e = eq_col(L[act]); c = note_col(L[act])
            keep = NOTE
            if (keep == "") {
                rest = L[act]; sub(/^[^=]*=/, "", rest)
                if (match(rest, /[!#][ \t]*/)) {
                    keep = substr(rest, RSTART + RLENGTH)
                    sub(/[ \t]+$/, "", keep)
                }
            }
            L[act] = fmt(KEY, VAL, keep, cc, ind, e, c)
            for (i = 1; i <= n; i++) print L[i]
            exit
        }
        want = section_of(KEY)
        # 2. no headers at all, or no home for this tag: plain append
        if (nh == 0 || want == "") {
            last = n; while (last > 0 && L[last] ~ /^[ \t]*$/) last--
            for (i = 1; i <= last; i++) print L[i]
            print fmt(KEY, VAL, NOTE, cc, "", KEYCOL, NOTECOL)
            exit
        }
        # 3. the section exists: append to the end of its block
        for (h = 1; h <= nh; h++) if (tolower(hname[h]) == tolower(want)) {
            start = hpos[h]
            stop = (h < nh) ? hpos[h + 1] : n + 1
            while (stop > start + 1 && L[stop - 1] ~ /^[ \t]*$/) stop--
            # the alignment this block already agrees on
            besteq = KEYCOL; bestnc = NOTECOL; bestcount = 0
            for (i = start + 1; i < stop; i++) {
                e = eq_col(L[i]); if (e < 0) continue
                c = note_col(L[i]); k = e "," c; tally[k]++
                if (tally[k] > bestcount) { bestcount = tally[k]; besteq = e; bestnc = c }
            }
            for (i = 1; i < stop; i++) print L[i]
            print fmt(KEY, VAL, NOTE, cc, "", besteq, bestnc)
            for (i = stop; i <= n; i++) print L[i]
            exit
        }
        # 4. create the section, in canonical order among the ones present
        mine = canon_index(want); at = 0
        for (h = 1; h <= nh; h++) {
            ci = canon_index(hname[h])
            if (ci > 0 && mine > 0 && ci > mine) { at = hpos[h]; break }
        }
        dash = ""; for (i = 0; i < DASHES; i++) dash = dash "-"
        hdr = cc dash " " want
        if (at > 0) {
            for (i = 1; i < at; i++) print L[i]
            print hdr
            print fmt(KEY, VAL, NOTE, cc, "", KEYCOL, NOTECOL)
            print ""
            for (i = at; i <= n; i++) print L[i]
        } else {
            last = n; while (last > 0 && L[last] ~ /^[ \t]*$/) last--
            for (i = 1; i <= last; i++) print L[i]
            print ""
            print hdr
            print fmt(KEY, VAL, NOTE, cc, "", KEYCOL, NOTECOL)
        }
    }
    ' "$f" "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$f"; rm -f "$tmp"
}

# --------------------------------------------------------------------------- #
# incar_comment FILE KEY [WHY]   -- comment an ACTIVE tag out, in place
# --------------------------------------------------------------------------- #
wp_incar_comment(){
    local f="$1" key="$2" why="${3:-}" tmp
    [[ -f "$f" ]] || return 1
    tmp="$(mktemp)" || return 1
    awk -v KEY="$key" -v WHY="$why" '
    NR == FNR {
        if ($0 ~ /=[ \t]*[^ \t]+[ \t]+!/) bang++
        if ($0 ~ /=[ \t]*[^ \t]+[ \t]+#/) hash++
        next
    }
    {
        s = $0; sub(/^[ \t]+/, "", s)
        if (!done && toupper(s) ~ "^" toupper(KEY) "[ \t]*=") {
            cc = (bang > hash) ? "!" : "#"
            ind = $0; sub(/[^ \t].*$/, "", ind)
            print ind "# " s (WHY == "" ? "" : "   " cc " " WHY)
            done = 1; next
        }
        print
    }
    ' "$f" "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$f"; rm -f "$tmp"
}

# --------------------------------------------------------------------------- #
# incar_get FILE KEY   -- the value of an ACTIVE tag, comment stripped
# --------------------------------------------------------------------------- #
wp_incar_get(){
    [[ -f "$1" ]] || return 1
    awk -v KEY="$2" '
    { s = $0; sub(/^[ \t]+/, "", s)
      if (toupper(s) ~ "^" toupper(KEY) "[ \t]*=") {
          sub(/^[^=]*=[ \t]*/, "", s); sub(/[ \t]*[!#].*$/, "", s)
          sub(/[ \t]+$/, "", s); print s; exit } }
    ' "$1"
}
