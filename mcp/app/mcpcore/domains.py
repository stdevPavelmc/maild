"""MCP domain allow-list (D6): a domain is usable only when it is an ACTIVE catalogue domain AND
has `domain_policy.allowed = true`. No row = denied (secure default for new domains); an
inactive or deleted catalogue domain is denied but keeps its policy row.

Catalogue reads are cached for 30 s per process (proposal §8.2); the policy itself is not.
"""

import time

from mcpcore import audit, catalogue
from mcpcore.models import DomainPolicy

_TTL = 30.0
_cache: dict[str, tuple[float, bool]] = {}


def _catalogue_active(domain: str) -> bool:
    hit = _cache.get(domain)
    now = time.monotonic()
    if hit and now - hit[0] < _TTL:
        return hit[1]
    active = bool(catalogue.domain_state(domain))
    _cache[domain] = (now, active)
    return active


def is_allowed(domain: str) -> bool:
    """The policy row (our own DB) is read on every call, so an allow/deny takes effect at once in
    every worker; only the catalogue state is cached."""
    domain = domain.lower()
    return DomainPolicy.objects.filter(domain=domain, allowed=True).exists() and _catalogue_active(domain)


def address_allowed(address: str) -> bool:
    return "@" in address and is_allowed(address.rsplit("@", 1)[1])


def listing() -> list[dict]:
    policies = {p.domain: p.allowed for p in DomainPolicy.objects.all()}
    return [
        {"domain": d, "catalogue_active": active, "allowed": policies.get(d, False),
         "effective": active and policies.get(d, False)}
        for d, active in catalogue.domains()
    ]


def set_allowed(domain: str, allowed: bool, actor: dict) -> None:
    domain = domain.lower()
    if catalogue.domain_state(domain) is None:
        raise ValueError(f"'{domain}' is not a catalogue domain")
    DomainPolicy.objects.update_or_create(domain=domain, defaults={"allowed": allowed})
    _cache.pop(domain, None)
    audit.event("admin.settings", "domain.allow" if allowed else "domain.deny", actor=actor,
                target={"domain": domain})
