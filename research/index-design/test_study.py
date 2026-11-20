#!/usr/bin/env python3
import random
import unittest
from study import pack,unpack,reference_pack,recover


class TextCodecTests(unittest.TestCase):
    def test_raw_compressed_empty_and_null(self):
        for text in (None,'','abc','repeated words '*1000,'\u0000\u2126 café বাংলা العربية'):
            self.assertEqual(unpack(pack(text)),text)

    def test_prompt_keeps_original_title_and_exact_body_bytes(self):
        raw='café\u2126 বাংলা العربية'
        value='title: Original title | text: '+raw
        sources=('',raw,None)
        encoded=reference_pack(value,sources)
        self.assertEqual(recover(encoded,*(pack(x) for x in sources)),value)

    def test_multibyte_slice_offset_and_excerpt_suffix(self):
        source='before বাংলা café Ω after'*30
        for excerpt in (source[7:60],source[:100]+'…',source[:100]+'...'):
            candidates=(None,source,None)
            encoded=reference_pack(excerpt,candidates)
            self.assertEqual(recover(encoded,*(pack(x) for x in candidates)),excerpt)

    def test_normalized_text_cannot_replace_original_bytes(self):
        text='title: old | text: \u2126'*40
        candidates=('',text.replace('\u2126','Ω'),None)
        encoded=reference_pack(text,candidates)
        self.assertEqual(recover(encoded,*(pack(x) for x in candidates)),text)

    def test_generated_unicode_reference_roundtrips(self):
        rng=random.Random(519)
        for _ in range(500):
            source=''.join(rng.choice('ab éΩ\u2126বাংলাالعربية\u0000') for _ in range(1000))
            start=rng.randrange(500)
            part=source[start:start+400]
            for value in (part,part+'…','title: retained | text: '+part):
                candidates=(None,source,None)
                encoded=reference_pack(value,candidates)
                self.assertEqual(recover(encoded,*(pack(x) for x in candidates)),value)


if __name__=='__main__':unittest.main()
