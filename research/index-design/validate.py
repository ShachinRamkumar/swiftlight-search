#!/usr/bin/env python3
"""Final aggregate-only validation of the real migration and both format prototypes."""
import json
import shutil
from pathlib import Path
from study import ROOT,connect,logical_digest,queries,keyword_bench


def main():
    scratch=Path.home()/'.swiftlight-research/index-design'
    baseline=connect(scratch/'baseline.sqlite')
    tables=(('files','id'),('segments','id'),('embedding_inputs','segment'),('vectors','model,segment'),
            ('fts','rowid'),('embedding_models','id'),('embedding_failures','model,segment'),
            ('embedding_modality_identities','model,modality'))
    hashes={t:logical_digest(baseline,t,o) for t,o in tables}
    meta=baseline.execute("SELECT * FROM meta ORDER BY key").fetchall()
    qs=queries(baseline,scratch/'queries.json')
    expected=keyword_bench(baseline,qs)[1]
    out={}
    for name,path in (('backend','backend-compacted.sqlite'),('compressed','fts-compressed-external.sqlite'),('reference','fts-reference-external.sqlite')):
        c=connect(scratch/path)
        equal={t:logical_digest(c,t,o)==hashes[t] for t,o in tables}
        assert all(equal.values())
        metadata=c.execute("SELECT * FROM meta WHERE key!='storage_compaction_v1' ORDER BY key").fetchall()
        assert metadata==meta
        integrity=c.execute('PRAGMA integrity_check').fetchone()[0]
        assert integrity=='ok'
        assert not c.execute('PRAGMA foreign_key_check').fetchall()
        c.execute("INSERT INTO fts(fts,rank) VALUES('integrity-check',1)")
        c.commit()
        keyword=keyword_bench(c,qs,expected)[0]
        assert keyword['different_queries']==0
        out[name]={'retained_tables_identical':equal,'metadata_identical_except_compaction_marker':True,
                   'sqlite_integrity':integrity,'fts_integrity':'ok','fk_violations':0,'keyword':keyword}
        c.close()
        (scratch/'validation.json').write_text(json.dumps(out,indent=2))
        print(name,'final validation complete',flush=True)
    out['resources']={'final_free_disk_bytes':shutil.disk_usage(scratch).free,'required_free_disk_bytes':12*1024**3}
    (scratch/'validation.json').write_text(json.dumps(out,indent=2))


if __name__=='__main__':main()
