"""Real KLayout database classes, with no JSON/DSL translation layer.

Trusted local scripts have the complete klayout.db API, including read/write.
The companion HTTP worker separately restricts the methods available to AI code.
"""
from klayout.db import *  # noqa: F403
import klayout.db as db
from .generic_cmos import generic_cmos_inverter
from .ports import add_port, get_ports, update_port, remove_port

__version__ = "0.1.0"
