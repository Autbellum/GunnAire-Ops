"""Bound large-buffer allocator ownership as well as concurrent operations."""
from concurrent.futures import ThreadPoolExecutor
import threading

class AllocationLane:
    def __init__(self, name):
        self._slot = threading.BoundedSemaphore(1)
        self._worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix=name)

    def run(self, operation, *args, **kwargs):
        # Admission precedes submission: at most one queued/running operation.
        # Reusing one thread avoids retaining a large malloc arena for each
        # short-lived HTTP handler. Callers still own returned verified bytes.
        with self._slot:
            # Do not start the operation until its Future is owned by this
            # caller. submit() itself can be interrupted after enqueueing work.
            start_guard = threading.Lock()
            admitted = False
            future = None
            def execute():
                with start_guard:
                    permitted = admitted
                if permitted:
                    return operation(*args, **kwargs)
            start_guard.acquire()
            try:
                try:
                    future = self._worker.submit(execute)
                    admitted = True
                finally:
                    start_guard.release()
                return future.result()
            except BaseException:
                if future is None:
                    # Submission outcome is uncertain, but execute cannot have
                    # entered the operation. Cancel/drain this lane and fail
                    # closed; restarting the process restores its availability.
                    self._worker.shutdown(wait=True, cancel_futures=True)
                else:
                    # Keep admission and the caller's rotation guard until any
                    # admitted operation finishes, even when waiting is interrupted.
                    while True:
                        try:
                            if future.done():
                                break
                            future.result()
                        except BaseException:
                            pass
                del future  # Avoid a Future/exception traceback retention cycle.
                raise
