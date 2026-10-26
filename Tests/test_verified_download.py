"""Connection-reset recovery must preserve checksum and atomic-cache guarantees."""
import hashlib
import io
from pathlib import Path
import ssl
import sys
import tempfile
import unittest
import urllib.error
from unittest.mock import call, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Scripts'))
import verified_download as download


class Response(io.BytesIO):
    def __init__(self, data, length=None, *, status=200, content_range=None):
        super().__init__(data)
        self.status = status
        self.headers = {'Content-Length': str(len(data) if length is None else length)}
        if content_range is not None:
            self.headers['Content-Range'] = content_range


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.destination = Path(self.folder.name) / 'source.tar.gz'
        self.data = b'verified original source archive'
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.open_patch = patch.object(download.urllib.request, 'urlopen')
        self.open = self.open_patch.start()
        self.addCleanup(self.open_patch.stop)
        self.sleep_patch = patch.object(download.time, 'sleep')
        self.sleep = self.sleep_patch.start()
        self.addCleanup(self.sleep_patch.stop)

    def fetch(self, **kwargs):
        return download.fetch_verified('https://example.invalid/pinned.tar.gz',
                                       self.destination, self.digest, **kwargs)

    def test_connection_reset_recovers_and_commits_verified_bytes(self):
        self.open.side_effect = [urllib.error.URLError(ConnectionResetError(54, 'Connection reset by peer')),
                                 Response(self.data)]
        self.fetch()
        self.assertEqual(self.destination.read_bytes(), self.data)
        self.assertEqual(self.open.call_count, 2)
        self.sleep.assert_called_once_with(1)
        self.assertEqual(list(self.destination.parent.iterdir()), [self.destination])

    def test_partial_stream_reset_restarts_from_zero(self):
        broken = Response(self.data)
        broken.read = unittest.mock.Mock(side_effect=[self.data[:4], ConnectionResetError(54, 'reset')])
        self.open.side_effect = [broken, Response(self.data)]
        self.fetch()
        self.assertEqual(self.destination.read_bytes(), self.data)
        self.assertEqual(list(self.destination.parent.iterdir()), [self.destination])

    def test_truncated_content_length_retries(self):
        self.open.side_effect = [Response(self.data[:4], length=len(self.data)), Response(self.data)]
        self.fetch()
        self.assertEqual(self.open.call_count, 2)
        self.assertEqual(self.destination.read_bytes(), self.data)

    def test_truncated_download_resumes_remaining_bytes(self):
        self.open.side_effect = [Response(self.data[:4], length=len(self.data)),
                                 Response(self.data[4:], status=206,
                                          content_range=f'bytes 4-{len(self.data)-1}/{len(self.data)}')]
        self.fetch()
        request = self.open.call_args_list[1].args[0]
        self.assertEqual(request.get_header('Range'), 'bytes=4-')
        self.assertEqual(self.destination.read_bytes(), self.data)
        self.assertEqual(list(self.destination.parent.iterdir()), [self.destination])

    def test_ignored_range_restarts_instead_of_appending(self):
        self.open.side_effect = [Response(self.data[:4], length=len(self.data)), Response(self.data)]
        self.fetch()
        self.assertEqual(self.open.call_args_list[1].args[0].get_header('Range'), 'bytes=4-')
        self.assertEqual(self.destination.read_bytes(), self.data)

    def test_multiple_truncations_keep_advancing_resume_offset(self):
        last = len(self.data) - 1
        self.open.side_effect = [Response(self.data[:4], length=len(self.data)),
                                 Response(self.data[4:8], length=len(self.data)-4, status=206,
                                          content_range=f'bytes 4-{last}/{len(self.data)}'),
                                 Response(self.data[8:], status=206,
                                          content_range=f'bytes 8-{last}/{len(self.data)}')]
        self.fetch()
        self.assertEqual(self.open.call_args_list[2].args[0].get_header('Range'), 'bytes=8-')
        self.assertEqual(self.destination.read_bytes(), self.data)

    def test_invalid_range_cannot_publish(self):
        self.open.side_effect = [Response(self.data[:4], length=len(self.data)),
                                 Response(self.data[4:], status=206, content_range='bytes 0-25/30')]
        with self.assertRaisesRegex(ValueError, 'requested offset'):
            self.fetch()
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.destination.parent.iterdir()), [])

    def test_resumed_archive_still_requires_matching_checksum(self):
        self.destination.write_bytes(b'previous complete archive')
        self.open.side_effect = [Response(self.data[:4], length=len(self.data)),
                                 Response(b'x' * (len(self.data)-4), status=206,
                                          content_range=f'bytes 4-{len(self.data)-1}/{len(self.data)}')]
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            self.fetch()
        self.assertEqual(self.destination.read_bytes(), b'previous complete archive')
        self.assertEqual(list(self.destination.parent.iterdir()), [self.destination])

    def test_checksum_failure_never_replaces_existing_archive(self):
        self.destination.write_bytes(b'previous complete archive')
        self.open.return_value = Response(b'wrong bytes')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            self.fetch()
        self.assertEqual(self.destination.read_bytes(), b'previous complete archive')
        self.assertEqual(list(self.destination.parent.iterdir()), [self.destination])
        self.open.assert_called_once()
        self.sleep.assert_not_called()

    def test_retry_limit_preserves_existing_archive_and_removes_partials(self):
        self.destination.write_bytes(b'previous complete archive')
        self.open.side_effect = urllib.error.URLError(ConnectionResetError(54, 'reset'))
        with self.assertRaisesRegex(RuntimeError, 'after 4 attempts'):
            self.fetch()
        self.assertEqual(self.open.call_count, 4)
        self.assertEqual(self.sleep.call_args_list, [call(1), call(2), call(4)])
        self.assertEqual(self.destination.read_bytes(), b'previous complete archive')
        self.assertEqual(list(self.destination.parent.iterdir()), [self.destination])

    def test_verified_cache_avoids_network(self):
        self.destination.write_bytes(self.data)
        self.fetch()
        self.open.assert_not_called()

    def test_transient_http_failure_retries_but_not_missing_source(self):
        self.open.side_effect = [urllib.error.HTTPError('url', 503, 'unavailable', {}, None), Response(self.data)]
        self.fetch()
        self.destination.unlink()
        self.open.reset_mock(side_effect=True)
        self.open.side_effect = urllib.error.HTTPError('url', 404, 'not found', {}, None)
        with self.assertRaises(urllib.error.HTTPError):
            self.fetch()
        self.open.assert_called_once()
        self.assertFalse(self.destination.exists())

    def test_certificate_validation_is_not_bypassed_or_retried(self):
        self.open.side_effect = urllib.error.URLError(ssl.SSLCertVerificationError('invalid certificate'))
        with self.assertRaises(urllib.error.URLError):
            self.fetch()
        self.open.assert_called_once()
        self.sleep.assert_not_called()
        self.assertEqual(list(self.destination.parent.iterdir()), [])

    def test_size_limit_rejects_before_publishing(self):
        self.open.return_value = Response(self.data)
        with self.assertRaisesRegex(ValueError, 'size limit'):
            self.fetch(max_bytes=4)
        self.open.assert_called_once()
        self.assertEqual(list(self.destination.parent.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
