"""Keep Django models (and migrations) off the catalogue connection.

The `catalogue` alias is only ever used for raw read-only SQL (mcpcore.catalogue); the
restricted role could not create tables there anyway.
"""


class CatalogueRouter:
    def db_for_read(self, model, **hints):
        return "default"

    def db_for_write(self, model, **hints):
        return "default"

    def allow_relation(self, obj1, obj2, **hints):
        return True

    def allow_migrate(self, db, app_label, model_name=None, **hints):
        return db == "default"
