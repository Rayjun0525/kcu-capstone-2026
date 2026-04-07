EXTENSION = alma
DATA = sql/alma--1.0.sql
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

SQL_FILES = sql/01_schemas.sql \
            sql/02_roles.sql \
            sql/03_types.sql \
            sql/04_tables.sql \
            sql/05_views.sql \
            sql/06_functions_core.sql \
            sql/07_functions_llm.sql \
            sql/08_functions_agent.sql \
            sql/09_functions_mgmt.sql \
            sql/10_grants.sql \
            sql/11_indexes.sql \
            sql/12_triggers.sql

.PHONY: build clean fmt

build: $(SQL_FILES)
	@echo "-- ALMA Extension v1.0 — auto-generated, do not edit" > sql/alma--1.0.sql
	@echo "-- Generated: $$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> sql/alma--1.0.sql
	@echo "" >> sql/alma--1.0.sql
	@for f in $(SQL_FILES); do \
		echo "-- ============================================================"; \
		echo "-- $$f"; \
		echo "-- ============================================================"; \
		cat $$f; \
		echo ""; \
	done >> sql/alma--1.0.sql
	@echo "Build complete: sql/alma--1.0.sql"

clean:
	rm -f sql/alma--1.0.sql
