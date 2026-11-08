"""Cross-process exclusion for complete app operations during storage migration.

No public control endpoint. Only an authorized local operator can freeze the
private database directory. A crash leaves the marker for explicit recovery;
never auto-expire a possibly partial migration. All writers must run gate-aware
code; this is not a substitute for verifying deployed process identity.
"""
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import stat
import time
import uuid


class Paused(RuntimeError):
    def __init__(self):super().__init__('Storage maintenance is active or unavailable')


class RotationGate:
    def __init__(self, directory):
        self.directory=Path(directory)
        self.lock=self.directory/'.storage-rotation.lock'
        self.marker=self.directory/'.storage-rotation-paused'

    def _open(self):
        fd=os.open(self.lock,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or stat.S_IMODE(info.st_mode)!=0o600:
            os.close(fd);raise Paused()
        return fd

    @contextmanager
    def operation(self):
        fd=None
        try:
            if self.marker.exists() or self.marker.is_symlink():raise Paused()
            fd=self._open()
            fcntl.flock(fd,fcntl.LOCK_SH|fcntl.LOCK_NB)
            if self.marker.exists() or self.marker.is_symlink():raise Paused()
        except (OSError,Paused):
            if fd is not None:os.close(fd)
            raise Paused() from None
        try:yield
        finally:os.close(fd)

    @contextmanager
    def exclusive(self, *, timeout=30):
        """Stop new work, drain existing operations, then permit migration.

        A pre-existing marker is never removed or adopted. Failed draining
        removes only our marker. A failure after entry retains it for explicit
        recovery, as does abrupt process death.
        """
        fd=marker_fd=None
        identity=None
        entered=completed=False
        try:
            marker_fd=os.open(self.marker,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
            info=os.fstat(marker_fd);identity=(info.st_dev,info.st_ino)
            os.write(marker_fd,uuid.uuid4().hex.encode())
            os.fsync(marker_fd)
            fd=self._open()
            deadline=time.monotonic()+timeout
            while True:
                try:
                    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);break
                except BlockingIOError:
                    if time.monotonic()>=deadline:raise Paused()
                    time.sleep(.01)
            entered=True
            yield
            completed=True
        finally:
            # Keep exclusion until the owned marker is gone. Never remove a
            # replacement marker belonging to another recovery operation.
            if identity is not None and (not entered or completed):
                try:
                    current=self.marker.lstat()
                    if (current.st_dev,current.st_ino)==identity:self.marker.unlink()
                except FileNotFoundError:pass
            if marker_fd is not None:os.close(marker_fd)
            if fd is not None:os.close(fd)
