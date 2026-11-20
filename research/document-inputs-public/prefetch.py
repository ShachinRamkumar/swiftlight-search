"""Optional raster prefetch while viewer asset URLs remain valid. No model or OCR work."""
import os
os.environ['SWIFTLIGHT_DOWNLOAD_LEDGER'] = 'prefetch-downloads.json'

import hashlib
import json
import sys
from guard import ROOT, check, fetch


def main():
    for name in sys.argv[1:]:
        state=json.loads((ROOT/name/'metadata.json').read_text())
        for i,page in enumerate(state['pages']):
            path=ROOT/name/(hashlib.sha256(page['id'].encode()).hexdigest()[:20]+'.jpg')
            if not path.exists():
                fetch(page['image_url'],path)
            if (i+1)%100==0:
                print(name,i+1,'free_GB',round(check()/1e9,2),flush=True)


if __name__=='__main__':
    main()
