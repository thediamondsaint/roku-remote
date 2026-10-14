from pathlib import Path
import runpy
import unittest

viewer = runpy.run_path(str(Path(__file__).parents[1] / 'bin/roku-inventory'))


class ViewerDataTests(unittest.TestCase):
    def test_repeated_fields_and_attributes_are_preserved(self):
        node = {"tag": "player", "attributes": {"state": "play"}, "children": [
            {"tag": "track", "attributes": {"id": "1"}, "text": "English"},
            {"tag": "track", "attributes": {"id": "2"}, "text": "Spanish"}]}
        rows = viewer['flatten'](node)
        self.assertIn(('player / state', 'play'), rows)
        self.assertIn(('player / track', 'English'), rows)
        self.assertIn(('player / track', 'Spanish'), rows)
        self.assertIn(('player / track / id', '2'), rows)

    def test_invalid_report_is_rejected(self):
        for value in ({}, [None], [{'ip': 123}], [{'ip': '1', 'name': 'TV', 'queries': [], 'errors': {}}]):
            with self.assertRaises(ValueError):
                viewer['validate_report'](value)

    def test_empty_inventory_is_valid(self):
        self.assertEqual(viewer['validate_report']([]), [])
