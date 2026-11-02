"""Opt-in offline maintenance admission. Never grants authentication authority.

Only explicit database initialization may write while enabled. This scope does
not authorize providers or workers and must not be used by request handlers.
"""
from contextvars import ContextVar
from functools import wraps
import os

_initializing = ContextVar('maintenance_initializing', default=False)


def enabled():
    value = os.environ.get('GUNNAIRE_MAINTENANCE_MODE', '0').strip().lower()
    if value not in {'0', '1', 'false', 'true'}:
        raise ValueError('GUNNAIRE_MAINTENANCE_MODE must be 0/1 or false/true')
    return value in {'1', 'true'}


class MaintenanceUnavailable(RuntimeError):
    status = 503
    code = 'maintenance_unavailable'

    def __init__(self):
        super().__init__('Operation unavailable during maintenance')


def require_operational():
    if enabled():
        raise MaintenanceUnavailable()


def operational(function):
    @wraps(function)
    def guarded(*args, **kwargs):
        require_operational()
        return function(*args, **kwargs)
    return guarded


def initialize(function):
    @wraps(function)
    def initializing(*args, **kwargs):
        token = _initializing.set(True)
        try:
            return function(*args, **kwargs)
        finally:
            _initializing.reset(token)
    return initializing


def database_read_only():
    return enabled() and not _initializing.get()
