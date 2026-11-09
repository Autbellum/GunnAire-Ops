import base64
import random
import unittest
from Backend.document_upload_encoding import decode_base64

class UploadEncodingTests(unittest.TestCase):
    def compare(self, text):
        try:expected=base64.b64decode(text,validate=True)
        except ValueError:
            with self.assertRaises(ValueError):decode_base64(text)
        else:self.assertEqual(decode_base64(text),expected)
    def test_canonical_chunk_boundaries_and_all_terminal_padding(self):
        for size in (0,1,2,3,49151,49152,49153,98304,98305):
            encoded=base64.b64encode(b'm'*size).decode()
            for suffix in ('','=','==','===','====','=A','\n','!'):
                with self.subTest(size=size,suffix=suffix):self.compare(encoded+suffix)
    def test_strict_invalid_and_noncanonical_padding_match_standard_library(self):
        for text in ('=','====','A','A===','AA=','AA===','AAA==','AAAA=','AAAA====','AAAA=AAAA','AA==AAAA','AAAA\n','é','\x00','AAAA'+'='*70000):self.compare(text)
        rng=random.Random(754)
        alphabet='ABab09+/= !\n\ré'
        for _ in range(3000):self.compare(''.join(rng.choice(alphabet) for _ in range(rng.randrange(20))))
