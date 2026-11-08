"""Views use the design system, so the windows stay one product.

Raw sizes, radii and colours are how the app drifted into several looks. A new
screen should use the roles in DictatorDesignSystem.swift and the frames in
Views/DSComponents.swift. If a role is missing, add it there.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / "swift-client" / "Dictator"

# The foundation itself, and the one illustration with its own palette.
EXEMPT = {
    "DictatorDesignSystem.swift",
    "DSComponents.swift",
}
BRAND_FONT_FILES = {"BrandViews.swift", "SidebarView.swift"}
OWN_PALETTE = {"WalkieTalkieIndicatorView.swift"}

RULES = {
    "use a font role such as .dsBody": re.compile(
        r"\.font\(\.(system|caption2?|callout|headline|title[23]?|body|footnote|subheadline|largeTitle)\b"
    ),
    "use DSRadius": re.compile(r"cornerRadius: *[0-9]"),
    "use DSSpace": re.compile(r"\bspacing: *[1-9]|\.padding\((\.[a-zA-Z]+, *|\[[^\]]*\], *)?[1-9]"),
    "use a ds colour token": re.compile(
        r"Color\(red:|NSColor\.system|foreground(Style|Color)\(\.(secondary|primary|orange|red|green|blue|teal|purple|mint)\)"
    ),
    "use a DSButtonStyle": re.compile(r"buttonStyle\(\.(link|bordered|borderedProminent|borderless)\)"),
}


def view_files():
    for path in sorted(APP.rglob("*.swift")):
        if path.name in EXEMPT:
            continue
        text = path.read_text(encoding="utf-8")
        if "SwiftUI" in text and re.search(r":\s*View\b|ButtonStyle", text):
            yield path, text


class DesignTokenTests(unittest.TestCase):
    def test_views_use_the_design_system(self):
        problems = []
        for path, text in view_files():
            for number, line in enumerate(text.splitlines(), 1):
                code = line.split("//")[0]
                for advice, pattern in RULES.items():
                    if path.name in OWN_PALETTE and ("colour" in advice or "DSRadius" in advice):
                        continue
                    if pattern.search(code):
                        problems.append(f"{path.relative_to(ROOT)}:{number}: {advice}: {line.strip()}")
        self.assertEqual(problems, [], "\n" + "\n".join(problems))

    def test_brand_fonts_stay_in_the_brand_views(self):
        problems = []
        for path, text in view_files():
            if path.name not in BRAND_FONT_FILES and "DSFont." in text:
                problems.append(str(path.relative_to(ROOT)))
        self.assertEqual(problems, [])

    def test_every_sheet_uses_the_shared_frame(self):
        for path, text in view_files():
            self.assertNotIn("Form {", text, f"{path.name}: build forms from DSSheet and section cards")


if __name__ == "__main__":
    unittest.main()
