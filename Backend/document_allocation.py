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
            return self._worker.submit(operation, *args, **kwargs).result()
