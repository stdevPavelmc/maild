class OAuthError(Exception):
    """An RFC 6749 error: `code` is the `error` value, `message` its description."""

    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status

    def as_dict(self) -> dict:
        return {"error": self.code, "error_description": self.message}
