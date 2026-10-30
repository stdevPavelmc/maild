from django.urls import path, re_path

from mcpcore import views
from webapi.api import api

urlpatterns = [
    path("healthz", views.healthz),
    path("webapi/", api.urls),
    # the SPA: every other GET is a client-side route (/, /confirm, …)
    re_path(r"^(?!webapi/|api/|assets/|\.well-known/).*$", views.spa),
]
