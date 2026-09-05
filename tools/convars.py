"""Read Rust's server convars out of a real Assembly-CSharp.dll.

Every convar Rust accepts on the command line is a static field or property
carrying a [ServerVar] attribute. Its declaring type gives the prefix, so
ConVar.Server.maxplayers is reachable as +server.maxplayers.

This reads metadata only -- no .NET runtime, no Unity, nothing but the file
the server already has.

    python -m venv venv
    venv\\Scripts\\pip install dnfile

    python tools/convars.py <Assembly-CSharp.dll>                 curated list
    python tools/convars.py <Assembly-CSharp.dll> --all           everything
    python tools/convars.py <Assembly-CSharp.dll> --bat           launcher lines
    python tools/convars.py <Assembly-CSharp.dll> --check <file>  audit a launcher

WHAT "CURATED" MEANS HERE, AND WHY IT IS NOT A DUMP

A launcher listing every convar in the assembly is worse than one listing
none: the several hundred ai.*, debug.* and antihack.* entries are runtime and
diagnostic surface that nobody sets at launch, and burying the twenty that
matter in them destroys the one thing that makes the file good, which is that
a person can read it.

So the default output is curated, from two sources that are not opinions of
ours:

  1. [ServerVar(ShowInAdminUI = true)] -- Facepunch's own list of the convars
     worth showing an admin. Machine-readable, and it ships with the game.
  2. A seed of names that independent configuration sources agree on, seen in
     docs/RESEARCH.md. Evidence, not intuition.

--all is still there when you want the long tail. It is a reference to search,
not a file to paste.

DEFAULTS ARE REPORTED AS UNKNOWN RATHER THAN GUESSED

Many convars are initialised in a static constructor rather than as a
compile-time constant, so the value lives in IL, not metadata. Walking those
.cctor assignments would close most of the gap and is the obvious next step.
A comment claiming a default that has quietly moved is worse than no comment,
because somebody reads it and believes it.

STATUS: written against the metadata tables dnfile exposes, and NOT yet run
against a real Assembly-CSharp.dll. Treat its output as unverified until it
has been. See docs/OPEN-QUESTIONS.md.
"""

import re
import sys

try:
    import dnfile
except ImportError:
    sys.exit("dnfile missing:  python -m venv venv && venv\\Scripts\\pip install dnfile")

# Attributes Facepunch puts on a console variable. ServerVar is the one that
# matters for a launcher; the others are listed so we can say why something
# was skipped rather than silently dropping it.
CONVAR_ATTRS = ("ServerVar", "ClientVar", "ReplicatedVar", "AdminVar")

# Names that independent configuration sources agree on -- see
# docs/RESEARCH.md for how they were gathered and what each source was. This
# is a seed, not a verdict: anything ShowInAdminUI marks is added to it.
SEED = {
    # named by all three sources
    "server.hostname", "server.description", "server.headerimage", "server.tags",
    "server.maxplayers", "server.worldsize", "server.seed",
    # named by two of three
    "server.identity", "server.level", "server.url", "server.logoimage",
    "server.saveinterval", "server.pve", "decay.scale",
    "rcon.password", "rcon.port", "rcon.web",
    # one real server's live command line, verified working
    "server.port", "server.queryport", "server.globalchat", "server.itemdespawn",
    "server.combatlog", "server.chatlog", "server.printreportstoconsole",
    "rideablehorse.population", "hackablelockedcrate.requiredhackseconds",
}


def attr_name(ca):
    """Best-effort name of a CustomAttribute's type."""
    try:
        row = ca.Type.row
        name = getattr(row, "Name", None)
        if name:
            return str(name)
        cls = getattr(row, "Class", None)
        if cls is not None and getattr(cls, "row", None) is not None:
            return str(getattr(cls.row, "TypeName", "?"))
    except Exception:
        pass
    return "?"


def attr_blob(ca):
    """Raw bytes of a CustomAttribute's value blob, or b''."""
    for attribute in ("Value", "value", "Blob"):
        raw = getattr(ca, attribute, None)
        if raw is None:
            continue
        if isinstance(raw, (bytes, bytearray)):
            return bytes(raw)
        for inner in ("value", "raw", "data"):
            got = getattr(raw, inner, None)
            if isinstance(got, (bytes, bytearray)):
                return bytes(got)
    return b""


def shows_in_admin_ui(blob):
    """True / False when the flag is present in the blob, None when absent.

    Read by locating the length-prefixed property name and taking the byte
    after it. Decoding the blob properly means skipping the constructor's
    fixed arguments first, which needs its signature -- and [ServerVar] is
    used with and without positional arguments. This is deliberately a scan,
    and it is why the column is reported as read rather than as certain.
    """
    if not blob:
        return None
    marker = b"ShowInAdminUI"
    at = blob.find(marker)
    if at < 0:
        return None
    after = at + len(marker)
    if after >= len(blob):
        return None
    return blob[after] != 0


def collect(path):
    pe = dnfile.dnPE(path)
    md = pe.net.mdtables

    # member -> [(attribute name, blob)], keyed by (table name, row index)
    ca_map = {}
    for ca in md.CustomAttribute.rows:
        parent = ca.Parent
        table = parent.table.name if getattr(parent, "table", None) else "?"
        ca_map.setdefault((table, parent.row_index), []).append((attr_name(ca), attr_blob(ca)))

    # Two ways to find a field's row number, because dnfile's FieldList
    # entries are index objects: they normally carry row_index themselves, and
    # matching on id() of a resolved row only works if .row hands back the
    # very same object each time, which it need not.
    field_index = {id(r): i + 1 for i, r in enumerate(md.Field.rows)}

    def field_row_index(entry):
        direct = getattr(entry, "row_index", None)
        if direct is not None:
            return direct
        resolved = entry.row if hasattr(entry, "row") else entry
        return field_index.get(id(resolved))

    # constant values, for the defaults the compiler stored inline
    consts = {}
    constant_table = getattr(md, "Constant", None)
    for c in (constant_table.rows if constant_table else []):
        p = c.Parent
        table = p.table.name if getattr(p, "table", None) else "?"
        consts[(table, p.row_index)] = getattr(c, "Value", None)

    out = []
    for td in md.TypeDef.rows:
        ns = str(getattr(td, "TypeNamespace", "") or "")
        tn = str(getattr(td, "TypeName", "") or "")

        # Rust's convar classes live in the ConVar namespace. Keep others out
        # so the list stays a launcher reference, not an assembly dump.
        if ns != "ConVar":
            continue

        prefix = tn.lower()

        for f in (td.FieldList or []):
            row = f.row if hasattr(f, "row") else f
            if row is None:
                continue
            idx = field_row_index(f)
            if idx is None:
                continue

            attrs = ca_map.get(("Field", idx), [])
            kinds = [a for a, _ in attrs if any(a.startswith(k) for k in CONVAR_ATTRS)]
            if not kinds:
                continue

            admin = None
            for a, blob in attrs:
                if a.startswith("ServerVar"):
                    flag = shows_in_admin_ui(blob)
                    if flag is not None:
                        admin = flag

            name = str(getattr(row, "Name", "?"))
            default = consts.get(("Field", idx))
            full = "%s.%s" % (prefix, name)
            out.append({
                "convar": full,
                "kind": ",".join(sorted(set(kinds))),
                "default": "UNKNOWN" if default is None else repr(default),
                "type": tn,
                "admin": admin,
                "curated": bool(admin) or full.lower() in SEED,
            })

    out.sort(key=lambda r: r["convar"])
    return out


def emit_debug(path):
    """Print what the walk actually sees, so a zero result can be diagnosed.

    Written after the first real run returned nothing: the file parsed, so the
    question is which assumption about dnfile's shape is wrong -- how a
    namespace string comes back, or how a TypeDef's fields are indexed.
    """
    from collections import Counter

    pe = dnfile.dnPE(path)
    md = pe.net.mdtables

    print("dnfile version:", getattr(dnfile, "__version__", "unknown"))
    print()
    print("TABLE SIZES")
    for name in ("TypeDef", "Field", "CustomAttribute", "Constant", "MethodDef"):
        table = getattr(md, name, None)
        print("  %-16s %s" % (name, len(table.rows) if table else "MISSING"))

    if not getattr(md, "TypeDef", None) or not md.TypeDef.rows:
        print("\nNo TypeDef rows at all -- nothing else can work.")
        return

    first = md.TypeDef.rows[0]
    ns_value = getattr(first, "TypeNamespace", None)
    print()
    print("TYPEDEF SHAPE")
    print("  TypeNamespace is a %s: %r" % (type(ns_value).__name__, ns_value))
    print("  TypeName      is a %s: %r"
          % (type(getattr(first, "TypeName", None)).__name__, getattr(first, "TypeName", None)))

    counts = Counter(str(getattr(td, "TypeNamespace", "") or "") for td in md.TypeDef.rows)
    print()
    print("TOP NAMESPACES")
    for ns, n in counts.most_common(12):
        print("  %5d  %r" % (n, ns))
    print("  'ConVar' present as an exact string: %s" % ("ConVar" in counts))
    near = [ns for ns in counts if "convar" in ns.lower()]
    if near:
        print("  namespaces containing 'convar': %r" % near[:8])

    print()
    print("CONVAR TYPES AND FIELD COUNTS")
    shown = 0
    for td in md.TypeDef.rows:
        if str(getattr(td, "TypeNamespace", "") or "") != "ConVar":
            continue
        fields = getattr(td, "FieldList", None)
        print("  ConVar.%-22s fields=%s" % (getattr(td, "TypeName", "?"),
                                            len(fields) if fields else 0))
        shown += 1
        if shown >= 10:
            print("  ...")
            break
    if shown == 0:
        print("  none")

    print()
    print("FIELDLIST ENTRY SHAPE")
    for td in md.TypeDef.rows:
        fields = getattr(td, "FieldList", None)
        if not fields:
            continue
        entry = fields[0]
        print("  entry type: %s" % type(entry).__name__)
        print("  has row_index: %s (value %r)"
              % (hasattr(entry, "row_index"), getattr(entry, "row_index", None)))
        resolved = getattr(entry, "row", None)
        same = any(resolved is r for r in md.Field.rows[:500])
        print("  .row resolves: %s, and is identical to a Field row: %s"
              % (resolved is not None, same))
        break

    print()
    print("TOP CUSTOM ATTRIBUTE NAMES")
    names = Counter(attr_name(ca) for ca in md.CustomAttribute.rows)
    for name, n in names.most_common(12):
        print("  %5d  %s" % (n, name))
    varish = [n for n in names if "Var" in n]
    print("  names containing 'Var': %r" % varish[:10])

    parents = Counter(
        ca.Parent.table.name if getattr(ca.Parent, "table", None) else "?"
        for ca in md.CustomAttribute.rows
    )
    print()
    print("CUSTOM ATTRIBUTE PARENT TABLES")
    for table, n in parents.most_common(8):
        print("  %5d  %s" % (n, table))


def emit_tsv(rows):
    print("convar\tkind\tadmin_ui\tdefault")
    for r in rows:
        admin = "?" if r["admin"] is None else ("yes" if r["admin"] else "no")
        print("%s\t%s\t%s\t%s" % (r["convar"], r["kind"], admin, r["default"]))


def emit_bat(rows):
    """Launcher option lines, every one commented out.

    Disabled on purpose: an option you do not set uses the game's default, and
    a launcher that silently sets three hundred convars is not one anybody
    should run.
    """
    print("REM  Generated by tools/convars.py -- every line disabled.")
    print("REM  Remove the leading REM on a line to enable that option.")
    print("REM  UNKNOWN means the default is set in a static constructor and")
    print("REM  was not read. Check it in game rather than assuming.")
    current = None
    for r in rows:
        if r["type"] != current:
            current = r["type"]
            print()
            print("REM " + "-" * 66)
            print("REM  %s" % current)
            print("REM " + "-" * 66)
        star = " *" if r["admin"] else ""
        print("REM  %s  [default: %s]%s" % (r["convar"], r["default"], star))
        print('REM set "ARGS=!ARGS! +%s VALUE"' % r["convar"])


CONVAR_IN_BAT = re.compile(r"\+([A-Za-z0-9_]+\.[A-Za-z0-9_]+)")


def emit_check(rows, launcher_path):
    """Audit a launcher against this build.

    The point of the whole exercise: after a Rust update, tell me which
    options in my launcher no longer exist, and which of my comments now
    claim a default the game disagrees with. That turns an update from a
    mystery outage into a two-line diff.
    """
    known = {r["convar"].lower(): r for r in rows}

    with open(launcher_path, "r", encoding="utf-8", errors="replace") as handle:
        text = handle.read()

    seen, missing, mismatched = [], [], []
    for line in text.splitlines():
        stripped = line.strip()
        for name in CONVAR_IN_BAT.findall(line):
            key = name.lower()
            if key in seen:
                continue
            seen.append(key)
            row = known.get(key)
            if row is None:
                missing.append((name, stripped.upper().startswith("REM")))
                continue
            claimed = re.search(r"\[default:\s*([^\]]+)\]", text[:text.find(line) + len(line)][-400:])
            if claimed and row["default"] != "UNKNOWN":
                said = claimed.group(1).strip()
                if said.lower() not in ("unknown",) and said.strip("'\"") != row["default"].strip("'\""):
                    mismatched.append((name, said, row["default"]))

    print("Checked %s against %d convars in this build." % (launcher_path, len(known)))
    print()
    if missing:
        print("NOT IN THIS BUILD -- renamed or removed:")
        for name, disabled in missing:
            print("  %-45s %s" % (name, "(line is commented out)" if disabled else "*** ENABLED ***"))
    else:
        print("Every convar in the launcher exists in this build.")
    print()
    if mismatched:
        print("COMMENT DISAGREES WITH THE BUILD:")
        for name, said, real in mismatched:
            print("  %-40s says %-14s build says %s" % (name, said, real))
    else:
        print("No comment claims a default this build disagrees with.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)

    args = sys.argv[1:]

    if "--debug" in args:
        emit_debug(args[0])
        sys.exit(0)

    everything = "--all" in args
    rows = collect(args[0])

    admin_count = sum(1 for r in rows if r["admin"])
    curated = [r for r in rows if r["curated"]]
    shown = rows if everything else curated

    if "--check" in args:
        emit_check(rows, args[args.index("--check") + 1])
    elif "--bat" in args:
        emit_bat(shown)
    else:
        emit_tsv(shown)

    print(
        "\n%d convars carry a convar attribute. %d are ShowInAdminUI. "
        "%d curated (admin UI plus the researched seed). Showing %d."
        % (len(rows), admin_count, len(curated), len(shown)),
        file=sys.stderr,
    )
    if not rows:
        print(
            "Nothing found. Run again with --debug to print what the metadata "
            "walk actually sees; a zero here means an assumption about the "
            "table layout is wrong, not that the assembly has no convars.",
            file=sys.stderr,
        )
