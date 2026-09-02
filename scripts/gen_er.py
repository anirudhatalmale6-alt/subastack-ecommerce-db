#!/usr/bin/env python3
"""
Generate the ER diagram from the LIVE database catalogue, not from a
hand-drawn picture that drifts out of date.

    python3 scripts/gen_er.py "$DB_URL" docs/er-diagram

writes <out>.dot and, if graphviz is installed, <out>.png.

Every table, column, primary key and foreign key is read out of
information_schema / pg_catalog, so the diagram is by construction a
description of what is actually deployed.
"""
import json
import os
import shutil
import subprocess
import sys

GROUPS = {
    "catalogue": (["categories", "products", "product_variants", "product_images"], "#1f6f8b"),
    "stock":     (["inventory", "inventory_movements"], "#7d5ba6"),
    "customers": (["customers", "addresses"], "#2e7d5b"),
    "cart":      (["carts", "cart_items"], "#8a6d1f"),
    "orders":    (["orders", "order_items", "order_status_history"], "#b1442b"),
    "money":     (["payments"], "#4a4a8a"),
    "fulfilment":(["shipments", "shipment_items"], "#3f6b3f"),
}

COLUMNS_SQL = """
select json_agg(t) from (
  select c.relname as table_name,
         a.attname as column_name,
         format_type(a.atttypid, a.atttypmod) as data_type,
         a.attnotnull as not_null,
         coalesce(pk.is_pk, false) as is_pk,
         coalesce(fk.is_fk, false) as is_fk,
         a.attnum
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
    left join lateral (
      select true as is_pk from pg_constraint k
       where k.conrelid = c.oid and k.contype = 'p' and a.attnum = any(k.conkey)) pk on true
    left join lateral (
      select true as is_fk from pg_constraint k
       where k.conrelid = c.oid and k.contype = 'f' and a.attnum = any(k.conkey)) fk on true
   where n.nspname = 'public' and c.relkind = 'r'
   order by c.relname, a.attnum
) t;
"""

FKS_SQL = """
select json_agg(t) from (
  select src.relname as src_table,
         tgt.relname as tgt_table,
         (select string_agg(a.attname, ',' order by x.ord)
            from unnest(k.conkey) with ordinality x(attnum, ord)
            join pg_attribute a on a.attrelid = src.oid and a.attnum = x.attnum) as src_columns
    from pg_constraint k
    join pg_class src on src.oid = k.conrelid
    join pg_class tgt on tgt.oid = k.confrelid
    join pg_namespace n on n.oid = src.relnamespace
   where k.contype = 'f' and n.nspname = 'public'
   order by 1, 2
) t;
"""


def query(db_url, sql):
    out = subprocess.run(
        ["psql", db_url, "-t", "-A", "-X", "-v", "ON_ERROR_STOP=1", "-c", sql],
        check=True, capture_output=True, text=True).stdout.strip()
    return json.loads(out) if out else []


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def colour_of(table):
    for _, (tables, colour) in GROUPS.items():
        if table in tables:
            return colour
    return "#555555"


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: gen_er.py <db-url> [out-prefix]")
    db_url = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "docs/er-diagram"

    cols = query(db_url, COLUMNS_SQL)
    fks = query(db_url, FKS_SQL)

    by_table = {}
    for c in cols:
        by_table.setdefault(c["table_name"], []).append(c)

    lines = [
        "digraph er {",
        '  graph [rankdir=LR, splines=spline, overlap=false, nodesep=0.6, ranksep=1.4, bgcolor="white",',
        '         fontname="Helvetica", label="Subastack e-commerce schema", labelloc=t, fontsize=20];',
        '  node  [shape=plaintext, fontname="Helvetica", fontsize=10];',
        '  edge  [color="#666666", arrowsize=0.7, penwidth=1.1];',
        "",
    ]

    for table, columns in sorted(by_table.items()):
        colour = colour_of(table)
        rows = [
            f'<tr><td bgcolor="{colour}" colspan="2" align="center">'
            f'<font color="white"><b>{esc(table)}</b></font></td></tr>'
        ]
        for c in columns:
            name = esc(c["column_name"])
            if c["is_pk"]:
                name = f"<b>{name}</b>  <font color='#b8860b'>PK</font>"
            elif c["is_fk"]:
                name = f"{name}  <font color='#1f6f8b'>FK</font>"
            null_mark = "" if c["not_null"] else " <font color='#999999'>?</font>"
            rows.append(
                f'<tr><td align="left" port="{esc(c["column_name"])}">{name}{null_mark}</td>'
                f'<td align="left"><font color="#666666">{esc(c["data_type"])}</font></td></tr>')
        label = ('<<table border="0" cellborder="1" cellspacing="0" cellpadding="4">'
                 + "".join(rows) + "</table>>")
        lines.append(f'  "{table}" [label={label}];')

    lines.append("")
    for fk in fks:
        src_col = fk["src_columns"].split(",")[0]
        tgt = fk["tgt_table"]
        head = f'"{tgt}":"id"' if tgt in by_table else f'"{tgt}"'
        lines.append(
            f'  "{fk["src_table"]}":"{src_col}":e -> {head}:w '
            f'[color="{colour_of(tgt)}"];')

    # Tables outside `public` that we point at (auth.users) get a plain node.
    external = {fk["tgt_table"] for fk in fks} - set(by_table)
    for name in sorted(external):
        lines.append(
            f'  "{name}" [shape=box, style="rounded,dashed", fontsize=11, '
            f'label="auth.{name}\\n(platform-managed)", fontcolor="#666666", color="#999999"];')

    lines.append("}")

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    dot_path = out + ".dot"
    with open(dot_path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"wrote {dot_path}  ({len(by_table)} tables, {len(fks)} foreign keys)")

    if shutil.which("dot"):
        png_path = out + ".png"
        subprocess.run(["dot", "-Tpng", "-Gdpi=110", dot_path, "-o", png_path], check=True)
        print(f"wrote {png_path}")
    else:
        print("graphviz not installed -- skipped PNG render")


if __name__ == "__main__":
    main()
