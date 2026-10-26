#!/usr/bin/env python3
"""Malformed artifacts must not be accepted as a valid iOS candidate."""
import importlib.util
import plistlib
import struct
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('artifact', Path(__file__).resolve().parents[1] / 'Scripts/inspect-apple-artifact.py')
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


def image(commands, count=None, cpu=0x100000C, subtype=0):
    return struct.pack('<8I', 0xFEEDFACF, cpu, subtype, 2, len(commands) if count is None else count,
                       sum(map(len, commands)), 0, 0) + b''.join(commands)


class MachOTests(unittest.TestCase):
    def test_release_manifest_covers_document_picker_and_disk_checks(self):
        manifest = plistlib.loads((Path(__file__).resolve().parents[1] / 'App/PrivacyInfo.xcprivacy').read_bytes())
        self.assertEqual(artifact.privacy_errors(manifest), [])
        manifest['NSPrivacyAccessedAPITypes'] = [item for item in manifest['NSPrivacyAccessedAPITypes']
                                                if not item['NSPrivacyAccessedAPIType'].endswith('DiskSpace')]
        self.assertTrue(any('DiskSpace' in error for error in artifact.privacy_errors(manifest)))

    def test_device_and_simulator_are_distinguished(self):
        for platform in [2, 7]:
            data = image([struct.pack('<6I', 0x32, 24, platform, 17 << 16, (27 << 16) | (1 << 8), 0)])
            result = artifact.macho(data)
            self.assertEqual(result['platform'], platform)
            self.assertEqual(result['minimum_os'], [17, 0, 0])
            self.assertEqual(result['sdk'], [27, 1, 0])

    def test_uuid_matches_exact_bytes(self):
        data = image([struct.pack('<II', 0x1B, 24) + bytes(range(16))])
        self.assertEqual(artifact.macho(data)['uuid'], '00010203-0405-0607-0809-0a0b0c0d0e0f')

    def test_rejects_truncated_or_overlong_commands(self):
        for cmd in [struct.pack('<II', 0x32, 24), struct.pack('<II', 0x32, 0),
                    struct.pack('<4I', 0x32, 16, 2, 0)]:
            with self.assertRaises(ValueError):
                artifact.macho(image([cmd]))

    def test_rejects_wrong_architecture(self):
        for cpu, subtype in [(0x1000007, 0), (0x100000C, 2)]:
            with self.assertRaises(ValueError):
                artifact.macho(image([], cpu=cpu, subtype=subtype))

    def test_universal_binary_bounds(self):
        thin = image([])
        data = struct.pack('>7I', 0xCAFEBABE, 1, 0x100000C, 0, 32, len(thin), 4) + bytes(4) + thin
        self.assertEqual(artifact.macho(data)['architecture'], 'arm64')
        with self.assertRaises(ValueError):
            artifact.macho(data[:-1])

    def test_rejects_string_outside_dylib_command(self):
        with self.assertRaises(ValueError):
            artifact.macho(image([struct.pack('<6I', 0xC, 24, 24, 0, 0, 0)]))

    def test_signature_is_presence_evidence_only(self):
        data = image([struct.pack('<4I', 0x1D, 16, 48, 8)]) + bytes(8)
        self.assertTrue(artifact.macho(data)['code_signature_present'])
        self.assertFalse(artifact.macho(data[:-1])['code_signature_present'])


if __name__ == '__main__':
    unittest.main()
