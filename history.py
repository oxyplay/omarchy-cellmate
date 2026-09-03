#!/usr/bin/env python3
"""Load/append ~/.local/state/omarchy/power-history.log via a private dir FD.

Writes never follow pathnames: exclusive 0600 temp next to the log, fsync,
then renameat. Reads are O_NOFOLLOW|O_NONBLOCK and byte-capped.
"""
import os
import re
import signal
import stat
import sys

NAME = "power-history.log"
MAX_KEEP = 2880
MAX_STORE = 5760
MAX_LINE = 80
MAX_READ = 256 * 1024
# 9-11 digit unix time, pct 0..1, watts, discharge flag
REC = re.compile(
    rb"^(\d{9,11}) (0(?:\.\d{1,4})?|1(?:\.0{1,4})?) (\d{1,4}(?:\.\d{1,4})?) (-1|0|1)$"
)
OPEN_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
OPEN_READ = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
OPEN_EXCL = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC


def _die(*_):
    sys.exit(1)


def _open_child(dirfd, name, mkdir_mode):
    """Open existing dir child with O_NOFOLLOW, or mkdir it TOCTOU-safe.

    Follows only root-owned platform symlinks (link and target uid 0).
    Rejects all other symlinks. Caller validates ownership/mode.
    """
    try:
        return os.open(name, OPEN_DIR, dir_fd=dirfd)
    except (OSError, NotADirectoryError) as e:
        err = e.errno if hasattr(e, 'errno') else 2
        is_symlink = False
        link_target_root = False
        next_fd = -1
        try:
            link_st = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
            if stat.S_ISLNK(link_st.st_mode):
                is_symlink = True
                target_fd = os.open(
                    name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC,
                    dir_fd=dirfd,
                )
                try:
                    target_st = os.fstat(target_fd)
                    if link_st.st_uid == 0 and target_st.st_uid == 0:
                        link_target_root = True
                        next_fd = target_fd
                        target_fd = -1
                finally:
                    if target_fd >= 0:
                        os.close(target_fd)
        except OSError:
            pass
        if is_symlink:
            if link_target_root:
                return next_fd
            raise OSError("symlink in state path")
        if err != 2:  # not ENOENT (EACCES, etc.)
            raise
        try:
            link_st = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
            if stat.S_ISLNK(link_st.st_mode):
                raise OSError("symlink in state path")
        except OSError as e2:
            if e2.errno != 2:  # ENOENT
                raise
        os.mkdir(name, mode=mkdir_mode, dir_fd=dirfd)
        return os.open(name, OPEN_DIR, dir_fd=dirfd)


def open_state_dir():
    state = os.environ.get("XDG_STATE_HOME")
    if state:
        if not state.startswith("/"):
            raise OSError("XDG_STATE_HOME must be an absolute path")
    else:
        home = os.environ.get("HOME")
        if not home or not home.startswith("/"):
            raise OSError("HOME must be an absolute path")
        state = os.path.join(home, ".local", "state")
    # Walk from / with O_DIRECTORY|O_NOFOLLOW on every component.
    # Verify each component is a directory (not a symlink) BEFORE any mkdir.
    # No preceding realpath: following symlinks before the trusted
    # descriptor walk would let an ancestor symlink redirect the
    # whole tree; rejecting relative paths prevents cwd-dependent
    # state location.
    parts = [p for p in state.split(os.sep) if p]
    if not parts or any(p in (".", "..") for p in parts):
        raise OSError("bad state path")
    fd = os.open(b"/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        for part in parts:
            next_fd = _open_child(fd, part, 0o755)
            # Verify ownership: must be root or current user.
            st = os.fstat(next_fd)
            if st.st_uid != 0 and st.st_uid != os.getuid():
                os.close(next_fd)
                raise OSError("non-root-owned directory in state path")
            os.close(fd)
            fd = next_fd
        # fd is now the state directory
        next_fd = _open_child(fd, "omarchy", 0o700)
        st = os.fstat(next_fd)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
            os.close(next_fd)
            raise OSError("state dir not private")
        if st.st_mode & 0o077:
            os.fchmod(next_fd, 0o700)
        return next_fd
    finally:
        os.close(fd)


def _owned_reg(fd):
    st = os.fstat(fd)
    return stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid() and st.st_nlink == 1


def _read_fd(fd):
    data = bytearray()
    while len(data) < MAX_READ:
        try:
            chunk = os.read(fd, min(65536, MAX_READ - len(data)))
        except BlockingIOError:
            break
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def parse_records(data):
    out = []
    for raw in data.split(b"\n"):
        line = raw.strip()
        if not line or len(line) > MAX_LINE:
            continue
        if REC.match(line):
            out.append(line)
            if len(out) > MAX_STORE:
                out = out[-MAX_KEEP:]
    return out[-MAX_KEEP:]


def load_records(dirfd):
    try:
        fd = os.open(NAME, OPEN_READ, dir_fd=dirfd)
    except OSError:
        return []
    try:
        if not _owned_reg(fd):
            return []
        if os.fstat(fd).st_mode & 0o077:
            os.fchmod(fd, 0o600)
        return parse_records(_read_fd(fd))
    finally:
        os.close(fd)


def _replace(dirfd, records):
    payload = b"".join(r + b"\n" for r in records[-MAX_KEEP:])
    tmp = None
    tfd = -1
    for i in range(8):
        cand = ".%s.tmp.%d.%d" % (NAME, os.getpid(), i)
        try:
            tfd = os.open(cand, OPEN_EXCL, 0o600, dir_fd=dirfd)
            tmp = cand
            break
        except FileExistsError:
            continue
    if tmp is None:
        raise OSError("tmp")
    try:
        if not _owned_reg(tfd):
            raise OSError("tmp not private")
        off = 0
        while off < len(payload):
            n = os.write(tfd, payload[off:])
            if n <= 0:
                raise OSError("write")
            off += n
        os.fsync(tfd)
        os.close(tfd)
        tfd = -1
        os.rename(tmp, NAME, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        tmp = None
        os.fsync(dirfd)
    finally:
        if tfd >= 0:
            os.close(tfd)
        if tmp is not None:
            try:
                os.unlink(tmp, dir_fd=dirfd)
            except OSError:
                pass


def append_record(dirfd, line):
    line = line.strip()
    if isinstance(line, str):
        line = line.encode("ascii", "strict")
    if not REC.match(line):
        raise ValueError("bad record")
    recs = load_records(dirfd)
    recs.append(line)
    if len(recs) > MAX_STORE:
        recs = recs[-MAX_KEEP:]
    _replace(dirfd, recs)


def main(argv):
    signal.signal(signal.SIGALRM, _die)
    signal.alarm(3)
    try:
        os.setpgrp()
    except OSError:
        pass
    if not argv:
        return 1
    dirfd = open_state_dir()
    try:
        op = argv[0]
        if op == "load":
            recs = load_records(dirfd)
            sys.stdout.buffer.write(b"".join(r + b"\n" for r in recs))
            sys.stdout.buffer.flush()
            return 0
        if op == "append" and len(argv) >= 2:
            append_record(dirfd, argv[1])
            return 0
        return 1
    finally:
        os.close(dirfd)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception:
        sys.exit(1)
