#!/usr/bin/env python3
"""Measure conditional retirement of unselected legacy text, without changing either live image policy."""
import json
from pathlib import Path
from study import clone,compact,size
from vectors import collect


def main():
    scratch=Path.home()/'.swiftlight-research/index-design'
    c=clone(scratch/'fts-reference-external.sqlite',scratch/'retired-text.sqlite')
    policies=('coreai-all','coreai-text-legacy-image')
    before={p:collect(c,p) for p in policies}
    removed=c.execute("SELECT count(*),sum(length(vec)) FROM packed_segments WHERE modality='text' AND vec IS NOT NULL").fetchone()
    triggers=c.execute("SELECT name,sql FROM sqlite_master WHERE type='trigger'").fetchall()
    c.execute('BEGIN IMMEDIATE')
    for name,_ in triggers:c.execute(f'DROP TRIGGER "{name}"')
    c.execute("UPDATE packed_segments SET vec=NULL WHERE modality='text'")
    for _,sql in triggers:c.execute(sql)
    c.commit();compact(c,16384)
    equal={p:collect(c,p)==before[p] for p in policies}
    assert all(equal.values())
    out={'bytes':size(c),'removed_legacy_text_vectors':removed[0],'removed_payload_bytes':removed[1],
         'selected_vector_rows_identical':equal,
         'restriction':'Core AI text selection only; legacy-text rollback is no longer supported without regeneration'}
    (scratch/'retired.json').write_text(json.dumps(out,indent=2));print('conditional legacy-text retirement measured',flush=True)


if __name__=='__main__':main()
