"""Read actual Mach-O deployment versions, including members of static archives."""
import subprocess


def verify_ios_deployment(binary, maximum="17.0"):
    output = subprocess.check_output(["xcrun", "otool", "-l", str(binary)], text=True)
    command = ""
    versions = []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        if fields[0] == "cmd":
            command = fields[1]
        elif fields[0] == "minos" or (
                fields[0] == "version" and command == "LC_VERSION_MIN_IPHONEOS"):
            versions.append(fields[1])
    if not versions:
        raise RuntimeError(f"No iOS deployment version found in {binary}")
    def version(value):
        return tuple((list(map(int, value.split("."))) + [0, 0])[:3])
    newer = sorted({v for v in versions if version(v) > version(maximum)})
    if newer:
        raise RuntimeError(f"{binary} requires iOS {', '.join(newer)}; maximum allowed is {maximum}")
    return sorted(set(versions))
