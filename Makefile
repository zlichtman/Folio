SCRATCH ?= /private/tmp/folio-build
SWIFTPM := --disable-sandbox --scratch-path "$(SCRATCH)/debug" -debug-info-format none
export CLANG_MODULE_CACHE_PATH ?= $(SCRATCH)/clang
export FOLIO_BUILD_CACHE ?= $(SCRATCH)

.PHONY: all build test app dmg release-check clean

all: build

build:
	swift build $(SWIFTPM)

test:
	swift test $(SWIFTPM)

# Universal, Developer ID signed Folio.app staged in $(SCRATCH)/stage; dist/ gets only archives
# (FOLIO_ALLOW_ADHOC=1 without an identity).
app:
	./scripts/build-app.sh

# Notarized, stapled dist/Folio.dmg and dist/Folio-<version>.zip (FOLIO_NOTARIZE=0 for a dry run).
dmg:
	./scripts/package-release.sh

release-check:
	./scripts/check-release.sh

clean:
	rm -rf "$(SCRATCH)" dist .build
