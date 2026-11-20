"""Check shipped artifacts without opening an index or preparing a Core AI model."""
from pathlib import Path
import os
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'build.noindex/Swiftlight.app'
HELPER = APP / 'Contents/Helpers/Swiftlight Indexer'


@unittest.skipUnless(HELPER.exists() and (ROOT / 'vendor/DigUp/.build/release/coreai-check').exists(),
                     'checks shipped products; run ./build.sh first')
class CoreAIProductTests(unittest.TestCase):
    def test_llama_selection_is_rejected_before_runtime_loading(self):
        for command in ['worker', 'index-service']:
            with self.subTest(command=command):
                result = subprocess.run(
                    [str(HELPER), command, '--engine', 'llama'],
                    capture_output=True, text=True, timeout=10,
                    env={k: v for k, v in os.environ.items() if not k.startswith('DIGUP_')},
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn('supports only --engine coreai', result.stderr)
                self.assertNotIn('ready', result.stdout)

    def test_legacy_commands_are_unavailable(self):
        for command in ['download-model', 'coreai-rollback', 'search-service', 'index-selected']:
            with self.subTest(command=command):
                result = subprocess.run([str(HELPER), command], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2)

    def test_products_do_not_link_llama_or_ggml(self):
        products = [HELPER, ROOT / 'vendor/DigUp/.build/release/coreai-check']
        for product in products:
            with self.subTest(product=product.name):
                symbols = subprocess.check_output(['nm', '-a', str(product)], text=True)
                libraries = subprocess.check_output(['otool', '-L', str(product)], text=True)
                self.assertIsNone(re.search(r'llama|ggml', symbols + libraries, re.I))
        symbols = subprocess.check_output(['nm', '-a', str(HELPER)], text=True)
        self.assertIn('_jpeg_read_header', symbols)
        self.assertIn('_tok_load', symbols)
        libraries = subprocess.check_output(['otool', '-L', str(HELPER)], text=True)
        self.assertIn('PDFKit.framework', libraries)
        self.assertFalse((APP / 'Contents/Resources/llama.cpp-LICENSE.txt').exists())


if __name__ == '__main__':
    unittest.main()
