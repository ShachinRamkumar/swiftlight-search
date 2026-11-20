#!/usr/bin/env python3
"""Count exact SQLite record bytes by column, including serialized headers.

Unlike length(CAST(integer AS BLOB)), this counts SQLite's integer encoding.
Only record headers are decoded. No stored text or paths are emitted.
Use a checkpointed snapshot, never a live WAL database.
"""
import json
from pathlib import Path
import struct

from study import connect, guard


def varint(data, at):
    start = at
    value = 0
    for _ in range(8):
        byte = data[at]
        at += 1
        value = (value << 7) | (byte & 127)
        if byte < 128:
            return value, at, at-start
    return (value << 8) | data[at], at+1, 9


def serial_size(serial):
    if serial in (0,8,9):
        return 0
    if serial <= 7:
        return (0,1,2,3,4,6,8,8)[serial]
    if serial < 12:
        raise ValueError("reserved serial type")
    return (serial-12)//2


def audit(path):
    guard(path)
    assert not Path(str(path)+"-wal").exists() or Path(str(path)+"-wal").stat().st_size == 0
    c=connect(path)
    pagesize=c.execute("PRAGMA page_size").fetchone()[0]
    objects=c.execute("SELECT name,type FROM sqlite_master WHERE rootpage>0").fetchall()
    objects.append(("sqlite_schema","table"))
    out={}
    with path.open("rb") as f:
        for name,kind in objects:
            if kind == "index":
                columns=[r[2] if r[2] else "<rowid>" for r in c.execute(f'PRAGMA index_xinfo("{name}")')]
            else:
                columns=[r[1] for r in c.execute(f'PRAGMA table_info("{name}")')]
                # WITHOUT ROWID records store PK columns before non-PK columns.
                pk=next((r[1] for r in c.execute(f'PRAGMA index_list("{name}")') if r[3]=="pk"),None)
                if pk:
                    columns=[r[2] for r in c.execute(f'PRAGMA index_xinfo("{pk}")')]
            totals={n:{"value_bytes":0,"serial_type_bytes":0,"records":0} for n in columns}
            headers=0
            record_bytes=0
            for pageno,expected_payload in c.execute("SELECT pageno,payload FROM dbstat WHERE name=? AND pagetype!='overflow'",(name,)):
                f.seek((pageno-1)*pagesize)
                page=f.read(pagesize)
                base=100 if pageno==1 else 0
                page_type=page[base]
                count=struct.unpack_from('>H',page,base+3)[0]
                header=12 if page_type in (2,5) else 8
                if page_type==5:
                    continue
                if page_type not in (2,10,13):
                    raise ValueError("unexpected btree page type")
                for i in range(count):
                    at=struct.unpack_from('>H',page,base+header+2*i)[0]
                    if page_type==2:
                        at+=4
                    payload,at,_=varint(page,at)
                    if page_type==13:
                        _,at,_=varint(page,at)
                    record_at=at
                    header_size,at,nbytes=varint(page,at)
                    headers+=nbytes
                    col=0
                    cell_bytes=header_size
                    while at < record_at+header_size:
                        serial,at,nbytes=varint(page,at)
                        size=serial_size(serial)
                        field=totals[columns[col]]
                        field['value_bytes']+=size
                        field['serial_type_bytes']+=nbytes
                        field['records']+=1
                        cell_bytes+=size
                        col+=1
                    assert cell_bytes==payload,(name,cell_bytes,payload)
                    record_bytes+=cell_bytes
            dbstat_payload=c.execute("SELECT sum(payload) FROM dbstat WHERE name=?",(name,)).fetchone()[0]
            assert record_bytes==dbstat_payload,(name,record_bytes,dbstat_payload)
            out[name]={"columns":totals,"record_header_length_bytes":headers,"total_record_bytes":record_bytes}
    return out


if __name__=='__main__':
    scratch=Path.home()/'.swiftlight-research/index-design'
    out=audit(scratch/'baseline.sqlite')
    (scratch/'column-bytes.json').write_text(json.dumps(out,indent=2))
    print('Exact record accounting reconciled with dbstat for',len(out),'objects')
