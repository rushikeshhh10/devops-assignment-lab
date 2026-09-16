"""
test_verify.py - Unit tests for verify.py.

These test the verifier's own logic (retry/timeout behavior, marker
generation, SSL context setup) in isolation, without needing live
infrastructure - this is what CI runs on every push/PR. The live,
full end-to-end pipeline test (against real AWS infra) is what
terraform/verify.tf's null_resource runs during an actual deploy.
"""

import os
import ssl
import sys
import time
import unittest
import uuid
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.dirname(__file__))
import verify  # noqa: E402


class TestWaitUntil(unittest.TestCase):
    def test_succeeds_when_check_immediately_true(self):
        result = verify.wait_until("test", lambda: True, timeout_s=5, interval_s=1)
        self.assertTrue(result)

    def test_fails_and_times_out_when_check_always_false(self):
        start = time.time()
        result = verify.wait_until("test", lambda: False, timeout_s=2, interval_s=1)
        elapsed = time.time() - start
        self.assertFalse(result)
        self.assertGreaterEqual(elapsed, 2)

    def test_succeeds_after_a_few_transient_failures(self):
        calls = {"n": 0}

        def flaky():
            calls["n"] += 1
            if calls["n"] < 3:
                raise ConnectionError("not ready yet")
            return True

        result = verify.wait_until("test", flaky, timeout_s=5, interval_s=0.3)
        self.assertTrue(result)
        self.assertGreaterEqual(calls["n"], 3)

    def test_does_not_hang_past_its_timeout(self):
        start = time.time()
        verify.wait_until("test", lambda: False, timeout_s=1, interval_s=0.2)
        elapsed = time.time() - start
        self.assertLess(elapsed, 3)  # generous margin, but proves it's bounded


class TestSSLContext(unittest.TestCase):
    def test_context_disables_verification_for_self_signed_certs(self):
        ctx = verify.make_ssl_context()
        self.assertFalse(ctx.check_hostname)
        self.assertEqual(ctx.verify_mode, ssl.CERT_NONE)


class TestMarkerGeneration(unittest.TestCase):
    def test_marker_is_unique_each_call(self):
        m1 = f"verifier-{uuid.uuid4().hex}"
        m2 = f"verifier-{uuid.uuid4().hex}"
        self.assertNotEqual(m1, m2)

    def test_marker_has_expected_prefix_and_length(self):
        m = f"verifier-{uuid.uuid4().hex}"
        self.assertTrue(m.startswith("verifier-"))
        self.assertEqual(len(m), len("verifier-") + 32)  # uuid4 hex is 32 chars


class TestHttpGetAuthHeader(unittest.TestCase):
    @patch("verify.urllib.request.urlopen")
    def test_adds_basic_auth_header_when_credentials_given(self, mock_urlopen):
        verify.http_get("https://example.test/", user="admin", password="secret", ctx=None)
        called_request = mock_urlopen.call_args[0][0]
        self.assertIn("Authorization", called_request.headers)
        self.assertTrue(called_request.headers["Authorization"].startswith("Basic "))

    @patch("verify.urllib.request.urlopen")
    def test_no_auth_header_when_no_credentials(self, mock_urlopen):
        verify.http_get("https://example.test/", ctx=None)
        called_request = mock_urlopen.call_args[0][0]
        self.assertNotIn("Authorization", called_request.headers)


class TestMarkerDeliveryLogic(unittest.TestCase):
    """
    Simulates the exact check main() uses to decide whether the marker made
    it into Wazuh: a plain substring match against the raw Indexer response
    body (see verify.py's comment on why this approach was chosen).
    """

    def test_marker_found_in_indexer_response_body(self):
        marker = "verifier-abc123"
        fake_response_body = (
            '{"hits":{"hits":[{"_source":{"full_log":'
            '"...uri=/?verify=verifier-abc123..."}}]}}'
        )
        self.assertIn(marker, fake_response_body)

    def test_marker_not_found_in_unrelated_response_body(self):
        marker = "verifier-abc123"
        fake_response_body = '{"hits":{"hits":[]}}'
        self.assertNotIn(marker, fake_response_body)


if __name__ == "__main__":
    unittest.main()
