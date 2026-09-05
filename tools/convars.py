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
import struct
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


def build_method_owners(md):
    """MethodDef row index -> the name of the type that declares it.

    Needed because a CustomAttribute points at the attribute's CONSTRUCTOR,
    not at the attribute type. When the attribute is defined in this assembly
    that constructor is a MethodDef, and the only way back to the type name is
    to ask which TypeDef claims it.
    """
    owners = {}
    for td in md.TypeDef.rows:
        name = str(getattr(td, "TypeName", "") or "")
        for method in (getattr(td, "MethodList", None) or []):
            index = getattr(method, "row_index", None)
            if index is not None:
                owners[index] = name
    return owners


# Accepted on the command line but not declared as a convar anywhere in the
# assembly, so a plain "is it in this build" test reports it missing. Listing
# it here is not a guess: the reference server passes it and its RCON works.
# Getting this wrong is the most damaging mistake the checker could make --
# telling somebody to delete the line that secures their RCON.
COMMAND_LINE_ONLY = {"rcon.password"}


def attr_name(ca, method_owners):
    """Name of a CustomAttribute's type.

    Reading .Name off ca.Type gives ".ctor" every single time -- it is the
    constructor's own name -- which silently matched nothing at all. Resolve
    the declaring type instead: through MemberRef.Class when the attribute
    lives in another assembly, and through the MethodDef's owning TypeDef when
    it lives in this one. Rust's [ServerVar] is the second kind.
    """
    try:
        target = ca.Type
        table = target.table.name if getattr(target, "table", None) else ""
        if table == "MethodDef":
            return method_owners.get(target.row_index, "?")
        if table == "MemberRef":
            declaring = getattr(target.row, "Class", None)
            if declaring is not None and getattr(declaring, "row", None) is not None:
                return str(getattr(declaring.row, "TypeName", "?"))
    except Exception:
        pass
    return "?"



# Instruction lengths for the opcodes a static constructor actually contains.
# Decoding forward with correct lengths matters: guessing would misalign and
# silently attribute a value to the wrong field, which is worse than reading
# nothing. An unknown opcode abandons that constructor rather than risk it.
_OPLEN = {}
for _op in list(range(0x00, 0x0E)) + [0x14, 0x15] + list(range(0x16, 0x1F)) + \
        [0x25, 0x26, 0x2A] + list(range(0x58, 0x62)) + [0x65, 0x66, 0x69, 0x6A]:
    _OPLEN[_op] = 0
for _op in (0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x1F) + tuple(range(0x2B, 0x38)):
    _OPLEN[_op] = 1
for _op in (0x20, 0x22, 0x28, 0x29, 0x6F, 0x71, 0x72, 0x73, 0x74, 0x75, 0x79,
            0x7B, 0x7C, 0x7D, 0x7E, 0x7F, 0x80, 0x8C, 0x8D, 0xA2) + tuple(range(0x38, 0x45)):
    _OPLEN[_op] = 4
for _op in (0x21, 0x23):
    _OPLEN[_op] = 8

# Field signature element types, so a 1 stored into a bool prints as true
# rather than as 1.
ELEMENT_TYPES = {
    0x02: "bool", 0x03: "char", 0x04: "sbyte", 0x05: "byte", 0x06: "short",
    0x07: "ushort", 0x08: "int", 0x09: "uint", 0x0A: "long", 0x0B: "ulong",
    0x0C: "float", 0x0D: "double", 0x0E: "string",
}


def field_element_type(row):
    sig = getattr(row, "Signature", None)
    raw = getattr(sig, "value", None) or getattr(sig, "raw", None) or sig
    if isinstance(raw, (bytes, bytearray)) and len(raw) >= 2 and raw[0] == 0x06:
        return ELEMENT_TYPES.get(raw[1])
    return None


def method_body(pe, rva):
    """Raw IL of a method, tiny or fat header."""
    offset = pe.get_offset_from_rva(rva)
    data = pe.__data__
    first = data[offset]
    if (first & 3) == 2:
        return bytes(data[offset + 1: offset + 1 + (first >> 2)])
    size = struct.unpack_from("<I", data, offset + 4)[0]
    header = (struct.unpack_from("<H", data, offset)[0] >> 12) * 4
    return bytes(data[offset + header: offset + header + size])


def scan_static_constructor(pe, code):
    """field row index -> constant assigned to it, from `ldc/ldstr; stsfld`.

    Rust declares convars as `public static int maxplayers = 500`, which the
    compiler turns into an assignment inside .cctor rather than a Constant
    table entry -- so the metadata says nothing and the IL says everything.
    This is where every real default comes from.
    """
    found = {}
    pending = None
    i = 0
    while i < len(code):
        op = code[i]
        if op == 0xFE:                      # two-byte opcode prefix
            i += 2
            pending = None
            continue
        length = _OPLEN.get(op)
        if length is None:
            return found, False             # unknown: stop rather than misalign
        arg = code[i + 1: i + 1 + length]
        if 0x16 <= op <= 0x1E:
            pending = op - 0x16
        elif op == 0x15:
            pending = -1
        elif op == 0x1F:
            pending = struct.unpack("<b", arg)[0]
        elif op == 0x20:
            pending = struct.unpack("<i", arg)[0]
        elif op == 0x21:
            pending = struct.unpack("<q", arg)[0]
        elif op == 0x22:
            pending = round(struct.unpack("<f", arg)[0], 6)
        elif op == 0x23:
            pending = struct.unpack("<d", arg)[0]
        elif op == 0x72:                    # ldstr
            token = struct.unpack("<I", arg)[0]
            try:
                pending = pe.net.user_strings.get(token & 0xFFFFFF).value
            except Exception:
                pending = None
        elif op == 0x80:                    # stsfld
            token = struct.unpack("<I", arg)[0]
            if (token >> 24) == 0x04 and pending is not None:
                found[token & 0xFFFFFF] = pending
            pending = None
        else:
            pending = None
        i += 1 + length
    return found, True


def read_il_defaults(pe, md):
    values = {}
    complete = incomplete = 0
    for td in md.TypeDef.rows:
        if str(getattr(td, "TypeNamespace", "") or "") != "ConVar":
            continue
        for method in (getattr(td, "MethodList", None) or []):
            if str(getattr(method.row, "Name", "") or "") != ".cctor":
                continue
            rva = getattr(method.row, "Rva", 0)
            if not rva:
                continue
            try:
                got, whole = scan_static_constructor(pe, method_body(pe, rva))
            except Exception:
                incomplete += 1
                continue
            values.update(got)
            complete += whole
            incomplete += (not whole)
    return values, complete, incomplete


def show_value(value, element_type):
    if value is None:
        return "UNKNOWN"
    if element_type == "bool":
        return "true" if value else "false"
    if element_type == "string":
        return '"%s"' % value
    return str(value)


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

    method_owners = build_method_owners(md)
    il_defaults, whole, partial = read_il_defaults(pe, md)

    # member -> [(attribute name, blob)], keyed by (table name, row index)
    ca_map = {}
    for ca in md.CustomAttribute.rows:
        parent = ca.Parent
        table = parent.table.name if getattr(parent, "table", None) else "?"
        ca_map.setdefault((table, parent.row_index), []).append(
            (attr_name(ca, method_owners), attr_blob(ca)))

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

    # Property row index -> (declaring type, property name). Some convars are
    # properties rather than fields -- rcon.password and server.tags among them
    # -- and a walk that only reads fields reports them as "not in this build",
    # which is the most damaging thing this tool could get wrong.
    property_owner = {}
    property_map = getattr(md, "PropertyMap", None)
    for row in (property_map.rows if property_map else []):
        parent = getattr(row, "Parent", None)
        owner = str(getattr(parent.row, "TypeName", "?")) if parent is not None else "?"
        for entry in (getattr(row, "PropertyList", None) or []):
            index = getattr(entry, "row_index", None)
            if index is not None:
                property_owner[index] = (owner, str(getattr(entry.row, "Name", "?") or "?"))

    def convar_kinds(table, index):
        names = [a for a, _ in ca_map.get((table, index), [])]
        return [a for a in names if any(a.startswith(k) for k in CONVAR_ATTRS)]

    def admin_flag(table, index):
        for a, blob in ca_map.get((table, index), []):
            if a.startswith("ServerVar"):
                flag = shows_in_admin_ui(blob)
                if flag is not None:
                    return flag
        return None

    out = []
    seen = set()

    # Convars are NOT confined to the ConVar namespace. Plenty are declared on
    # ordinary game classes -- HackableLockedCrate.requiredHackSeconds becomes
    # +hackablelockedcrate.requiredhackseconds -- and the prefix is simply the
    # declaring type's name, lowercased. Filtering on namespace lost all of
    # them.
    for td in md.TypeDef.rows:
        tn = str(getattr(td, "TypeName", "") or "")
        if not tn:
            continue
        prefix = tn.lower()

        for f in (td.FieldList or []):
            row = f.row if hasattr(f, "row") else f
            if row is None:
                continue
            idx = field_row_index(f)
            if idx is None:
                continue
            kinds = convar_kinds("Field", idx)
            if not kinds:
                continue

            name = str(getattr(row, "Name", "?"))
            default = consts.get(("Field", idx))
            element = field_element_type(row)
            if default is None:
                default = il_defaults.get(idx)
            full = "%s.%s" % (prefix, name)
            if full.lower() in seen:
                continue
            seen.add(full.lower())
            admin = admin_flag("Field", idx)
            out.append({
                "convar": full,
                "kind": ",".join(sorted(set(kinds))),
                "default": show_value(default, element),
                "value_type": element or "?",
                "type": tn,
                "admin": admin,
                "curated": bool(admin) or full.lower() in SEED,
            })

    for index, (owner, name) in property_owner.items():
        kinds = convar_kinds("Property", index)
        if not kinds:
            continue
        full = "%s.%s" % (owner.lower(), name)
        if full.lower() in seen:
            continue
        seen.add(full.lower())
        admin = admin_flag("Property", index)
        out.append({
            # A property's value comes from a getter, so there is no constant
            # to read. UNKNOWN here is the honest answer, not a failure.
            "convar": full,
            "kind": ",".join(sorted(set(kinds))),
            "default": "UNKNOWN",
            "value_type": "property",
            "type": owner,
            "admin": admin,
            "curated": bool(admin) or full.lower() in SEED,
        })

    out.sort(key=lambda r: r["convar"])
    print("Read %d defaults out of %d static constructors (%d abandoned early)."
          % (len(il_defaults), whole + partial, partial), file=sys.stderr)
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
    names = Counter(attr_name(ca, build_method_owners(md)) for ca in md.CustomAttribute.rows)
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
    print("convar\tkind\ttype\tadmin_ui\tdefault")
    for r in rows:
        admin = "?" if r["admin"] is None else ("yes" if r["admin"] else "no")
        print("%s\t%s\t%s\t%s\t%s"
              % (r["convar"], r["kind"], r["value_type"], admin, r["default"]))


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

    The point of the whole exercise: after a Rust update, tell me which options
    in my launcher no longer exist, and which of my comments now claim a
    default the game disagrees with. That turns an update from a mystery
    outage into a two-line diff.
    """
    known = {r["convar"].lower(): r for r in rows}

    with open(launcher_path, "r", encoding="utf-8", errors="replace") as handle:
        lines = handle.read().splitlines()

    missing, mismatched, checked = [], [], 0
    claimed = None
    for line in lines:
        found = re.search(r"\[default:\s*([^\]]+)\]", line)
        if found:
            claimed = found.group(1).strip()

        names = CONVAR_IN_BAT.findall(line)
        if not names:
            continue

        for name in names:
            checked += 1
            if name.lower() in COMMAND_LINE_ONLY:
                continue
            row = known.get(name.lower())
            if row is None:
                missing.append((name, line.strip().upper().startswith("REM")))
                continue
            if claimed and claimed.lower() != "unknown" and row["default"] != "UNKNOWN":
                if claimed.strip('"\'') != row["default"].strip('"'):
                    mismatched.append((name, claimed, row["default"]))
        claimed = None

    print("Checked %d options in %s against %d convars in this build."
          % (checked, launcher_path, len(known)))
    print()

    if missing:
        print("NOT IN THIS BUILD -- renamed or removed:")
        for name, disabled in missing:
            print("  %-46s %s" % (name, "(commented out)" if disabled else "*** ENABLED ***"))
    else:
        print("Every convar in the launcher exists in this build.")
    print()

    if mismatched:
        print("COMMENT DISAGREES WITH THE BUILD:")
        for name, said, real in mismatched:
            print("  %-42s says %-12s build says %s" % (name, said, real))
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
