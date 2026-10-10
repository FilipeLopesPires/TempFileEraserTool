"""One reviewable row: a generated folder, or the temp files found in one folder."""

from __future__ import annotations

from dataclasses import dataclass, field

from .jobs import FoundFiles, FoundFolder
from .rules import CERTAIN

FOLDER_ROW = 'Folder'
FILES_ROW = 'Files'


@dataclass
class Row:
    id: int
    kind: str
    path: str
    category: str
    confidence: str
    files: tuple[str, ...] = ()
    note: str | None = None
    # None until the scan's sizing pass reports it; file rows know it immediately
    bytes: int | None = None
    checked: bool = False

    @classmethod
    def from_message(cls, message: FoundFolder | FoundFiles) -> 'Row':
        is_files = isinstance(message, FoundFiles)
        return cls(
            id=message.id,
            kind=FILES_ROW if is_files else FOLDER_ROW,
            path=message.path,
            category=message.category,
            confidence=message.confidence,
            files=tuple(getattr(message, 'files', ())),
            note=message.note,
            bytes=message.bytes if is_files else None,
            # Uncertain rows start unchecked: they are probably generated, but check first
            checked=message.confidence == CERTAIN,
        )

    def to_item(self) -> dict:
        """The shape remover.run_removal expects."""
        return {'id': self.id, 'kind': self.kind, 'path': self.path,
                'files': self.files, 'bytes': self.bytes}
