rfind = $(shell find '$(1)' -name '$(2)')

# TODO add this back in: Makefile
SRC_FILES := $(call rfind,src,[^.]*.ts) \
		$(call rfind,src,[^.]*.js) \
		$(call rfind,src,[^.]*.json)

EXAMPLE_FILES = $(shell find examples/ -type f)

PREREQS_STATEFILE = .make/done_prereqs
DEPS_STATEFILE = .make/done_deps
TESTS_STATEFILE = .make/done_tests
DOCKER_STATEFILE = .make/done_docker
BUILD_ARTIFACTS = dist/iidy-macos dist/iidy-linux
RELEASE_PACKAGES = dist/iidy-macos-amd64.zip dist/iidy-linux-amd64.zip

DOCKER_BUILD_ARGS = --force-rm

##########################################################################################
## Top level targets. Our public api. See Plumbing section for the actual work

.PHONY: help
help: ## Display this message
	@grep -E '^[a-zA-Z_-]+ *:.*?## .*$$' $(MAKEFILE_LIST) \
	| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
.DEFAULT_GOAL := help

.PHONY: prereqs
prereqs: $(PREREQS_STATEFILE)     ## Check for system level prerequisites

.PHONY: deps
deps: $(DEPS_STATEFILE)           ## Install library deps (e.g. npm install)

.PHONY: build
build: $(BUILD_ARTIFACTS)         ## Build static binaries

.PHONY: docker_build
docker_build: $(DOCKER_STATEFILE) ## Build and test docker images

.PHONY: test
test: $(TESTS_STATEFILE)          ## Run functional tests

.PHONY: clean
clean:                            ## Clean the dist/ directory (binaries, etc.)
	rm -rf dist/* lib/*

.PHONY: fullclean
fullclean : clean                 ## Clean dist, node_modules and .make (make state tracking)
	rm -rf .make node_modules

.PHONY: package
package: SHELL:=/bin/bash
package: $(RELEASE_PACKAGES)
	@git diff --quiet --ignore-submodules HEAD || echo -e '\x1b[0;31mWARNING: git workding dir not clean\x1b[0m'
	@echo
	@ls -alh dist/*zip
	@shasum -p -a 256 dist/* || true

.PHONY: release
release: check_working_dir_is_clean clean deps build test bump_version_and_tag package
	@echo
	@echo Changelog:
	@ { \
		IFS=":" read -r first second; \
		echo git log $${first}...$${second}; echo ; \
		git --no-pager log $${first}...$${second} \
			--grep="Merge pull request #" --format="- %b %s" \
			| sed 's/ from [^ ]\+\/[^ ]\+$///' \
			| sed 's/Merge pull request #\([0-9]+\)/\(#\1\)/'; \
		} < <(git tag | tail -n2 | paste -sd':' -)
	@echo open dist/
	@echo update https://github.com/unbounce/iidy/releases
	@echo and remember to update https://github.com/unbounce/homebrew-taps/blob/master/iidy.rb

.PHONY: bump_version_and_tag
bump_version_and_tag:
	@read -p 'What version would you like to release (eg. 1.0.0)? ' version; \
	echo "Setting version $$version..."; \
	npm set version "$$version"; \
	npm install; \
	echo "Committing, tagging, and pushing v$$version..."; \
	git add package.json package-lock.json; \
	git commit -m "v$$version"; \
	git tag -a "v$$version" -m "v$$version"; \
	git push origin "v$$version";

################################################################################
## Plumbing

$(PREREQS_STATEFILE) :
	@mkdir -p .make
	@echo '>>>' Checking that you have required system level dependencies
	@echo https://nodejs.org/en/
	@which node
	@touch $(PREREQS_STATEFILE)

$(DEPS_STATEFILE) : Makefile $(PREREQS_STATEFILE) package.json
	@mkdir -p .make
	npm install
	@touch $(DEPS_STATEFILE)

# TODO add intermediate pre-binaries build target and associated tests

$(BUILD_ARTIFACTS) : $(DEPS_STATEFILE) $(SRC_FILES)
	npm run build
	./node_modules/.bin/mocha -- lib/tests/
	bin/iidy help | grep argsfile > /dev/null
	npm run pkg-binaries

$(RELEASE_PACKAGES) : $(BUILD_ARTIFACTS)
	cd dist && \
	for OS in linux macos; do \
		cp iidy-$$OS iidy; \
		zip iidy-$${OS}-amd64.zip iidy;\
		shasum -p -a 256 iidy-$${OS}-amd64.zip; \
	done
	rm -f dist/iidy

$(TESTS_STATEFILE) : $(BUILD_ARTIFACTS) $(EXAMPLE_FILES)
# initial sanity checks:
ifeq ($(shell uname),Darwin)
	dist/iidy-macos help | grep argsfile > /dev/null
endif
# functional tests:
	mkdir -p dist/docker/
	cp dist/iidy-linux dist/docker/iidy
	cp Dockerfile.test dist/docker/Dockerfile
	cp Makefile.test dist/docker/Makefile
	cp -a examples dist/docker/
	docker build $(DOCKER_BUILD_ARGS) -t iidy-test dist/docker
	docker run --rm -it -v ~/.aws/:/root/.aws/ iidy-test make test
	touch $(TESTS_STATEFILE)

$(DOCKER_STATEFILE) : $(BUILD_ARTIFACTS) $(EXAMPLE_FILES)
	@rm -rf /tmp/iidy
	@git clone . /tmp/iidy

	docker build $(DOCKER_BUILD_ARGS) -t iidy-npm -f /tmp/iidy/Dockerfile.test-npm-build /tmp/iidy
	sleep 0.5
	docker run -it --rm iidy-npm help  > /dev/null
	docker rmi iidy-npm

	docker build $(DOCKER_BUILD_ARGS) -t iidy -f /tmp/iidy/Dockerfile /tmp/iidy
	sleep 0.5
	docker run -it --rm iidy help > /dev/null

## Yarn is currently broken for typescript 2.6.1 installs with iidy
#	docker build $(DOCKER_BUILD_ARGS) -t iidy-yarn -f /tmp/iidy/Dockerfile.test-yarn-build /tmp/iidy
#	sleep 0.5
#	docker run -it --rm iidy-yarn help > /dev/null
#	docker rmi iidy-yarn

	@rm -rf /tmp/iidy

check_working_dir_is_clean :
	@git diff --quiet --ignore-submodules HEAD || ( echo '\x1b[0;31mERROR: git workding dir not clean\x1b[0m'; false )
