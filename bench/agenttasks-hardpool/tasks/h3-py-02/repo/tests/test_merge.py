import unittest
from docmerge import Document, Section, merge
from docmerge.report import conflict_keys


def doc(*items):
    return Document(tuple(Section(k, k.upper(), body) for k, body in items))


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.base = doc(('a', 'A\n'), ('b', 'B\n'), ('c', 'C\n'), ('d', 'D\n'))

    def test_review_when_left_reorders_and_right_changes_text(self):
        left = doc(('d', 'D\n'), ('a', 'A\n'), ('b', 'B\n'), ('c', 'C\n'))
        right = doc(('a', 'A\n'), ('b', 'B\n'), ('c', 'C\n'), ('d', 'updated\n'))
        result = merge(self.base, left, right)
        self.assertEqual(conflict_keys(result), ('d',))
        self.assertEqual(result.conflicts[0].reason, 'move-edit')
        self.assertEqual(result.conflicts[0].base.body, 'D\n')
        self.assertEqual(result.conflicts[0].right.body, 'updated\n')
        self.assertEqual(result.document.by_key()['d'].body, 'D\n')

    def test_review_when_right_reorders_and_left_changes_title(self):
        right = doc(('d', 'D\n'), ('a', 'A\n'), ('b', 'B\n'), ('c', 'C\n'))
        left = Document(self.base.sections[:-1] + (Section('d', 'New title', 'D\n'),))
        result = merge(self.base, left, right)
        self.assertEqual(conflict_keys(result), ('d',))
        self.assertEqual(result.document.by_key()['d'].title, 'New title')

    def test_shifted_neighbors_and_insertions_are_not_moves(self):
        left = doc(('x', 'new\n'), ('d', 'D\n'), ('a', 'A\n'), ('b', 'B\n'), ('c', 'C\n'))
        right = doc(('a', 'changed\n'), ('b', 'B\n'), ('c', 'C\n'), ('d', 'D\n'))
        self.assertTrue(merge(self.base, left, right).clean)

    def test_deletions_do_not_make_survivors_move(self):
        left = doc(('b', 'B\n'), ('c', 'C\n'), ('d', 'D\n'))
        right = doc(('a', 'A\n'), ('b', 'changed\n'), ('c', 'C\n'), ('d', 'D\n'))
        self.assertTrue(merge(self.base, left, right).clean)

    def test_existing_content_conflict_is_not_duplicated(self):
        left = doc(('d', 'left\n'), ('a', 'A\n'), ('b', 'B\n'), ('c', 'C\n'))
        right = doc(('a', 'A\n'), ('b', 'B\n'), ('c', 'C\n'), ('d', 'right\n'))
        result = merge(self.base, left, right)
        self.assertEqual(conflict_keys(result), ('d',))
        self.assertEqual(result.conflicts[0].reason, 'content')

    def test_identical_edits_and_no_movement_are_clean(self):
        changed = doc(('a', 'changed\n'), ('b', 'B\n'), ('c', 'C\n'), ('d', 'D\n'))
        self.assertTrue(merge(self.base, changed, changed).clean)

    def test_ambiguous_swap_uses_documented_tie_break(self):
        base = doc(('a', 'A'), ('b', 'B'))
        left = doc(('b', 'B'), ('a', 'A'))
        right = doc(('a', 'changed'), ('b', 'B'))
        self.assertEqual(conflict_keys(merge(base, left, right)), ('a',))

    def test_a_deleted_section_still_uses_content_conflict(self):
        left = doc(('d', 'D\n'), ('a', 'A\n'), ('b', 'B\n'), ('c', 'C\n'))
        right = doc(('a', 'A\n'), ('b', 'B\n'), ('c', 'C\n'))
        result = merge(self.base, left, right)
        self.assertTrue(result.clean)
        self.assertNotIn('d', result.document.by_key())
