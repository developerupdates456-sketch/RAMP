"""Pytest bootstrap.

Makes ``backend`` importable when pytest is invoked from anywhere in the repo.

Why this is needed: ``backend/tests/`` has no ``__init__.py``, so pytest's
default ``prepend`` import mode inserts ``backend/tests`` on ``sys.path`` -- not
the repository root. Every ``from backend...`` import in the test suite then
fails with ``ModuleNotFoundError: No module named 'backend'``, which is
reported as a collection error for each test module rather than as a real test
failure.
"""

import os
import sys

REPO_ROOT = os.path.dirname(os.path.abspath(__file__))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)
