"""Fetch the original checkpoint, pinned and hash-checked, under the scratch directory."""
import hashlib
from guard import ROOT, check, read
from eg2ref import REVISION, CHECKPOINT_SHA256

FILES = {
    'model.safetensors': (1488915288, CHECKPOINT_SHA256),
    'tokenizer.json': (32170510, '4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4'),
    'config.json': (None, None),
    'tokenizer_config.json': (None, None),
    'preprocessor_config.json': (None, None),
    'processor_config.json': (None, None),
}


def main():
    folder = ROOT / 'model'
    folder.mkdir(exist_ok=True)
    for name, (size, sha) in FILES.items():
        path = folder / name
        if path.exists() and (size is None or path.stat().st_size == size):
            if sha is None or hashlib.file_digest(path.open('rb'), 'sha256').hexdigest() == sha:
                print('verified', name, flush=True)
                continue
        print('fetch', name, 'free', check(size or 0), flush=True)
        read(f'https://huggingface.co/google/embeddinggemma-2/resolve/{REVISION}/{name}', path, size, sha,resume=size is not None)


if __name__ == '__main__':
    main()
