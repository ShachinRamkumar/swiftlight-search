"""Steady-state model storage per option, in logical bytes. Reads installed host files and retained evidence; writes budget.json."""
import json
from pathlib import Path
here = Path(__file__).resolve().parent
research = here.parent
root = Path.home() / 'Library/Application Support/Swiftlight/CoreAI/coreai-eg2-v1'
DIGUP = 309_855_456 + 554_821_024

# Measured compiled caches (research/neural-engine-storage/full-runtime/REPORT.md, runtime/summary.json).
TEXT_FP16, VISION_FP16, AUDIO_FP16, BOOKMARKS = 283_495_256, 319_459_518, 615_712_483, 543
Q32_FP16, Q32_INT8 = 275_164_693, 138_939_186
# Unique weight bytes per modality (lossless-resource-statistics.json; cross-modal sharing measured as zero).
W_TEXT, W_VISION, W_AUDIO = 273_541_120, 304_054_272, 611_218_688
saving_per_weight_byte = (Q32_FP16 - Q32_INT8) / W_TEXT  # calibrated on the measured q32 INT8 compile
int8 = lambda fp16, w: round(fp16 - saving_per_weight_byte * w)

files = {str(p.relative_to(root)): p.stat().st_size for p in root.rglob('*') if p.is_file()}
host = {k: v for k, v in files.items() if '.aimodel/' not in k and not k.startswith('function-assets/')}
host_total = sum(host.values())
codecs = json.loads((here / 'host-table-codecs.json').read_text())
rope_total = sum(v for k, v in host.items() if k.startswith('rope-tables/') and k.endswith('.f16'))
rope_2048 = sum(v for k, v in host.items() if k.startswith('rope-tables/2048-'))
# Vision rows reachable from VisionHostPrep.target: at most 2520 patches with both sides multiples of 3 -> coordinates 0..839.
vision_rows = 840
pos_trim = 2 * vision_rows * 768 * 2
cos_trim = (vision_rows + 1) * 16 * 4
lossless_host = (host_total
    - host['token-table.bf16'] + codecs['token-table.bf16']['zstd19_planes_chunk64']['bytes']
    - host['tokenizer.json'] + codecs['tokenizer.json']['zstd19']
    - rope_total + rope_2048
    - host['vision-host/position-table.bf16'] + pos_trim
    - host['vision-host/cos.f32'] - host['vision-host/sin.f32'] + 2 * cos_trim)
TOKEN_INT8 = 134_742_016  # research/model-storage/EXPERIMENTS.md, row-wise INT8 incl. scales
int8_host = lossless_host - codecs['token-table.bf16']['zstd19_planes_chunk64']['bytes'] + TOKEN_INT8
text8, vision8, audio8 = int8(TEXT_FP16, W_TEXT), int8(VISION_FP16, W_VISION), int8(AUDIO_FP16, W_AUDIO)
options = {
    'today: split sources + compiled cache, audio not compiled (measured)': 3_007_235_098 + 1_456_859_337,
    'earlier best: merged text, source-free, all modalities, raw hosts (measured)': 1_565_079_618,
    'A: lossless text+image, audio downloaded only when enabled': TEXT_FP16 + VISION_FP16 + lossless_host + 2 * 181,
    'A + audio enabled at FP16': TEXT_FP16 + VISION_FP16 + AUDIO_FP16 + lossless_host + BOOKMARKS,
    'A + audio enabled at INT8 (audio estimate)': TEXT_FP16 + VISION_FP16 + audio8 + lossless_host + BOOKMARKS,
    'B: 8-bit everything, all modalities resident (vision/audio/merged estimates)': text8 + vision8 + audio8 + int8_host + BOOKMARKS,
    'C: lossless text+image, audio through macOS Speech + SoundAnalysis': TEXT_FP16 + VISION_FP16 + lossless_host + 2 * 181,
}
out = dict(digup_model_bytes=DIGUP, host_now=host_total, host_lossless=lossless_host, host_int8_token_table=int8_host,
           int8_estimates=dict(text_merged=text8, vision=vision8, audio=audio8, q32_measured=Q32_INT8,
                               saving_per_weight_byte=saving_per_weight_byte),
           unique_fp16_weight_bytes=W_TEXT + W_VISION + W_AUDIO,
           options={k: dict(bytes=v, vs_digup=v - DIGUP, ratio_to_digup=round(v / DIGUP, 3)) for k, v in options.items()},
           excluded=['OS-managed ANE artifacts (not readable)', 'Metal shader cache (107 MB measured for the indexer, OS-purgeable)',
                     'search index', 'app bundle', 'temporary download/compile peaks', 'macOS speech assets for option C'])
(here / 'budget.json').write_text(json.dumps(out, indent=1))
print(json.dumps(out, indent=1))
