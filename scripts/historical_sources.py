"""Read historical test sources without depending on mutable Git references."""
import hashlib
from pathlib import Path, PurePosixPath
import re


class HistoricalSourceError(RuntimeError):
    pass


def read_source(snapshot, relative_path, expected_sha256, expected_blob):
    """Require a regular snapshot file matching its original SHA-256 and Git blob."""
    if not isinstance(relative_path, str):
        raise HistoricalSourceError("Historical source path must be a relative file path")
    relative = PurePosixPath(relative_path)
    if (not relative.parts or relative.is_absolute() or ".." in relative.parts
            or str(relative) != relative_path or "\\" in relative_path):
        raise HistoricalSourceError("Historical source path must be a canonical relative file path")
    if not isinstance(expected_sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
        raise HistoricalSourceError("Historical source SHA-256 is invalid")
    if not isinstance(expected_blob, str) or not re.fullmatch(r"[0-9a-f]{40}", expected_blob):
        raise HistoricalSourceError("Historical source Git blob is invalid")
    candidate = Path(snapshot)
    if candidate.is_symlink() or not candidate.is_dir():
        raise HistoricalSourceError("Historical source snapshot directory is unavailable")
    for part in relative.parts:
        candidate /= part
        if candidate.is_symlink():
            raise HistoricalSourceError("Historical source must not traverse symbolic links")
    if not candidate.is_file():
        raise HistoricalSourceError("Historical source snapshot is missing: " + relative_path)
    try:
        data = candidate.read_bytes()
    except OSError as error:
        raise HistoricalSourceError("Historical source snapshot cannot be read: " + relative_path) from error
    if hashlib.sha256(data).hexdigest() != expected_sha256:
        raise HistoricalSourceError("Historical source SHA-256 mismatch: " + relative_path)
    object_data = b"blob " + str(len(data)).encode("ascii") + b"\0" + data
    if hashlib.sha1(object_data).hexdigest() != expected_blob:
        raise HistoricalSourceError("Historical source Git blob mismatch: " + relative_path)
    return data
