#!/usr/bin/env python3
"""The SideStore source written next to the testing .ipa points at that exact .ipa, by a stable URL."""
import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("sss", ROOT / "Tools/sidestore_source.py")
sss = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sss)


class SideStoreSourceTest(unittest.TestCase):
    def test_source_describes_the_uploaded_ipa(self):
        with tempfile.TemporaryDirectory() as tmp:
            ipa = pathlib.Path(tmp) / "NOOP-ios-unsigned-v11.9.0.ipa"
            ipa.write_bytes(b"x" * 1234)
            out = pathlib.Path(tmp) / "sidestore-source.json"
            sss.main(["sidestore_source.py", "--repo", "dviree/noopzone", "--tag", "testing-latest",
                      "--version", "11.9.0", "--build", "433", "--ipa", str(ipa),
                      "--date", "2026-10-04", "--out", str(out)])
            source = json.loads(out.read_text())

        self.assertEqual(source["sourceURL"],
                         "https://github.com/dviree/noopzone/releases/download/testing-latest/sidestore-source.json")
        app = source["apps"][0]
        self.assertEqual(app["bundleIdentifier"], "com.noopapp.noop")
        version = app["versions"][0]
        self.assertEqual(version["version"], "11.9.0")
        self.assertEqual(version["buildVersion"], "433")
        self.assertEqual(version["size"], 1234)
        self.assertEqual(version["date"], "2026-10-04")
        self.assertEqual(version["downloadURL"],
                         "https://github.com/dviree/noopzone/releases/download/testing-latest/"
                         "NOOP-ios-unsigned-v11.9.0.ipa")
        self.assertEqual(version["minOSVersion"], "17.0")


if __name__ == "__main__":
    unittest.main()
