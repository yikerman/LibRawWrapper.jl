JULIA ?= julia

.PHONY: help generate parse format test docs check

help:
	@echo "make generate  Regenerate src/raw.jl with Clang.jl"
	@echo "make parse     Load and precompile the complete package"
	@echo "make format    Format Julia source files"
	@echo "make test      Run package tests"
	@echo "make docs      Build Documenter.jl documentation"
	@echo "make check     Run parse checks and tests"

generate:
	$(JULIA) --project=tools gen/generator.jl

parse:
	$(JULIA) --project -e 'using LibRawWrapper'

format:
	$(JULIA) --project=tools -e 'using JuliaFormatter; format("src"; overwrite=true, ignore=["raw.jl"]); for dir in ("gen", "test", "examples"); format(dir; overwrite=true); end'

test:
	$(JULIA) --project test/runtests.jl

docs:
	$(JULIA) --project=tools docs/make.jl

check: parse test
