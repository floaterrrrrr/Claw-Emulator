"""Configuration boundaries that matter for a public checkout and local signing."""
import importlib.util
import json
import os
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("distribution_config", ROOT / "Scripts/distribution_config.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class DistributionConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Distribution").mkdir()
        for name in ["ExportOptions.plist", "TestFlightUploadOptions.plist", "app-store-metadata.json"]:
            (self.root / "Distribution" / name).write_bytes((ROOT / "Distribution" / name).read_bytes())
        self.env = patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.paths = patch.multiple(config, ROOT=self.root, GENERATED=self.root / ".build-config")
        self.paths.start()
        self.addCleanup(self.paths.stop)

    def test_public_checkout_has_unsigned_defaults_and_refuses_signing(self):
        values = config.settings()
        self.assertEqual(values["CLAW_BUNDLE_ID"], "com.example.claw")
        config.generate(values)
        with self.assertRaises(ValueError):
            config.generate(values, require_signing=True)
        options = plistlib.loads((config.GENERATED / "ExportOptions.plist").read_bytes())
        self.assertNotIn("teamID", options)

    def test_local_values_precedence_and_private_generated_files(self):
        (self.root / ".env").write_text("CLAW_APPLE_TEAM_ID=ABCDE12345\nCLAW_BUNDLE_ID=org.example.first\n")
        (self.root / ".env.local").write_text("CLAW_BUNDLE_ID=org.example.second\n")
        os.environ["CLAW_BUNDLE_ID"] = "org.example.final"
        values = config.settings()
        config.generate(values, require_signing=True)
        generated = config.GENERATED / "app-store-metadata.json"
        self.assertEqual(json.loads(generated.read_text())["bundle_id"], "org.example.final")
        self.assertEqual(generated.stat().st_mode & 0o777, 0o600)
        options = plistlib.loads((config.GENERATED / "TestFlightUploadOptions.plist").read_bytes())
        self.assertEqual(options["teamID"], "ABCDE12345")
        self.assertEqual(options["destination"], "upload")

    def test_dotenv_never_evaluates_shell_code_and_override_is_isolated(self):
        alternate = self.root / "alternate.env"
        marker = self.root / "must-not-exist"
        value = f"$(touch {marker})"
        alternate.write_text(f"CLAW_DEVELOPER_DIR='{value}'\n")
        (self.root / ".env").write_text("CLAW_APPLE_TEAM_ID=ABCDE12345\n")
        os.environ["CLAW_ENV_FILE"] = str(alternate)
        values = config.settings()
        self.assertEqual(values["CLAW_DEVELOPER_DIR"], value)
        self.assertEqual(values["CLAW_APPLE_TEAM_ID"], "")
        self.assertFalse(marker.exists())

    def test_rejects_partial_api_auth_and_build_setting_injection(self):
        values = config.settings()
        values["CLAW_ASC_API_KEY_ID"] = "ABCDE12345"
        with self.assertRaises(ValueError):
            config.authentication(values)
        os.environ["CLAW_BUNDLE_ID"] = "org.example.claw\nOTHER_SETTING = value"
        with self.assertRaises(ValueError):
            config.settings()

    def test_api_auth_uses_a_file_path_without_embedding_key_material(self):
        key = self.root / "test-api-key.p8"
        key.write_text("synthetic-test-key-material")
        values = config.settings()
        values.update(CLAW_APPLE_TEAM_ID="ABCDE12345", CLAW_ASC_API_KEY_ID="ABCDE12345",
                      CLAW_ASC_API_ISSUER_ID="00000000-0000-0000-0000-000000000001",
                      CLAW_ASC_API_PRIVATE_KEY_PATH=str(key))
        flags = config.authentication(values)
        self.assertEqual(flags[:2], ["-authenticationKeyPath", str(key)])
        config.generate(values, require_signing=True)
        for output in config.GENERATED.iterdir():
            self.assertNotIn(key.read_bytes(), output.read_bytes())

    def test_cloud_uses_product_identity_and_ignores_local_dotenv(self):
        (self.root / ".env").write_text("CLAW_APPLE_TEAM_ID=WRONG12345\nCLAW_BUNDLE_ID=org.example.local\n")
        os.environ.update(CI_XCODE_CLOUD="TRUE", CI_TEAM_ID="ABCDE12345",
                          CI_BUNDLE_ID="org.example.cloud", CI_BUILD_NUMBER="26")
        values = config.settings()
        self.assertEqual(values["CLAW_APPLE_TEAM_ID"], "ABCDE12345")
        self.assertEqual(values["CLAW_BUNDLE_ID"], "org.example.cloud")
        self.assertEqual(config.metadata(values)["build"], "26")

    def test_encryption_is_not_assumed_when_unconfigured(self):
        info = {}
        self.assertIsNone(config.apply_encryption_declaration(info, config.settings()))
        self.assertNotIn("ITSAppUsesNonExemptEncryption", info)

    def test_committed_exemption_survives_local_and_cloud_archive_metadata(self):
        for cloud in (False, True):
            with self.subTest(cloud=cloud):
                os.environ["CI_XCODE_CLOUD"] = "TRUE" if cloud else "FALSE"
                info = plistlib.loads((ROOT / "App/Info.plist").read_bytes())
                self.assertIs(info["ITSAppUsesNonExemptEncryption"], False)
                info["CFBundleVersion"] = "104"
                info["ClawSourceCommit"] = "test-source-identity"
                self.assertIs(config.apply_encryption_declaration(info, config.settings()), False)
                archived = plistlib.loads(plistlib.dumps(info))
                self.assertIs(archived["ITSAppUsesNonExemptEncryption"], False)
                self.assertNotIn("ITSEncryptionExportComplianceCode", archived)

    def test_explicit_exemption_and_non_exemption_are_written_as_booleans(self):
        os.environ["CLAW_USES_NON_EXEMPT_ENCRYPTION"] = "false"
        info = {"ITSEncryptionExportComplianceCode": "old-code"}
        self.assertIs(config.apply_encryption_declaration(info, config.settings()), False)
        self.assertNotIn("ITSEncryptionExportComplianceCode", info)
        os.environ.update(CLAW_USES_NON_EXEMPT_ENCRYPTION="true",
                          CLAW_ENCRYPTION_EXPORT_COMPLIANCE_CODE="approved-test-code")
        self.assertIs(config.apply_encryption_declaration(info, config.settings()), True)
        self.assertEqual(info["ITSEncryptionExportComplianceCode"], "approved-test-code")

    def test_ambiguous_encryption_settings_are_rejected(self):
        os.environ["CLAW_USES_NON_EXEMPT_ENCRYPTION"] = "maybe"
        with self.assertRaises(ValueError):
            config.settings()
        os.environ.update(CLAW_USES_NON_EXEMPT_ENCRYPTION="false",
                          CLAW_ENCRYPTION_EXPORT_COMPLIANCE_CODE="unexpected-code")
        with self.assertRaises(ValueError):
            config.settings()


if __name__ == "__main__":
    unittest.main()
