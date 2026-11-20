"""Audit OCR provenance, the source word filter, soft-token budgets, and mixed truncation."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import unicodedata

from guard import ROOT

HERE=Path(__file__).resolve().parent


def has_words(text):
    letters=sum(unicodedata.category(c)[0] in 'LM' for c in text if not c.isspace())
    others=sum(not c.isspace() for c in text)-letters
    return letters>0 and letters*4>=others


def main():
    reports={}
    for file in sorted(HERE.glob('inputs-*.json')):
        name=file.stem.removeprefix('inputs-')
        inputs=json.loads(file.read_text())
        metadata=json.loads((ROOT/name/'metadata.json').read_text())
        assert len(inputs)==len(metadata['pages'])
        mostly_digits=[]
        for page,stats in zip(metadata['pages'],inputs):
            assert page['id']==stats['page_id']
            text=page.get('text')
            if text is None:
                key=hashlib.sha256(page['id'].encode()).hexdigest()[:20]
                text=(ROOT/name/(key+'.txt')).read_text()
            assert hashlib.sha256(text.encode()).hexdigest()==stats['text_sha256']
            if stats['text_characters']>=200 and not has_words(text):
                mostly_digits.append(page['id'])
        reports[name]={'pages':len(inputs),'text_hashes_match':True,
                       'long_OCR_pages_failing_source_word_guard':len(mostly_digits),
                       'affected_page_ids':mostly_digits,
                       'empty_OCR_pages':sum(p['text_characters']==0 for p in inputs),
                       'soft_token_histogram':dict(sorted(Counter(p['soft_tokens'] for p in inputs).items())),
                       'mixed_trimmed_pages':{v:sum(p['trimmed_tokens'][v]>0 for p in inputs)
                                               for v in ['V2','V2_text_image','prompt_image']}}
    (HERE/'diagnostics.json').write_text(json.dumps(reports,indent=2)+'\n')
    print(json.dumps(reports,indent=2))


if __name__=='__main__':
    main()
