"""Copy llama-server and its non-system dependencies into a relocatable app bundle."""

from pathlib import Path
import re
import subprocess
import sys


def output(*command):
    return subprocess.check_output(command, text=True)


def dependencies(binary):
    return [line.strip().split(" (compatibility", 1)[0]
            for line in output("otool", "-L", str(binary)).splitlines()[1:]]


def rpaths(binary):
    return re.findall(r"cmd LC_RPATH\n.*?\n\s*path (.*?) \(offset",
                      output("otool", "-l", str(binary)))


def bundle(source, app):
    source = source.resolve()
    executable = app / "Contents/MacOS/llama-server"
    library_dir = app / "Contents/lib"
    library_dir.mkdir(parents=True, exist_ok=True)
    pending = [(source, executable)]
    copied = {}

    def expand(path, loader):
        return Path(path.replace("@loader_path", str(loader.parent))
                    .replace("@executable_path", str(source.parent)))

    def resolve(name, loader):
        if name.startswith("@rpath/"):
            relative = name[len("@rpath/"):]
            candidates = [expand(path, loader) / relative for path in rpaths(loader)]
            candidates += [loader.parent / relative, source.parent.parent / "lib" / relative]
        else:
            candidates = [expand(name, loader)]
        for candidate in candidates:
            if candidate.is_file():
                return candidate.resolve()
        raise RuntimeError(f"Cannot bundle dependency {name} used by {loader}")

    while pending:
        original, destination = pending.pop(0)
        if destination in copied:
            if copied[destination] != original:
                raise RuntimeError(f"Conflicting libraries named {destination.name}")
            continue
        copied[destination] = original
        destination.unlink(missing_ok=True)
        subprocess.run(["cp", "-X", str(original), str(destination)], check=True)
        changes = []
        for name in dependencies(original):
            if name.startswith(("/System/Library/", "/usr/lib/")):
                continue
            dependency = resolve(name, original)
            if dependency == original:  # A dylib's own install name.
                continue
            target = library_dir / Path(name).name
            pending.append((dependency, target))
            relative = ("@executable_path/../lib/" if destination == executable else "@loader_path/") + target.name
            changes += ["-change", name, relative]
        if original.name.startswith("libggml."):
            for pattern in ("libggml-metal*.dylib", "libggml-cpu*.dylib", "libggml-blas*.dylib"):
                for backend in original.parent.glob(pattern):
                    resolved = backend.resolve()
                    if resolved not in copied.values() and not any(item[0] == resolved for item in pending):
                        pending.append((resolved, library_dir / backend.name))
        if destination != executable:
            changes += ["-id", "@rpath/" + destination.name]
        desired_rpath = "@executable_path/../lib" if destination == executable else "@loader_path"
        original_rpaths = rpaths(original)
        for path in dict.fromkeys(original_rpaths):
            if path != desired_rpath:
                changes += ["-delete_rpath", path]
        if desired_rpath not in original_rpaths:
            changes += ["-add_rpath", desired_rpath]
        subprocess.run(["install_name_tool", *changes, str(destination)], check=True, capture_output=True)

    for destination in copied:
        if any(name.startswith(("/opt/", "/usr/local/")) for name in dependencies(destination)):
            raise RuntimeError(f"Unbundled dependency remains in {destination}")
    print(f"Embedded llama-server and {len(copied) - 1} libraries.")


if __name__ == "__main__":
    bundle(Path(sys.argv[1]), Path(sys.argv[2]))
