import os
import sys

# Let tests import the backend modules (lookup, verification, ...) directly.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
