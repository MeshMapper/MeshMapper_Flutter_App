from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tool.store_screenshots import contact_sheet


def _touch(root: Path, rel: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"png")


class BuildHtmlTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        # Created out of name order on purpose.
        _touch(self.root, "ios-iphone-69/02_log.png")
        _touch(self.root, "ios-iphone-69/01_map.png")
        _touch(self.root, "android-phone/01_map.png")
        self.html = contact_sheet.build_html(self.root)

    def test_set_order_is_fixed(self) -> None:
        self.assertEqual(
            contact_sheet.SET_ORDER,
            ["ios-iphone-69", "ios-ipad-13", "watch-46", "android-phone"],
        )

    def test_names_every_set_in_order(self) -> None:
        positions = [self.html.index(name) for name in contact_sheet.SET_ORDER]
        self.assertEqual(positions, sorted(positions))

    def test_lists_iphone_files_in_name_order_with_relative_src(self) -> None:
        first = self.html.index('src="ios-iphone-69/01_map.png"')
        second = self.html.index('src="ios-iphone-69/02_log.png"')
        self.assertLess(first, second)
        self.assertNotIn(str(self.root), self.html)

    def test_marks_empty_sets_missing(self) -> None:
        self.assertEqual(self.html.count("missing"), 2)
        ipad = self.html.index("ios-ipad-13")
        watch = self.html.index("watch-46")
        android = self.html.index("android-phone")
        self.assertIn("missing", self.html[ipad:watch])
        self.assertIn("missing", self.html[watch:android])

    def test_present_sets_are_not_marked_missing(self) -> None:
        iphone = self.html.index("ios-iphone-69")
        ipad = self.html.index("ios-ipad-13")
        self.assertNotIn("missing", self.html[iphone:ipad])
        self.assertNotIn("missing", self.html[self.html.index("android-phone"):])


class MainTest(unittest.TestCase):
    def test_writes_contact_sheet_html(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _touch(root, "watch-46/01_map.png")
            out = contact_sheet.write_contact_sheet(root)
            self.assertEqual(out, root / "contact_sheet.html")
            self.assertIn('src="watch-46/01_map.png"', out.read_text())


if __name__ == "__main__":
    unittest.main()
