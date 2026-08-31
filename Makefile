# Portable core (T650Kit) builds and tests in Docker — no local Swift needed.
# The t650d daemon target only builds on a real Mac (or macOS CI).
SWIFT := docker run --rm -v "$(CURDIR)":/src -w /src swift:latest swift

test:
	$(SWIFT) test

build:
	$(SWIFT) build --target T650Kit

shell:
	docker run --rm -it -v "$(CURDIR)":/src -w /src swift:latest bash

clean:
	rm -rf .build

.PHONY: test build shell clean
