"""PyTorch reference for Swiftlight's EmbeddingGemma 2 inputs, built on the original HF checkpoint.

Host input assembly mirrors production source and runs through transformers' EmbeddingGemma2Model.
Numerical agreement with Core AI remains pending external replay. The study uses FP32, not Core AI's FP16:

- Text ids: the production tokenizer.json (same SHA-256 as the HF repo) with add_special_tokens and special-token
  parsing off, cut to `limit` as `HFTokenizer.tokenize` does: prefix(limit - 1) + [EOS].
- Image pixels: a port of `VisionHostPrep.target` / `resize` / `prepare` (integer antialiased bicubic, a = -0.5,
  sides multiples of 48, at most budget * 9 patches), then pixels / 255.
- Image sequence: `VisionHostPrep.compose`, i.e. [BOS, BOI, IMG x n, EOI, EOS] with the n soft tokens in IMG slots.
- Output: mean over every position, L2-normalized (`TextHostPrep.finalize`; ST Pooling(mean) + Normalize).

Mixed inputs have no production path; `mixed_ids` defines them (see REPORT.md).
"""
import math

import numpy as np

REVISION = '914f7f89142e33e77833254d9c9b90c3cef7303b'
CHECKPOINT_SHA256 = '197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79'
BOS, EOS, PAD = 2, 1, 0
BOI, IMG, EOI = 255999, 258880, 258882
QUERY_LIMIT, DOC_LIMIT = 512, 2048
MIN_PAGE_TEXT = 200   # IndexOptions.minPageText
PAGE_CHARS = 4000     # Indexer.pdf: String(page.text.prefix(4000))
PAGE_BUDGET = 280     # IndexOptions.pageBudget


def page_text(text):
    import regex
    return ''.join(regex.findall(r'\X', text)[:PAGE_CHARS])


def query_prompt(q):
    return f'task: search result | query: {q}'


def document_prompt(title, text):
    return f'title: {title if title else "none"} | text: {text}'


# ---------------------------------------------------------------- image prep (port of VisionHostPrep.swift)

def target_size(h, w, budget):
    if budget not in (70, 140, 280) or h <= 0 or w <= 0:
        raise ValueError(f'unsupported image dimensions/budget: {budget}')
    factor = math.sqrt(float(budget * 9 * 256) / float(h * w))
    th = int(math.floor(factor * h / 48)) * 48
    tw = int(math.floor(factor * w / 48)) * 48
    if th == 0 and tw == 0:
        raise ValueError('image too thin to embed')
    if th == 0:
        th, tw = 48, min((w // h) * 48, budget * 48)
    elif tw == 0:
        tw, th = 48, min((h // w) * 48, budget * 48)
    if th * tw > budget * 9 * 256:
        raise ValueError('image resize exceeds budget')
    return th, tw


def _coefficients(source, target):
    scale = source / target
    filter_scale = max(scale, 1.0)
    support = 2 * filter_scale
    rows, maximum = [], 0.0
    for i in range(target):
        center = scale * (i + 0.5)
        start = max(int(center - support + 0.5), 0)
        end = min(int(center + support + 0.5), source)
        weights = []
        for j in range(start, end):
            x = abs((j - center + 0.5) / filter_scale)
            weights.append(((1.5 * x - 2.5) * x) * x + 1 if x < 1 else
                           (((-0.5 * x + 2.5) * x - 4) * x + 2 if x < 2 else 0.0))
        total = sum(weights)
        if total != 0:
            weights = [v / total for v in weights]
        maximum = max(maximum, max(weights) if weights else 0.0)
        rows.append((start, weights))
    precision = 0
    while precision < 22:
        if int(0.5 + maximum * (1 << (precision + 1))) >= 32768:
            break
        precision += 1
    taps = max(len(w) for _, w in rows)
    index = np.zeros((target, taps), dtype=np.int64)
    weight = np.zeros((target, taps), dtype=np.int64)
    for i, (start, ws) in enumerate(rows):
        for k, v in enumerate(ws):
            index[i, k] = start + k
            weight[i, k] = int(v * (1 << precision) + (-0.5 if v < 0 else 0.5))
    return index, weight, precision


def _resample_axis(pixels, target, axis):
    """One pass of VisionHostPrep.resize along `axis` (1 = width, 0 = height) of an H x W x 3 uint8 array."""
    index, weight, q = _coefficients(pixels.shape[axis], target)
    src = pixels.astype(np.int64)
    acc = np.full(pixels.shape[:axis] + (target,) + pixels.shape[axis + 1:], 1 << (q - 1), dtype=np.int64)
    for k in range(index.shape[1]):
        gathered = np.take(src, index[:, k], axis=axis)
        w = weight[:, k].reshape((-1, 1, 1) if axis == 0 else (1, -1, 1))
        acc += gathered * w
    return np.clip(acc >> q, 0, 255).astype(np.uint8)


def resize(pixels, h, w):
    if pixels.shape[1] != w:
        pixels = _resample_axis(pixels, w, 1)
    if pixels.shape[0] != h:
        pixels = _resample_axis(pixels, h, 0)
    return pixels


def prepare_image(rgb, budget=PAGE_BUDGET):
    """rgb: H x W x 3 uint8. Returns (pixel_values [1, P, 768] float32, position_ids [1, P, 2] int64, n soft tokens,
    resized H x W x 3 uint8), in the patch order and padding transformers' Gemma4 vision tower expects."""
    th, tw = target_size(rgb.shape[0], rgb.shape[1], budget)
    resized = resize(np.ascontiguousarray(rgb), th, tw)
    p, ph, pw = budget * 9, th // 16, tw // 16
    valid = ph * pw
    patches = resized.reshape(ph, 16, pw, 16, 3).transpose(0, 2, 1, 3, 4).reshape(valid, 768)
    pixel_values = np.zeros((1, p, 768), dtype=np.float32)
    pixel_values[0, :valid] = patches.astype(np.float32) * np.float32(1.0 / 255.0)
    positions = np.full((1, p, 2), -1, dtype=np.int64)
    ys, xs = np.divmod(np.arange(valid), pw)
    positions[0, :valid, 0] = xs
    positions[0, :valid, 1] = ys
    return pixel_values, positions, valid // 9, resized


# ---------------------------------------------------------------- tokens

class Tokens:
    def __init__(self, tokenizer_json):
        from tokenizers import Tokenizer
        self.tok = Tokenizer.from_file(str(tokenizer_json))
        self.tok.no_truncation()
        self.tok.no_padding()
        self.tok.encode_special_tokens = True   # tok_encode(..., add=1, split=1)

    def encode(self, text, limit):
        ids = self.tok.encode(text, add_special_tokens=True).ids
        assert ids[0] == BOS and ids[-1] == EOS, 'tokenizer BOS/EOS contract changed'
        if len(ids) > limit:
            ids = ids[:limit - 1] + [EOS]
        return ids

    def bare(self, text):
        """Ids without BOS/EOS, for pieces of a mixed sequence."""
        return self.tok.encode(text, add_special_tokens=False).ids

    def query(self, q):
        return self.encode(query_prompt(q), QUERY_LIMIT)

    def document(self, title, text):
        return self.encode(document_prompt(title, page_text(text)), DOC_LIMIT)


def image_ids(n):
    return [BOS, BOI] + [IMG] * n + [EOI, EOS]


def mixed_ids(tokens, title, text, n, order):
    """One sequence for a page: the document prompt prefix, the page image and the page text.

    order 'image_text': BOS "title: T | text:" BOI IMG*n EOI " <text>" EOS
    order 'text_image': BOS "title: T | text: <text>" BOI IMG*n EOI EOS   (first piece = the T prompt exactly)
    order 'image_only': BOS "title: T | text:" BOI IMG*n EOI EOS
    The text is the same 4000-character page text the T vector sees; it is trimmed (from its end) so the whole
    sequence fits DOC_LIMIT tokens. Pieces are tokenized separately, as HF's EmbeddingGemma2Processor does when it
    splits a string around the image placeholder, e.g. "title: T | text:<|image|> <text>". Returns (ids, tokens
    of text trimmed)."""
    title = title if title else 'none'
    picture = [BOI] + [IMG] * n + [EOI]
    if order == 'image_only':
        return [BOS] + tokens.bare(f'title: {title} | text:') + picture + [EOS], 0
    if order == 'image_text':
        head = tokens.bare(f'title: {title} | text:')
        body = tokens.bare(' ' + page_text(text)) if text else []
        room = DOC_LIMIT - (2 + len(head) + len(picture))
        if room < 0:
            raise ValueError('title and image exceed mixed context')
        ids = [BOS] + head + picture + body[:room] + [EOS]
        trimmed = max(0, len(body) - room)
    elif order == 'text_image':
        body = tokens.bare(document_prompt(title, page_text(text)))
        room = DOC_LIMIT - (2 + len(picture))
        ids = [BOS] + body[:room] + picture + [EOS]
        trimmed = max(0, len(body) - room)
    else:
        raise ValueError(order)
    assert len(ids) <= DOC_LIMIT
    return ids, trimmed


# ---------------------------------------------------------------- model

def snapshot_dir():
    from guard import ROOT
    return ROOT / 'model'


class Reference:
    def __init__(self, device='cpu', threads=None, model=None, dtype='float32'):
        import torch
        from transformers import AutoConfig, AutoModel
        self.torch = torch
        if threads:
            torch.set_num_threads(threads)
        path = snapshot_dir()
        if model is None:
            config = AutoConfig.from_pretrained(path)
            config.audio_config = None   # text + image only (model card, "Selective Encoder Loading")
            model = AutoModel.from_pretrained(path, config=config, dtype=getattr(torch, dtype), local_files_only=True,
                                             attn_implementation='sdpa')
        self.model = model.to(device).eval()
        self.device = device
        self.tokens = Tokens(path / 'tokenizer.json')
        self.embed = self.model.get_input_embeddings()

    def soft_tokens(self, pixel_values, positions):
        """The n x 512 soft tokens the text tower receives for one image (vision tower + embed_vision)."""
        torch = self.torch
        with torch.inference_mode():
            out = self.model.get_image_features(torch.from_numpy(pixel_values).to(self.device, dtype=self.model.dtype),
                                                torch.from_numpy(positions).to(self.device), return_dict=True)
            return out.pooler_output[0].float()

    def run(self, ids, soft=None):
        """Mean-pooled, L2-normalized 768-d vector for one id sequence; IMG slots take `soft` in order."""
        torch = self.torch
        with torch.inference_mode():
            # Bound MPS graph shapes. Padding positions never enter attention keys or mean pooling.
            # The variable-length path can retain a separate graph for every page length on MPS.
            bucket = next(b for b in [128,256,512,1024,2048] if len(ids) <= b)
            t = torch.tensor([ids + [PAD] * (bucket-len(ids))], device=self.device)
            attention = torch.arange(bucket, device=self.device)[None, :] < len(ids)
            mask = t == IMG
            x = self.embed(torch.where(mask, PAD, t))
            if int(mask.sum()):
                assert soft is not None and soft.shape[0] == int(mask.sum()), 'soft tokens do not fill IMG slots'
                x = x.masked_scatter(mask.unsqueeze(-1), soft.to(x.device, dtype=x.dtype).reshape(-1))
            h = self.model.language_model(inputs_embeds=x, attention_mask=attention,
                                          return_dict=True).last_hidden_state[0, :len(ids)]
            v = h.float().mean(0)
            out = (v / v.norm()).cpu().numpy()
            if out.shape != (768,) or not np.isfinite(out).all():
                raise RuntimeError('invalid reference vector')
            return out
