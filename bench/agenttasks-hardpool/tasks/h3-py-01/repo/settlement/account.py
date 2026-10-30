"""Account state and a defensive snapshot for API callers."""
from dataclasses import dataclass, field


@dataclass
class Account:
    balance: int = 0
    holds: dict = field(default_factory=dict)

    @property
    def reserved(self):
        return sum(self.holds.values())

    @property
    def available(self):
        return self.balance - self.reserved

    def copy(self):
        return Account(self.balance, self.holds.copy())

    def view(self):
        return {
            "balance": self.balance,
            "reserved": self.reserved,
            "available": self.available,
            "holds": dict(self.holds),
        }
