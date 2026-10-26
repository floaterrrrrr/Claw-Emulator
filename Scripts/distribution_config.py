"""Load local distribution settings without executing dotenv contents as shell code."""
import argparse
import json
import os
import plistlib
import re
import shlex
import subprocess
import sys
from pathlib import Path
from uuid import UUID

ROOT = Path(__file__).resolve().parents[1]
GENERATED = ROOT / ".build-config"
DEFAULTS = {
    "CLAW_APPLE_TEAM_ID": "",
    "CLAW_BUNDLE_ID": "com.example.claw",
    "CLAW_ASC_APP_ID": "",
    "CLAW_DEVELOPER_DIR": "",
    "CLAW_ASC_API_KEY_ID": "",
    "CLAW_ASC_API_ISSUER_ID": "",
    "CLAW_ASC_API_PRIVATE_KEY_PATH": "",
    "CLAW_USES_NON_EXEMPT_ENCRYPTION": "",
    "CLAW_ENCRYPTION_EXPORT_COMPLIANCE_CODE": "",
}


def settings():
    values = DEFAULTS.copy()
    cloud = os.environ.get("CI_XCODE_CLOUD", "").upper() == "TRUE"
    if cloud:
        values["CLAW_APPLE_TEAM_ID"] = os.environ.get("CI_TEAM_ID", "")
        values["CLAW_BUNDLE_ID"] = os.environ.get("CI_BUNDLE_ID", "com.example.claw")
    override = os.environ.get("CLAW_ENV_FILE")
    files = [Path(override)] if override else [ROOT / ".env", ROOT / ".env.local"]
    if cloud:
        files = []  # Cloud uses workflow settings; never load a developer's dotenv.
    for path in files:
        if not path.exists():
            if override:
                raise ValueError("CLAW_ENV_FILE does not exist")
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].lstrip()
            key, separator, raw = line.partition("=")
            key = key.strip()
            if not separator or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
                raise ValueError(f"Invalid env assignment on line {number}")
            if key not in DEFAULTS:
                continue
            tokens = shlex.split(raw, comments=True, posix=True)
            if len(tokens) > 1:
                raise ValueError(f"Quote values containing spaces: {key}")
            values[key] = tokens[0] if tokens else ""
    values.update({key: os.environ[key] for key in DEFAULTS if key in os.environ})
    if values["CLAW_APPLE_TEAM_ID"] and not re.fullmatch(r"[A-Z0-9]{10}", values["CLAW_APPLE_TEAM_ID"]):
        raise ValueError("CLAW_APPLE_TEAM_ID must be a 10-character Apple team identifier")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", values["CLAW_BUNDLE_ID"]):
        raise ValueError("CLAW_BUNDLE_ID must be an explicit reverse-domain identifier")
    if values["CLAW_ASC_APP_ID"] and not values["CLAW_ASC_APP_ID"].isdigit():
        raise ValueError("CLAW_ASC_APP_ID must contain only digits")
    for key in DEFAULTS:
        if "\n" in values[key] or "\r" in values[key] or "\0" in values[key]:
            raise ValueError(f"Multiline values are not supported: {key}")
    declaration = values["CLAW_USES_NON_EXEMPT_ENCRYPTION"].lower()
    if declaration not in ("", "true", "false"):
        raise ValueError("CLAW_USES_NON_EXEMPT_ENCRYPTION must be true, false, or empty")
    if values["CLAW_ENCRYPTION_EXPORT_COMPLIANCE_CODE"] and declaration != "true":
        raise ValueError("An export compliance code requires CLAW_USES_NON_EXEMPT_ENCRYPTION=true")
    return values


def apply_encryption_declaration(info, values=None):
    """Apply an explicit owner decision; never infer an exemption from a build."""
    values = settings() if values is None else values
    declaration = values["CLAW_USES_NON_EXEMPT_ENCRYPTION"].lower()
    if declaration:
        info["ITSAppUsesNonExemptEncryption"] = declaration == "true"
        if declaration == "false":
            info.pop("ITSEncryptionExportComplianceCode", None)
        elif values["CLAW_ENCRYPTION_EXPORT_COMPLIANCE_CODE"]:
            info["ITSEncryptionExportComplianceCode"] = values["CLAW_ENCRYPTION_EXPORT_COMPLIANCE_CODE"]
    return info.get("ITSAppUsesNonExemptEncryption")


def metadata(values=None):
    values = values or settings()
    result = json.loads((ROOT / "Distribution/app-store-metadata.json").read_text())
    app_id = values["CLAW_ASC_APP_ID"]
    result.update(bundle_id=values["CLAW_BUNDLE_ID"], team_id=values["CLAW_APPLE_TEAM_ID"] or None,
                  app_store_connect_id=app_id or None,
                  app_store_connect_url=f"https://appstoreconnect.apple.com/apps/{app_id}/distribution" if app_id else None)
    if os.environ.get("CI_XCODE_CLOUD", "").upper() == "TRUE" and os.environ.get("CI_BUILD_NUMBER"):
        result["build"] = os.environ["CI_BUILD_NUMBER"]
    return result


def write_private(path, data):
    # Generated files contain local account identifiers, never private-key contents.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        os.fchmod(output.fileno(), 0o600)
        output.write(data)


def generate(values, require_signing=False):
    if require_signing and not values["CLAW_APPLE_TEAM_ID"]:
        raise ValueError("Set CLAW_APPLE_TEAM_ID in .env or the environment before signing/uploading")
    GENERATED.mkdir(mode=0o700, exist_ok=True)
    config = (f"CLAW_APPLE_TEAM_ID = {values['CLAW_APPLE_TEAM_ID']}\n"
              f"CLAW_BUNDLE_ID = {values['CLAW_BUNDLE_ID']}\n")
    write_private(GENERATED / "Signing.xcconfig", config.encode())
    for name in ["ExportOptions.plist", "TestFlightUploadOptions.plist"]:
        options = plistlib.loads((ROOT / "Distribution" / name).read_bytes())
        if values["CLAW_APPLE_TEAM_ID"]:
            options["teamID"] = values["CLAW_APPLE_TEAM_ID"]
        write_private(GENERATED / name, plistlib.dumps(options))
    write_private(GENERATED / "app-store-metadata.json", (json.dumps(metadata(values), indent=2) + "\n").encode())


def environment(values):
    result = dict(os.environ, **values, CLAW_ENV_LOADED="1")
    if values["CLAW_DEVELOPER_DIR"]:
        result["DEVELOPER_DIR"] = os.path.expanduser(values["CLAW_DEVELOPER_DIR"])
    return result


def authentication(values):
    keys = [values[key] for key in ["CLAW_ASC_API_KEY_ID", "CLAW_ASC_API_ISSUER_ID", "CLAW_ASC_API_PRIVATE_KEY_PATH"]]
    if not any(keys):
        return []
    if not all(keys):
        raise ValueError("Supply all three CLAW_ASC_API_* settings, or leave all empty to use Xcode Accounts")
    key_id, issuer, key_path = keys
    if not re.fullmatch(r"[A-Z0-9]{10}", key_id):
        raise ValueError("CLAW_ASC_API_KEY_ID must be a 10-character identifier")
    try:
        UUID(issuer)
    except ValueError:
        raise ValueError("CLAW_ASC_API_ISSUER_ID must be a UUID") from None
    key_path = Path(key_path).expanduser()
    if not key_path.is_absolute():
        key_path = ROOT / key_path
    if not key_path.is_file():
        raise ValueError("CLAW_ASC_API_PRIVATE_KEY_PATH does not exist")
    return ["-authenticationKeyPath", str(key_path), "-authenticationKeyID", key_id,
            "-authenticationKeyIssuerID", issuer]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["generate", "run", "xcodebuild"])
    parser.add_argument("--require-signing", action="store_true")
    args, command = parser.parse_known_args()
    if command[:1] == ["--"]:
        command = command[1:]
    values = settings()
    if args.command == "generate":
        if command:
            parser.error("Unexpected arguments for generate")
        generate(values, args.require_signing)
        print("Generated local distribution configuration in .build-config (ignored by Git).")
    elif args.command == "run":
        if not command:
            parser.error("run requires a command after --")
        os.execvpe(command[0], command, environment(values))
    else:
        raise SystemExit(subprocess.call(["xcodebuild", *command, *authentication(values)], env=environment(values)))


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        raise SystemExit(str(error)) from None
