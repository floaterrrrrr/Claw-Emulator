#!/usr/bin/env python3
"""Validate the canonical Claw project, bridge and public source layout."""
import importlib.util
import json
from pathlib import Path
import re
import sys
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Scripts'))
spec = importlib.util.spec_from_file_location('public_export', ROOT / 'Scripts/export-public-source.py')
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class ReleaseLayoutTests(unittest.TestCase):
    def test_canonical_project_and_scheme_build_claw(self):
        project = (ROOT / 'Claw.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        scheme = ET.parse(ROOT / 'Claw.xcodeproj/xcshareddata/xcschemes/Claw.xcscheme')
        targets = scheme.findall('.//BuildableReference')
        self.assertTrue(targets)
        for target in targets:
            self.assertEqual(target.attrib['BuildableName'], 'Claw.app')
            self.assertEqual(target.attrib['BlueprintName'], 'Claw')
            self.assertEqual(target.attrib['ReferencedContainer'], 'container:Claw.xcodeproj')
            self.assertIn(target.attrib['BlueprintIdentifier'], project)
        self.assertIn('Native/ClawCore.h', project)
        self.assertIn('"NDEBUG=1"', project)

    def test_native_and_frontend_bridge_names_agree(self):
        header = (ROOT / 'Native/ClawCore.h').read_text(encoding='utf-8')
        bridge = (ROOT / 'Native/ClawCore.mm').read_text(encoding='utf-8')
        frontend = (ROOT / 'App/GameEngine.swift').read_text(encoding='utf-8')
        for symbol in ['Claw3DSLoad', 'Claw3DSStop', 'Claw3DSSetSpeed']:
            self.assertIn(symbol, header)
            self.assertIn(symbol, bridge)
            self.assertIn(symbol, frontend)

    def test_public_export_excludes_history_but_keeps_build_inputs_and_licenses(self):
        for path in ['Docs/Archive/BUILD21.md', 'Validation/build.log', '.github/workflows/main.yml',
                     'ThirdParty/Dependencies/FFmpeg/libavcodec.xcframework/file',
                     'PrivateCompatibility.xcodeproj/project.pbxproj']:
            self.assertTrue(exporter.excluded_path(path), path)
        for path in ['README.md', 'LICENSE', 'Claw.xcodeproj/project.pbxproj',
                     'Native/ClawCore.mm', 'Distribution/header-sources.json',
                     'ThirdParty/Cytrus/license.txt', 'App/Legal/DependencyLicenses.txt']:
            self.assertFalse(exporter.excluded_path(path), path)

    def test_release_defaults_to_verified_source_pipeline(self):
        policy = json.loads((ROOT / 'Distribution/ffmpeg-build-policy.json').read_text())
        self.assertEqual(policy['mode'], 'source')
        self.assertTrue(policy['release_candidate'])


if __name__ == '__main__':
    unittest.main()
