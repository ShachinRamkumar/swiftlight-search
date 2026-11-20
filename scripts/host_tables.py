"""Lossless packed host tables for the Core AI runtime, and their reference decoder.

Every file here decodes to bytes whose SHA-256 is pinned, so no model input changes. The Swift
decoder is vendor/DigUp/Sources/HostTableCodec; keep the two in step.

token-table.slht: a BF16 row table split into byte planes, one zstd frame per plane per chunk.
Little-endian throughout:

    0   8   magic b'SLHOST01'
    8   4   header bytes (64)
    12  4   element kind (1 = BF16)
    16  4   rows
    20  4   columns
    24  4   rows per chunk
    28  4   chunks: ceil(rows / rows per chunk)
    32  32  SHA-256 of the decoded table (rows x columns x 2 bytes, row-major)
    64  8 x (2 x chunks + 1)  frame offsets from the start of the file

Frame k spans [offset k, offset k+1). Frame 2c holds chunk c's high bytes (sign and seven exponent
bits) and frame 2c+1 its low bytes, both in row-major order: n x columns bytes for a chunk of n rows
(only the last chunk can be short). Frames are standard zstd frames with their content size and
XXH64 checksum. The file ends at the last offset. Row r lives in chunk r // rows-per-chunk.

tokenizer.json.zst: tokenizer.json as one zstd frame with content size and checksum.

rope-tables: only the four 2048-position tables. Every table is channel-major
([channels][positions]), and the s-position table equals the first s values of each channel row of
the 2048 one. rope-tables/sha256.json still pins all 28 derived tables.

vision-host/position-table-840.bf16, cos-841.f32, sin-841.f32: the rows VisionHostPrep can reach.
VisionHostPrep.target keeps at most budget x 48 = 13,440 pixels (840 patches) on a side, so patch
coordinates stop at 839. The position table [2][10240][768] keeps rows 0...839 of each axis
([2][840][768]); the RoPE tables [10241][16] keep rows 0...840 (row 0 is coordinate -1).

host-tables.json records each packed or derived file with its own SHA-256 and, where it decodes or
derives, the source's pinned SHA-256.
"""
import hashlib, json, os, struct
from compression import zstd
from pathlib import Path

MAGIC = b'SLHOST01'
HEADER = struct.Struct('<8sIIIIII32s')   # 64 bytes
BF16 = 1
FORMAT = 'swiftlight-host-tables-1'
TOKEN_ROWS, TOKEN_COLUMNS, CHUNK_ROWS, LEVEL = 262144, 512, 64, 19
ROPE_TABLES = {'local_cos': 256, 'local_sin': 256, 'global_cos': 512, 'global_sin': 512}
ROPE_BUCKETS = (32, 64, 128, 256, 512, 1024, 2048)
VISION_SOURCE_ROWS, VISION_ROWS, VISION_COLUMNS = 10240, 840, 768
VISION_ROPE_ROWS, VISION_ROPE_CHANNELS = VISION_ROWS + 1, 16
PACKED_NAMES = {'token-table.bf16': 'token-table.slht', 'tokenizer.json': 'tokenizer.json.zst',
                'vision-host/position-table.bf16': 'vision-host/position-table-840.bf16',
                'vision-host/cos.f32': 'vision-host/cos-841.f32', 'vision-host/sin.f32': 'vision-host/sin-841.f32'}

class FormatError(ValueError):
    pass

def sha256(data):
    return hashlib.sha256(data).hexdigest()

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''): h.update(block)
    return h.hexdigest()

def frame(data, level=LEVEL):
    return zstd.compress(data, options={zstd.CompressionParameter.compression_level: level,
                                        zstd.CompressionParameter.checksum_flag: 1,
                                        zstd.CompressionParameter.content_size_flag: 1})

def unframe(data, size):
    """One zstd frame of exactly `size` bytes; trailing bytes or a second frame are an error."""
    try:
        if zstd.get_frame_info(data).decompressed_size != size: raise FormatError('frame content size mismatch')
        decoder = zstd.ZstdDecompressor()
        out = decoder.decompress(data, max_length=size + 1)
        if not decoder.eof or decoder.unused_data: raise FormatError('frame length mismatch')
    except zstd.ZstdError as error: raise FormatError(f'zstd: {error}') from error
    if len(out) != size: raise FormatError('frame decoded to the wrong size')
    return out

def pack_rows(raw, rows, columns, out, chunk_rows=CHUNK_ROWS, level=LEVEL):
    """Writes the BF16 table `raw` (row-major, little-endian) to the open binary file `out`."""
    if not (1 <= rows <= TOKEN_ROWS and 1 <= columns <= TOKEN_COLUMNS and chunk_rows == CHUNK_ROWS):
        raise FormatError('unsupported table shape/chunk size')
    raw = memoryview(raw).cast('B')
    if len(raw) != rows * columns * 2: raise FormatError('table size does not match its shape')
    chunks = -(-rows // chunk_rows)
    index_at = HEADER.size
    offsets = [index_at + 8 * (2 * chunks + 1)]
    out.write(HEADER.pack(MAGIC, HEADER.size, BF16, rows, columns, chunk_rows, chunks, hashlib.sha256(raw).digest()))
    out.write(b'\0' * 8 * (2 * chunks + 1))
    for chunk in range(chunks):
        data = bytes(raw[chunk * chunk_rows * columns * 2:(chunk + 1) * chunk_rows * columns * 2])
        for plane in (data[1::2], data[0::2]):
            framed = frame(plane, level)
            out.write(framed)
            offsets.append(offsets[-1] + len(framed))
    out.seek(index_at)
    out.write(struct.pack(f'<{len(offsets)}Q', *offsets))
    out.seek(0, os.SEEK_END)
    return offsets[-1]

class PackedRows:
    """Reference reader for .slht files; the Swift PackedRowTable mirrors these checks."""
    def __init__(self, path):
        self.data = Path(path).read_bytes()
        if len(self.data) < HEADER.size: raise FormatError('file shorter than its header')
        magic, size, kind, self.rows, self.columns, self.chunk_rows, self.chunks, self.digest = HEADER.unpack_from(self.data)
        if magic != MAGIC or size != HEADER.size or kind != BF16: raise FormatError('not a BF16 host table')
        if not (1 <= self.rows <= TOKEN_ROWS and 1 <= self.columns <= TOKEN_COLUMNS and self.chunk_rows == CHUNK_ROWS) or self.chunks != -(-self.rows // self.chunk_rows):
            raise FormatError('inconsistent table shape')
        count = 2 * self.chunks + 1
        if len(self.data) < HEADER.size + 8 * count: raise FormatError('file shorter than its frame index')
        self.offsets = struct.unpack_from(f'<{count}Q', self.data, HEADER.size)
        if self.offsets[0] != HEADER.size + 8 * count or self.offsets[-1] != len(self.data) \
           or any(b <= a for a, b in zip(self.offsets, self.offsets[1:])):
            raise FormatError('frame offsets out of order or outside the file')

    def chunk(self, index):
        """Chunk `index` as row-major little-endian BF16 bytes."""
        if not 0 <= index < self.chunks: raise FormatError('chunk out of range')
        n = min(self.chunk_rows, self.rows - index * self.chunk_rows) * self.columns
        hi = unframe(self.data[self.offsets[2 * index]:self.offsets[2 * index + 1]], n)
        lo = unframe(self.data[self.offsets[2 * index + 1]:self.offsets[2 * index + 2]], n)
        out = bytearray(2 * n)
        out[0::2], out[1::2] = lo, hi
        return bytes(out)

    def row(self, index):
        if not 0 <= index < self.rows: raise FormatError('row out of range')
        chunk, offset = divmod(index, self.chunk_rows)
        return self.chunk(chunk)[offset * self.columns * 2:(offset + 1) * self.columns * 2]

    def decode(self, verify=True):
        out = b''.join(self.chunk(c) for c in range(self.chunks))
        if verify and hashlib.sha256(out).digest() != self.digest: raise FormatError('decoded SHA-256 mismatch')
        return out

def rope_prefix(table, channels, positions, source_positions=2048):
    """The `positions`-position RoPE table from the channel-major `source_positions` one."""
    if len(table) != channels * source_positions * 2 or not 0 < positions <= source_positions:
        raise FormatError('RoPE table shape mismatch')
    width = positions * 2
    return b''.join(table[c * source_positions * 2:c * source_positions * 2 + width] for c in range(channels))

def row_prefix(table, axes, source_rows, rows, row_bytes):
    """The first `rows` rows of each of `axes` stacked tables of `source_rows` rows."""
    if len(table) != axes * source_rows * row_bytes or not 0 < rows <= source_rows: raise FormatError('table shape mismatch')
    return b''.join(table[a * source_rows * row_bytes:(a * source_rows + rows) * row_bytes] for a in range(axes))

def vision_reach(budget):
    """Largest patch coordinate VisionHostPrep.target can produce for `budget`, over every image shape."""
    # th or tw is 48 for the thinnest images: the other side is min((long // short) * 48, budget * 48).
    # Otherwise th * tw <= budget * 9 * 256 with both at least 48, so neither side exceeds budget * 48.
    return budget * 48 // 16 - 1

def write_atomic(path, data):
    temporary = path.with_name('.' + path.name + '.writing')
    with temporary.open('xb') as f:
        f.write(data); f.flush(); os.fsync(f.fileno())
    os.replace(temporary, path)

def pack(source, out, pinned, rope_hashes, vision_files):
    """Packs a verified runtime's host tables from `source` into the new folder `out`.

    `pinned` maps token-table.bf16 and tokenizer.json to SHA-256s, `rope_hashes` is
    rope-tables/sha256.json's content, and `vision_files` the vision host identity's file hashes.
    Every source is hashed first and every output decoded again before it is recorded."""
    source, out = Path(source), Path(out)
    for name, expected in [('token-table.bf16', pinned['token-table.bf16']), ('tokenizer.json', pinned['tokenizer.json'])] \
            + [('rope-tables/' + n, h) for n, h in rope_hashes.items() if n.startswith('2048-')] \
            + [('vision-host/' + n, h) for n, h in vision_files.items()]:
        if sha256_file(source / name) != expected: raise FormatError('source SHA-256 mismatch: ' + name)
    for folder in ('rope-tables', 'vision-host'): (out / folder).mkdir(parents=True, exist_ok=True)
    files, derived = {}, {}
    def record(name, **fields):
        files[name] = dict(sha256=sha256_file(out / name), bytes=(out / name).stat().st_size, **fields)

    table = out / PACKED_NAMES['token-table.bf16']
    with (source / 'token-table.bf16').open('rb') as f, table.open('xb') as w:
        pack_rows(f.read(), TOKEN_ROWS, TOKEN_COLUMNS, w)
    if sha256(PackedRows(table).decode()) != pinned['token-table.bf16']: raise FormatError('token table round trip failed')
    record('token-table.slht', kind='bf16-planes-zstd', decodes_to='token-table.bf16', decoded_sha256=pinned['token-table.bf16'],
           decoded_bytes=TOKEN_ROWS * TOKEN_COLUMNS * 2, rows=TOKEN_ROWS, columns=TOKEN_COLUMNS, chunk_rows=CHUNK_ROWS, zstd_level=LEVEL)

    text = (source / 'tokenizer.json').read_bytes()
    write_atomic(out / 'tokenizer.json.zst', frame(text))
    if sha256(unframe((out / 'tokenizer.json.zst').read_bytes(), len(text))) != pinned['tokenizer.json']:
        raise FormatError('tokenizer round trip failed')
    record('tokenizer.json.zst', kind='zstd', decodes_to='tokenizer.json', decoded_sha256=pinned['tokenizer.json'], decoded_bytes=len(text))

    for name, channels in ROPE_TABLES.items():
        big = (source / f'rope-tables/2048-{name}.f16').read_bytes()
        write_atomic(out / f'rope-tables/2048-{name}.f16', big)
        record(f'rope-tables/2048-{name}.f16', kind='copy')
        for s in ROPE_BUCKETS[:-1]:
            file = f'{s}-{name}.f16'
            digest = sha256(rope_prefix(big, channels, s))
            if digest != rope_hashes[file]: raise FormatError('RoPE prefix differs from its pinned table: ' + file)
            derived['rope-tables/' + file] = dict(kind='channel-prefix', source=f'rope-tables/2048-{name}.f16',
                                                  channels=channels, positions=s, sha256=digest)
    write_atomic(out / 'rope-tables/sha256.json', (source / 'rope-tables/sha256.json').read_bytes())
    record('rope-tables/sha256.json', kind='copy')

    if max(vision_reach(b) for b in (70, 140, 280)) != VISION_ROWS - 1: raise FormatError('vision reach changed')
    for name, axes, rows, kept, row_bytes in [('position-table.bf16', 2, VISION_SOURCE_ROWS, VISION_ROWS, VISION_COLUMNS * 2),
                                              ('cos.f32', 1, VISION_SOURCE_ROWS + 1, VISION_ROPE_ROWS, VISION_ROPE_CHANNELS * 4),
                                              ('sin.f32', 1, VISION_SOURCE_ROWS + 1, VISION_ROPE_ROWS, VISION_ROPE_CHANNELS * 4)]:
        target = PACKED_NAMES['vision-host/' + name]
        write_atomic(out / target, row_prefix((source / 'vision-host' / name).read_bytes(), axes, rows, kept, row_bytes))
        record(target, kind='row-prefix', source='vision-host/' + name, source_sha256=vision_files[name],
               axes=axes, source_rows=rows, rows=kept, row_bytes=row_bytes)
    write_atomic(out / 'vision-host/identity.json', (source / 'vision-host/identity.json').read_bytes())
    record('vision-host/identity.json', kind='copy')

    record_json = dict(format=FORMAT, files=dict(sorted(files.items())), derived=dict(sorted(derived.items())))
    write_atomic(out / 'host-tables.json', (json.dumps(record_json, indent=1, sort_keys=True) + '\n').encode())
    return record_json

def verify(folder, record, pinned, rope_hashes):
    """Decodes every packed file in `folder` again and checks it against `record` and the pins."""
    folder = Path(folder)
    for name, entry in record['files'].items():
        if sha256_file(folder / name) != entry['sha256']: raise FormatError('packed SHA-256 mismatch: ' + name)
    if sha256(PackedRows(folder / 'token-table.slht').decode()) != pinned['token-table.bf16']: raise FormatError('token table')
    entry = record['files']['tokenizer.json.zst']
    if sha256(unframe((folder / 'tokenizer.json.zst').read_bytes(), entry['decoded_bytes'])) != pinned['tokenizer.json']:
        raise FormatError('tokenizer')
    for name, entry in record['derived'].items():
        big = (folder / entry['source']).read_bytes()
        if sha256(rope_prefix(big, entry['channels'], entry['positions'])) != rope_hashes[name.split('/', 1)[1]]:
            raise FormatError('RoPE prefix: ' + name)
