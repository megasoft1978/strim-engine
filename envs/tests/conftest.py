import os

# macOS Seatbelt is accepted for trusted local development only (see README).
os.environ.setdefault("STRIM_ENVS_TRUSTED_LOCAL", "1")
