from django.urls import path, re_path

from mcpcore import views
from oauth import views as oauth
from webapi.api import api

urlpatterns = [
    path("healthz", views.healthz),
    path("webapi/", api.urls),
    # OAuth 2.1 authorization server + metadata (P4)
    path(".well-known/oauth-protected-resource", oauth.protected_resource),
    path(".well-known/oauth-protected-resource/api/v1/mcp", oauth.protected_resource),
    path(".well-known/oauth-authorization-server", oauth.authorization_server),
    path("oauth/authorize", oauth.authorize),
    path("oauth/token", oauth.token),
    path("oauth/revoke", oauth.revoke),
    path("oauth/register", oauth.register),
    # the admin SPA (separate bundle: no admin code is shipped to /)
    re_path(r"^adminmcp(?:/.*)?$", views.admin_spa),
    # the user SPA: every other GET is a client-side route (/, /confirm, …)
    re_path(r"^(?!webapi/|api/|assets/|oauth/|\.well-known/).*$", views.spa),
]
