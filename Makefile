.PHONY: help build build-candidate smoke smoke-host-docker smoke-candidate verify-tools

IMAGE ?= toolbelt:latest
CANDIDATE_TAG ?= toolbelt:candidate
DOCKERFILE ?= Dockerfile

help:
	@echo "Targets:"
	@echo "  make build                     # build $(IMAGE)"
	@echo "  make build-candidate CANDIDATE_TAG=toolbelt:candidate-<ts>"
	@echo "  make smoke IMAGE=<tag>         # smoke test image"
	@echo "  make smoke-host-docker IMAGE=<tag>  # smoke test image with host docker socket"
	@echo "  make smoke-candidate CANDIDATE_TAG=<tag>"
	@echo "  make verify-tools IMAGE=<tag>  # alias for smoke"

build:
	docker build -f $(DOCKERFILE) -t $(IMAGE) .

build-candidate:
	docker build -f $(DOCKERFILE) -t $(CANDIDATE_TAG) .

smoke:
	docker run --rm $(IMAGE) sh -lc 'openclaw --version >/dev/null && docker --version >/dev/null && docker compose version >/dev/null && docker-compose --version >/dev/null && docker buildx version >/dev/null && command -v iptables >/dev/null && command -v chub >/dev/null && command -v chub-mcp >/dev/null && chub --help >/dev/null && chub-mcp --help >/dev/null && openclaw doctor >/dev/null'

smoke-host-docker:
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock $(IMAGE) sh -lc 'openclaw --version >/dev/null && docker --version >/dev/null && docker ps >/dev/null && docker compose version >/dev/null && docker-compose --version >/dev/null && docker buildx version >/dev/null && command -v iptables >/dev/null && command -v chub >/dev/null && command -v chub-mcp >/dev/null && chub --help >/dev/null && chub-mcp --help >/dev/null && openclaw doctor >/dev/null'

smoke-candidate:
	$(MAKE) smoke IMAGE=$(CANDIDATE_TAG)

verify-tools:
	$(MAKE) smoke IMAGE=$(IMAGE)
