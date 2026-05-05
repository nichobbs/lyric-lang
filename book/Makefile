# Making Lyric Sing — build targets
#
# Requires: pandoc >= 3.0
# For PDF:  a LaTeX distribution (TeX Live / MiKTeX) with XeLaTeX
#           Optional: the eisvogel pandoc template for a polished cover page
#             https://github.com/Wandmalfarbe/pandoc-latex-template
# For HTML: no extra dependencies (CSS is embedded in the output file)
#
# Usage:
#   make pdf     — produces making-lyric-sing.pdf
#   make html    — produces making-lyric-sing.html  (self-contained)
#   make all     — both
#   make clean   — remove generated files

PANDOC   := pandoc
METADATA := metadata.yaml
OUT_BASE := making-lyric-sing

CHAPTERS := \
	chapters/00-preface.md \
	chapters/01-getting-started.md \
	chapters/02-core-types.md \
	chapters/03-data-structures.md \
	chapters/04-functions-and-modes.md \
	chapters/05-pattern-matching.md \
	chapters/06-visibility-and-modules.md \
	chapters/07-error-handling.md \
	chapters/08-contracts.md \
	chapters/09-opaque-types.md \
	chapters/10-async-and-concurrency.md \
	chapters/11-dependency-injection.md \
	chapters/12-standard-library.md \
	chapters/13-interop-and-ffi.md \
	chapters/14-testing.md \
	chapters/15-mocking-and-test-wires.md \
	chapters/16-runtime-verification.md \
	chapters/17-proofs.md \
	chapters/18-advanced-verification.md \
	chapters/19-package-ecosystem.md \
	chapters/appendix-a-vscode.md \
	chapters/appendix-b-quick-reference.md

# ── PDF ──────────────────────────────────────────────────────────────────────

# Check whether the eisvogel template is installed; use it if present.
EISVOGEL := $(shell pandoc --list-templates 2>/dev/null | grep -c eisvogel)

PDF_FLAGS := \
	--pdf-engine=xelatex \
	--toc \
	--toc-depth=2 \
	-V papersize=a4 \
	-V geometry:margin=2.5cm \
	-V colorlinks=true \
	-V linkcolor=NavyBlue \
	--highlight-style=tango \
	--lua-filter=filters/sidebar.lua

ifeq ($(EISVOGEL),1)
PDF_FLAGS += --template=eisvogel
endif

pdf: $(METADATA) $(CHAPTERS)
	$(PANDOC) $(METADATA) $(CHAPTERS) $(PDF_FLAGS) -o $(OUT_BASE).pdf
	@echo "Written: $(OUT_BASE).pdf"

# ── HTML ─────────────────────────────────────────────────────────────────────

HTML_FLAGS := \
	--standalone \
	--embed-resources \
	--toc \
	--toc-depth=2 \
	--css=style.css \
	--highlight-style=tango \
	--lua-filter=filters/sidebar.lua \
	-V lang=en

html: $(METADATA) $(CHAPTERS) style.css
	$(PANDOC) $(METADATA) $(CHAPTERS) $(HTML_FLAGS) -o $(OUT_BASE).html
	@echo "Written: $(OUT_BASE).html"

# ── Both ─────────────────────────────────────────────────────────────────────

all: pdf html

# ── Clean ────────────────────────────────────────────────────────────────────

clean:
	rm -f $(OUT_BASE).pdf $(OUT_BASE).html

.PHONY: pdf html all clean
