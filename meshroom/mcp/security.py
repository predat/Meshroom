"""
Path checks for the MCP tools: every file they touch must resolve inside a configured root.
"""
import os


def isUnder(path: str, root: str) -> bool:
    """ Whether the canonical 'path' is 'root' or inside it. Both paths must already be canonical. """
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def resolveRoot(root: str) -> str:
    """ Canonical path of a configured root. Raise ValueError if it is not an absolute path to a folder. """
    if not os.path.isabs(root):
        raise ValueError(f"Root is not an absolute path: {root!r}")
    resolved = os.path.realpath(root)
    if not os.path.isdir(resolved):
        raise ValueError(f"Root is not an existing folder: {root!r}")
    return resolved


def resolveUnderRoot(root: str, relativePath: str) -> str:
    """
    Canonical path of 'relativePath' inside the canonical 'root'.
    Raise ValueError if it resolves outside of it: absolute path, '..', or symbolic link leading out.
    """
    if os.path.isabs(relativePath):
        raise ValueError(f"Expected a path relative to the root, got {relativePath!r}")
    path = os.path.realpath(os.path.join(root, relativePath))
    if not isUnder(path, root):
        raise ValueError(f"Path {relativePath!r} resolves outside of the root")
    return path
