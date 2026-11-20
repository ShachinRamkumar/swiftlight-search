"""Atomic, fsynced records for restart checkpoints."""
import json
import os
from pathlib import Path


def write_atomic(path,write):
    path=Path(path)
    path.parent.mkdir(parents=True,exist_ok=True)
    part=path.with_name(path.name+'.part')
    with part.open('wb') as stream:
        write(stream)
        stream.flush()
        os.fsync(stream.fileno())
    part.replace(path)
    directory=os.open(path.parent,os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def save_json(path,value):
    encoded=(json.dumps(value,indent=2,allow_nan=False)+'\n').encode()
    write_atomic(path,lambda stream:stream.write(encoded))
