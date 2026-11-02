#!/usr/bin/env python
"""
Make the QtAliceVision plugins of the macOS app bundle load the bundled AliceVision and Qt,
then check that every library of AliceVision and QtAliceVision resolves inside the bundle.

Usage: python macos_bundle.py <Meshroom.app/Contents/MacOS>
"""

import os
import subprocess
import sys
from functools import lru_cache
from pathlib import Path

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")
LOAD_COMMANDS = {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB"}
MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"}  # thin 64-bit, universal


def isMachO(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    with open(path, "rb") as f:
        return f.read(4) in MACHO_MAGICS


@lru_cache(maxsize=None)
def loadCommands(path: Path) -> tuple[list[str], list[str]]:
    """
    Read the libraries loaded by a Mach-O file and its rpaths.

    Returns:
        The library install names and the rpaths, as written in the load commands.
    """
    output = subprocess.run(["otool", "-l", str(path)], check=True, capture_output=True, text=True).stdout
    loads, rpaths = [], []
    cmd = None
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("cmd "):
            cmd = line.removeprefix("cmd ")
        elif line.startswith("name ") and cmd in LOAD_COMMANDS:
            loads.append(line.removeprefix("name ").rsplit(" (offset", 1)[0])
        elif line.startswith("path ") and cmd == "LC_RPATH":
            rpaths.append(line.removeprefix("path ").rsplit(" (offset", 1)[0])
    return loads, rpaths


def isSystem(name: str) -> bool:
    return name.startswith(SYSTEM_PREFIXES)


def bundledName(name: str) -> str:
    """ Path of a library relative to a lib folder: from the framework folder for a framework, the file name otherwise. """
    parts = Path(name).parts
    for i, part in enumerate(parts):
        if part.endswith(".framework"):
            return str(Path(*parts[i:]))
    return parts[-1]


def fixupQtPlugins(rootDir: Path):
    """
    Point the libraries of the QtAliceVision plugins to their copy in the bundle:
    AliceVision and its dependencies through an rpath to aliceVision/lib, and Qt to the
    binaries cx_Freeze copied (it flattens the frameworks), with @executable_path like it does.
    """
    avLibDir = rootDir / "aliceVision" / "lib"
    qtBinaries = {p.name: p for p in (rootDir / "lib").rglob("Qt*") if isMachO(p)}
    for plugin in sorted(p for p in (rootDir / "qtPlugins").rglob("*") if isMachO(p)):
        loads, rpaths = loadCommands(plugin)
        args = []
        for name in loads:
            if isSystem(name):
                continue
            if (avLibDir / bundledName(name)).exists():
                newName = f"@rpath/{bundledName(name)}"
            elif Path(name).name in qtBinaries:
                newName = f"@executable_path/{qtBinaries[Path(name).name].relative_to(rootDir)}"
            else:
                continue  # Reported by the check
            if newName != name:
                args += ["-change", name, newName]
        for rpath in rpaths:
            args += ["-delete_rpath", rpath]
        args += ["-add_rpath", f"@loader_path/{os.path.relpath(avLibDir, plugin.parent)}"]
        print(f"{plugin.relative_to(rootDir)}: {' '.join(args)}")
        subprocess.run(["install_name_tool", *args, str(plugin)], check=True)
        # Modifying a binary invalidates its signature, mandatory on Apple Silicon
        subprocess.run(["codesign", "--force", "--sign", "-", str(plugin)], check=True)
    loadCommands.cache_clear()


def expand(path: str, image: Path, executable: Path) -> Path:
    """ Replace @loader_path and @executable_path in a library or rpath of the image. """
    prefix, _, rest = path.partition("/")
    base = {"@loader_path": image.parent, "@executable_path": executable.parent}.get(prefix)
    if base is None:
        return Path(path)
    return base / rest if rest else base


def checkBundle(rootDir: Path, appDir: Path) -> list[str]:
    """
    Resolve the libraries the way dyld does, from the binaries loaded by Meshroom
    (QtAliceVision plugins, AliceVision Python modules) and the AliceVision executables.
    @rpath is searched in the rpaths of the image, then of the images that loaded it.

    Returns:
        The errors: libraries not found in the bundle, or loaded from an absolute path.
    """
    meshroom = rootDir / "Meshroom"
    avDir = rootDir / "aliceVision"
    roots = [(p, meshroom) for p in (rootDir / "qtPlugins").rglob("*") if isMachO(p)]
    roots += [(p, meshroom) for p in avDir.rglob("*.so") if isMachO(p)]
    roots += [(p, p) for p in (avDir / "bin").iterdir() if isMachO(p)]
    errors = set()

    def resolve(name: str, stack: list[Path], executable: Path):
        if name.startswith("@rpath/"):
            for image in stack:
                for rpath in loadCommands(image)[1]:
                    candidate = expand(rpath, image, executable) / name.removeprefix("@rpath/")
                    if candidate.exists():
                        return candidate
            return None
        candidate = expand(name, stack[0], executable)
        return candidate if candidate.exists() else None

    for root, executable in roots:
        # The main executable rpaths are searched too for the binaries it loads
        stack = [root] if root == executable else [root, executable]
        seen = {root.resolve()}
        queue = [stack]
        while queue:
            stack = queue.pop()
            image = stack[0]
            loads, rpaths = loadCommands(image)
            where = image.relative_to(appDir) if image.is_relative_to(appDir) else image
            for rpath in rpaths:
                if rpath.startswith("/"):
                    errors.add(f"{where}: absolute rpath {rpath}")
            for name in loads:
                if isSystem(name):
                    continue
                if name.startswith("/"):
                    errors.add(f"{where}: loads the absolute path {name}")
                    continue
                target = resolve(name, stack, executable)
                if target is None:
                    errors.add(f"{where}: {name} not found")
                    continue
                target = target.resolve()
                if not target.is_relative_to(appDir):
                    errors.add(f"{where}: {name} resolves outside the bundle, to {target}")
                elif target not in seen:
                    seen.add(target)
                    queue.append([target] + stack)
    return sorted(errors)


def main():
    rootDir = Path(sys.argv[1]).resolve()
    appDir = rootDir.parents[1]  # Meshroom.app
    fixupQtPlugins(rootDir)
    errors = checkBundle(rootDir, appDir)
    for error in errors:
        print(f"::error::{error}")
    print(f"{len(errors)} error(s)")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
