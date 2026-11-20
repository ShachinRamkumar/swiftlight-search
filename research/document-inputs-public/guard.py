"""Bound disk allocation and cumulative network reads for this study."""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import shutil
import time
import urllib.error
import urllib.request
from durable import save_json

ROOT = Path.home() / '.swiftlight-research/public-bench'
ROOT.mkdir(parents=True,exist_ok=True)
FLOOR = 14 * 1024**3
CAP = 4_000_000_000
# pip's displayed downloads total < 200 MB. Reserve 500 MB, including metadata and earlier source inspection.
RESERVE = 500_000_000
LEDGER = ROOT / os.environ.get('SWIFTLIGHT_DOWNLOAD_LEDGER', 'downloads.json')
os.environ['HF_HOME'] = str(ROOT / 'hf')
for key,folder in [('TMPDIR','tmp'),('TORCH_HOME','torch'),('XDG_CACHE_HOME','cache'),('PIP_CACHE_DIR','pip-cache')]:
    (ROOT/folder).mkdir(exist_ok=True)
    os.environ[key]=str(ROOT/folder)
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'


def check(allocate=0):
    free = shutil.disk_usage('/').free
    if free - allocate < FLOOR:
        raise RuntimeError(f'disk floor: {free} bytes free; proposed {allocate}; minimum {FLOOR}')
    with (ROOT/'disk-samples.jsonl').open('a') as out:
        out.write(json.dumps({'time':time.time(),'free_bytes':free})+'\n')
    return free


def publish(state):
    save_json(LEDGER,state)


def total_reserved(own_state):
    total = own_state['bytes'] + own_state.get('inflight_bytes',0)
    for path in [ROOT/'downloads.json', ROOT/'prefetch-downloads.json']:
        if path != LEDGER and path.exists():
            other = json.loads(path.read_text())
            total += other['bytes'] + other.get('inflight_bytes',0)
    return total


def read(url, destination=None, expected=None, sha=None, resume=False,timeout=120):
    """Count every transfer byte; optionally resume a hash-checked model partial."""
    check(expected or 0)
    reserve = RESERVE if LEDGER.name=='downloads.json' else 0
    state = json.loads(LEDGER.read_text()) if LEDGER.exists() else {'bytes': reserve, 'reserve_bytes': reserve, 'requests': 0}
    data = bytearray() if destination is None else None
    output = None
    offset=0
    if destination is not None:
        destination = Path(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        partial=destination.with_suffix(destination.suffix+'.part')
        if resume and partial.exists():
            offset=partial.stat().st_size
            if expected is None or offset>expected:
                raise RuntimeError('invalid partial download size')
        output=partial.open('ab' if offset else 'wb')
    count = 0
    digest = hashlib.sha256()
    if offset:
        with partial.open('rb') as existing:
            while chunk:=existing.read(1024*1024):
                digest.update(chunk)
    try:
        request=urllib.request.Request(url,headers={'Range':f'bytes={offset}-'} if offset else {})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if offset and (response.status!=206 or not response.headers.get('Content-Range','').startswith(f'bytes {offset}-')):
                raise RuntimeError('server did not honor download resume range')
            length = int(response.headers.get('Content-Length', 0))
            check(length)
            # Separate writers have separate ledgers. A short lock reserves the shared global allowance.
            # No network read or wait happens under this lock.
            allowance = (expected-offset) if expected is not None else (length or 16_000_000)
            with (ROOT/'download-budget.lock').open('a') as lock:
                fcntl.flock(lock,fcntl.LOCK_EX)
                state['inflight_bytes'] = allowance
                if total_reserved(state) > CAP:
                    state['inflight_bytes'] = 0
                    raise RuntimeError('download cap would be exceeded')
                publish(state)
            while chunk := response.read(1024 * 1024):
                check(len(chunk) + 8_000_000)
                state['bytes'] += len(chunk)
                count += len(chunk)
                if count > allowance:
                    raise RuntimeError('response exceeds reserved length')
                digest.update(chunk)
                if output:
                    output.write(chunk)
                else:
                    data.extend(chunk)
                # Persist consumption after every chunk, so a reboot cannot lose the accounting.
                state['inflight_bytes']=max(0,allowance-count)
                with (ROOT/'download-budget.lock').open('a') as lock:
                    fcntl.flock(lock,fcntl.LOCK_EX)
                    publish(state)
        if expected is not None and count+offset != expected:
            raise RuntimeError(f'wrong length: {count+offset} != {expected}')
        if length and count != length:
            raise RuntimeError(f'incomplete HTTP response: {count} != {length}')
        if sha and digest.hexdigest() != sha:
            raise RuntimeError('SHA-256 mismatch')
    finally:
        state['requests'] += 1
        state['minimum_free_at_last_request'] = shutil.disk_usage('/').free
        state['inflight_bytes'] = 0
        with (ROOT/'download-budget.lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            publish(state)
        if output:
            output.flush()
            os.fsync(output.fileno())
            output.close()
    if destination is not None:
        destination.with_suffix(destination.suffix + '.part').replace(destination)
    return bytes(data) if data is not None else None


def fetch(url,destination=None):
    for attempt in range(5):
        try:
            return read(url,destination,timeout=45)
        except urllib.error.HTTPError as error:
            if error.code not in (429, 500, 502, 503, 504) or attempt == 4:
                raise
            retry_after=error.headers.get('Retry-After','0')
            delay=min(60,max(5*(attempt+1),int(retry_after) if retry_after.isdigit() else 0))
        except (TimeoutError,urllib.error.URLError,ConnectionError) as error:
            if attempt==4:raise
            delay=5*(attempt+1)
        print('network retry in',delay,'seconds',flush=True)
        time.sleep(delay)


def get_json(url):
    return json.loads(fetch(url))
