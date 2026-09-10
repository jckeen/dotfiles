"""Capture a retired link before deleting it; preserve concurrent replacements.

The shell caller performs the initial eligibility checks. Directory handles
keep the mutation on those real directories if an ancestor is replaced. A
private quarantine makes validation apply to the captured entry, instead of
authorizing an unlink of whatever later occupies the original pathname.
"""

from contextlib import contextmanager
import os
import stat
import sys
import uuid


@contextmanager
def parent_directory(path):
    parts = path.split("/")
    if not path.startswith("/") or any(part in (".", "..") for part in parts) or not parts[-1]:
        raise ValueError("expected an absolute path without dot components")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = os.open("/", flags)
    try:
        for part in filter(None, parts[1:-1]):
            child = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        yield descriptor, parts[-1]
    finally:
        os.close(descriptor)


def bundle_absent(bundle):
    try:
        with parent_directory(bundle) as (parent, name):
            os.stat(name, dir_fd=parent, follow_symlinks=False)
        return False
    except FileNotFoundError:
        return True


def exact_link(parent, name, source):
    return stat.S_ISLNK(os.stat(name, dir_fd=parent, follow_symlinks=False).st_mode) and (
        os.readlink(name, dir_fd=parent) == source
    )


def retire(link, source, bundle):
    """Return 0 for removed, 1 for preserved, or 2 for a recovery diagnostic."""
    try:
        with parent_directory(link) as (parent, name):
            if not exact_link(parent, name, source) or not bundle_absent(bundle):
                return 1
            quarantine = ".retired-skill-" + uuid.uuid4().hex
            os.mkdir(quarantine, 0o700, dir_fd=parent)
            captured = False
            held = None
            try:
                held = os.open(quarantine, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                try:
                    os.rename(name, "entry", src_dir_fd=parent, dst_dir_fd=held)
                    captured = True
                    if exact_link(held, "entry", source) and bundle_absent(bundle):
                        os.unlink("entry", dir_fd=held)
                        return 0
                except OSError:
                    if not captured:
                        raise

                # linkat creates the old name only if absent. Unlike rename,
                # this cannot overwrite a second concurrent replacement. A
                # directory cannot be hard linked, so retain it for recovery.
                try:
                    os.link("entry", name, src_dir_fd=held, dst_dir_fd=parent, follow_symlinks=False)
                    os.unlink("entry", dir_fd=held)
                    return 1
                except OSError:
                    recovery = os.path.join(os.path.dirname(link), quarantine, "entry")
                    print(f"PRESERVED  concurrent replacement retained at {recovery!r}; restore it manually")
                    return 2
            finally:
                if held is not None:
                    os.close(held)
                # Never recursively clean a quarantine: it may hold user data.
                try:
                    os.rmdir(quarantine, dir_fd=parent)
                except OSError:
                    pass
    except (OSError, ValueError) as error:
        print(f"PRESERVED  {link!r}: retirement skipped ({error})")
        return 1


if __name__ == "__main__":
    sys.exit(retire(*sys.argv[1:]) if len(sys.argv) == 4 else 2)
