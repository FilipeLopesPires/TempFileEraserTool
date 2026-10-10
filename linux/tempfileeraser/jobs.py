"""Background work that reports progress while it runs.

The Windows edition runs the scan and the removal in a PowerShell runspace and
reports through a ConcurrentQueue. Here a thread and a SimpleQueue do the same
job: the work is I/O bound in os.scandir, so the GIL costs nothing.

Every message is one of the small dataclasses below. The review window drains the
queue on a timer and matches on the type; the CLI drains it in a loop.
"""

from __future__ import annotations

import queue
import threading
from dataclasses import dataclass
from typing import Callable, Sequence


@dataclass(frozen=True)
class Progress:
    text: str
    step: int | None = None
    steps: int | None = None


@dataclass(frozen=True)
class FoundFolder:
    id: int
    path: str
    category: str
    confidence: str
    note: str | None = None


@dataclass(frozen=True)
class FoundFiles:
    id: int
    path: str
    files: tuple[str, ...]
    bytes: int
    category: str
    confidence: str
    note: str | None = None


@dataclass(frozen=True)
class Size:
    id: int
    bytes: int
    files: int


@dataclass(frozen=True)
class Removed:
    id: int
    path: str
    success: bool
    error: str | None = None
    bytes: int | None = None


@dataclass(frozen=True)
class Failure:
    message: str


@dataclass(frozen=True)
class Done:
    cancelled: bool = False


@dataclass
class Job:
    """A running thread, the queue it reports through, and its cancel switch."""

    queue: queue.SimpleQueue
    cancel: threading.Event
    thread: threading.Thread

    def stop(self, timeout: float = 5.0) -> None:
        self.cancel.set()
        self.thread.join(timeout)

    def drain(self, limit: int | None = None) -> list:
        """Every message waiting right now, up to limit. Never blocks."""
        messages = []
        while limit is None or len(messages) < limit:
            try:
                messages.append(self.queue.get_nowait())
            except queue.Empty:
                break
        return messages


def start(work: Callable, args: Sequence = ()) -> Job:
    """Runs work(*args, queue, cancel) in a daemon thread.

    The worker returns True if it stopped early. Done is posted here rather than
    by the worker, so there is always exactly one and a crash can never leave the
    window waiting forever.
    """
    message_queue: queue.SimpleQueue = queue.SimpleQueue()
    cancel = threading.Event()

    def run() -> None:
        cancelled = False
        try:
            cancelled = bool(work(*args, message_queue, cancel))
        except Exception as error:  # noqa: BLE001 - shown to the user, never raised here
            message_queue.put(Failure(str(error)))
            cancelled = True
        finally:
            message_queue.put(Done(cancelled=cancelled))

    thread = threading.Thread(target=run, name=getattr(work, '__name__', 'worker'), daemon=True)
    thread.start()
    return Job(queue=message_queue, cancel=cancel, thread=thread)
