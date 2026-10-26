# SPDX-License-Identifier: GPL-3.0-or-later
"""Retry interrupted source downloads; publish only checksum-verified archives."""
import hashlib
import http.client
from pathlib import Path
import re
import ssl
import tempfile
import time
import urllib.error
import urllib.request


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def fetch_verified(url, destination, expected_sha256, *, attempts=4, timeout=90,
                   max_bytes=128 * 1024 * 1024):
    destination = Path(destination)
    if attempts < 1 or max_bytes < 1:
        raise ValueError('Download attempts and size limit must be positive')
    if destination.is_file() and sha256_file(destination) == expected_sha256:
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=destination.name + '.',
                                     suffix='.download', delete=False) as file:
        temporary = Path(file.name)
    try:
        for attempt in range(1, attempts + 1):
            try:
                print(f'Downloading {destination.name} (attempt {attempt}/{attempts})', flush=True)
                offset = temporary.stat().st_size
                headers = {'Accept-Encoding': 'identity'}
                if offset:
                    headers.update({'Range': f'bytes={offset}-', 'Cache-Control': 'no-cache'})
                request = urllib.request.Request(url, headers=headers)
                with temporary.open('r+b') as file:
                    with urllib.request.urlopen(request, timeout=timeout) as response:
                        status = getattr(response, 'status', 200)
                        length = response.headers.get('Content-Length')
                        length = int(length) if length and length.isdecimal() else None
                        expected_total = None
                        if status == 206:
                            content_range = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)',
                                                         response.headers.get('Content-Range', ''))
                            if content_range is None:
                                raise ValueError('Missing or invalid source Content-Range')
                            start, end, expected_total = map(int, content_range.groups())
                            if start != offset or end < start or end >= expected_total:
                                raise ValueError('Source Content-Range does not match requested offset')
                            if length is not None and length != end - start + 1:
                                raise ValueError('Source Content-Length does not match range')
                            length = end - start + 1
                            file.seek(offset)
                        elif status == 200:
                            # A server may ignore Range. Never append a complete response
                            # to partial data; safely restart the temporary file instead.
                            offset = 0
                            file.seek(0)
                            file.truncate()
                        else:
                            raise ValueError(f'Unexpected source response status: {status}')
                        if ((expected_total is not None and expected_total > max_bytes) or
                                (length is not None and offset + length > max_bytes)):
                            raise ValueError('Source archive exceeds size limit: ' + destination.name)
                        total = offset
                        while True:
                            chunk = response.read(1024 * 1024)
                            if not chunk:
                                break
                            total += len(chunk)
                            if total > max_bytes:
                                raise ValueError('Source archive exceeds size limit: ' + destination.name)
                            file.write(chunk)
                        expected_end = offset + length if length is not None else total
                        if total != expected_end:
                            raise http.client.IncompleteRead(b'', max(0, expected_end - total))
                        if expected_total is not None and total < expected_total:
                            raise http.client.IncompleteRead(b'', expected_total - total)
                if sha256_file(temporary) != expected_sha256:
                    raise ValueError('Source checksum mismatch: ' + destination.name)
                temporary.replace(destination)
                return destination
            except (urllib.error.URLError, ConnectionError, TimeoutError,
                    http.client.IncompleteRead, ssl.SSLEOFError) as error:
                if isinstance(error, urllib.error.HTTPError):
                    error.close()
                    if error.code not in {408, 429, 500, 502, 503, 504}:
                        raise
                if isinstance(getattr(error, 'reason', None), ssl.SSLCertVerificationError):
                    raise
                if attempt == attempts:
                    raise RuntimeError(f'Download failed after {attempts} attempts: {destination.name}') from error
                delay = 2 ** (attempt - 1)
                print(f'Download interrupted ({error}); retrying in {delay}s.', flush=True)
                time.sleep(delay)
    finally:
        temporary.unlink(missing_ok=True)
