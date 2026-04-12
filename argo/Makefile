EXTENSION = argo
DATA      = sql/argo--1.0.sql

# For EDB/EPAS, you may need to specify PG_CONFIG explicitly
# e.g.: make PG_CONFIG=/usr/edb/as18/bin/pg_config install
PG_CONFIG ?= pg_config

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

.PHONY: build
build:
	@echo "ARGO extension files are ready (no compilation needed)."
