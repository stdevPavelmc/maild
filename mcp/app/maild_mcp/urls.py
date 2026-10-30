from django.urls import path

from mcpcore import views

urlpatterns = [
    path("healthz", views.healthz),
]
