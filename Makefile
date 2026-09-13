JULIA ?= julia

.PHONY: help deps generate parse format test test-examples docs check

help:
	@echo "make generate       Regenerate per-target src/bindings with Clang.jl"
	@echo "make parse          Load and precompile the complete package"
	@echo "make format         Format Julia source files"
	@echo "make test           Run package tests"
	@echo "make test-examples  Run all example programs"
	@echo "make deps           Instantiate root and tools environments"
	@echo "make docs           Build Documenter.jl documentation"
	@echo "make check          Run parse checks and tests"

generate:
	$(JULIA) --project=tools gen/generator.jl

parse:
	$(JULIA) --project -e 'using LibRawWrapper'

format:
	$(JULIA) --project=tools -e 'using JuliaFormatter; format("src"; overwrite=true, ignore=["raw.jl", "bindings"]); for dir in ("gen", "test", "examples"); format(dir; overwrite=true); end'

test:
	$(JULIA) --project test/runtests.jl

test-examples:
	$(JULIA) --project test/examples.jl

docs:
	$(JULIA) --project=tools docs/make.jl

check: deps parse test test-examples

deps:
	$(JULIA) --project -e 'using Pkg; Pkg.instantiate()'
	$(JULIA) --project=tools -e 'using Pkg; Pkg.instantiate()'
