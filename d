#!/bin/bash

docker compose --env-file env.dev -f docker-compose-dev.yml $@
