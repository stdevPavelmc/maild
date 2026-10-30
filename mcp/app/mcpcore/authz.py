"""Per-request authorization (proposal §8.2). Nothing is cached in the token; every request
re-evaluates:

  token active + not expired + not idle      (tokens.check_bearer, at the HTTP layer)
  → account MCP switch on                    (HTTP 403 mcp_disabled)
  → scope covers the tool                    (HTTP 403 insufficient_scope)
  → target address active in the account and inside the token's address subset
  → mailbox active in the catalogue → domain allowed          (per tool call)
"""

from dataclasses import dataclass, field

from mcpcore import catalogue, domains
from mcpcore.models import Account, AccountAddress, Token

# tool → scope (proposal §8.3); P2 adds the modify/trash/send tools
TOOL_SCOPES = {
    "list_accounts": "mail.read", "list_folders": "mail.read", "check_new_mail": "mail.read",
    "search_emails": "mail.read", "get_email": "mail.read", "get_thread": "mail.read",
    "get_attachment": "mail.read", "get_quota": "mail.read",
    # P2
    "mark_emails": "mail.modify", "move_emails": "mail.modify", "create_folder": "mail.modify",
    "rename_folder": "mail.modify", "save_draft": "mail.modify",
    "report_spam": "mail.trash", "not_spam": "mail.trash", "trash_emails": "mail.trash",
    "restore_from_trash": "mail.trash", "delete_folder": "mail.trash",
    "send_email": "mail.send", "reply_email": "mail.send", "forward_email": "mail.send",
}


class Denied(Exception):
    pass


@dataclass
class Principal:
    token: Token
    account: Account
    ip: str = ""
    client: str = ""
    request_id: str = ""
    _addresses: list[dict] | None = field(default=None, repr=False)

    @property
    def scopes(self) -> set[str]:
        return set(self.token.scopes or [])

    def audit_token(self) -> dict:
        return {"public_id": self.token.public_id, "kind": self.token.kind, "client": self.client}

    def audit_actor(self) -> dict:
        return {"type": "token", "account": self.account.id, "email": self.account.main_email}

    def addresses(self) -> list[dict]:
        """Every address of the account with its usability for this token, computed once per request."""
        if self._addresses is None:
            subset = set(self.token.addresses) if self.token.addresses is not None else None
            rows = []
            for a in AccountAddress.objects.filter(account=self.account).order_by("-is_main", "email"):
                reason = ""
                if a.status != AccountAddress.ACTIVE:
                    reason = a.status
                elif subset is not None and a.email not in subset:
                    reason = "not_in_token"
                elif not domains.address_allowed(a.email):
                    reason = "domain_not_allowed"
                elif catalogue.mailbox_state(a.email) is not True:
                    reason = "mailbox_inactive"
                rows.append({"address": a.email, "main": a.is_main, "status": a.status,
                             "usable": not reason, "reason": reason})
            self._addresses = rows
        return self._addresses

    def prefs(self) -> dict:
        from mcpcore import prefs

        return prefs.get(self.account)

    def hidden(self) -> set[str]:
        """Folders the user hid from agents (§7.3.3): never listed, searched or touched."""
        return set(self.prefs().get("hidden_folders") or [])

    def check_folder(self, *folders: str) -> None:
        hidden = self.hidden()
        for f in folders:
            if f and f in hidden:
                raise Denied(f"folder '{f}' is hidden from agents by the mailbox owner")

    def usable(self) -> list[str]:
        return [a["address"] for a in self.addresses() if a["usable"]]

    def resolve(self, account: str, allow_all: bool = False) -> list[str]:
        """The address(es) a tool may touch for its `account` argument."""
        account = (account or "").strip().lower()
        usable = self.usable()
        if allow_all and account in ("", "*"):
            if not usable:
                raise Denied("this token cannot use any address (check the account's addresses and the token's subset)")
            return usable
        if not account:
            raise Denied("'account' is required: one of " + ", ".join(usable))
        if account not in usable:
            row = next((a for a in self.addresses() if a["address"] == account), None)
            why = row["reason"] if row else "not an address of this account"
            raise Denied(f"'{account}' cannot be used by this token ({why})")
        return [account]
