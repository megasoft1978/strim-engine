import unittest
from docmerge import parse, render
from docmerge.edit import move, replace
from docmerge.diff import content_diff
from docmerge.search import search
from docmerge.service import preview
from docmerge.stats import word_count


class DocumentTests(unittest.TestCase):
    def test_roundtrip_and_search(self):
        text = 'Intro\n# Alpha {#a}\nHello world\n# Beta {#b}\nSecond\n'
        document = parse(text)
        self.assertEqual(render(document), text)
        self.assertEqual([s.key for s in search(document, 'WORLD')], ['a'])
        self.assertEqual(word_count(document), 5)

    def test_duplicate_key_rejected(self):
        with self.assertRaises(ValueError):
            parse('# A {#x}\n# B {#x}\n')

    def test_edit_and_diff(self):
        original = parse('# A {#a}\nold\n# B {#b}\nbody\n')
        changed = replace(move(original, 'b', 'a'), 'a', body='new\n')
        self.assertEqual(changed.keys(), ('b', 'a'))
        self.assertIn('+new', content_diff(original, changed))

    def test_preview_clean(self):
        text = '# A {#a}\ntext\n'
        document, report = preview(text, text, text)
        self.assertEqual(document, text)
        self.assertEqual(report, 'Merge is clean.')
