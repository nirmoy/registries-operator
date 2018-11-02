SOURCES_DIRS      = cmd pkg
SOURCES_DIRS_GO   = ./pkg/... ./cmd/...
SOURCES_APIPS_DIR = ./pkg/apis/kubic

GO         := GO111MODULE=on GO15VENDOREXPERIMENT=1 go
GO_NOMOD   := GO111MODULE=off go
GO_VERSION := $(shell $(GO) version | sed -e 's/^[^0-9.]*\([0-9.]*\).*/\1/')

# go source files, ignore vendor directory
REGS_OPER_SRCS      = $(shell find $(SOURCES_DIRS) -type f -name '*.go' -not -path "*generated*")
REGS_OPER_MAIN_SRCS = $(shell find $(SOURCES_DIRS) -type f -name '*.go' -not -path "*_test.go")

REGS_OPER_GEN_SRCS       = $(shell grep -l -r "//go:generate" $(SOURCES_DIRS))
REGS_OPER_CRD_TYPES_SRCS = $(shell find $(SOURCES_APIPS_DIR) -type f -name "*_types.go")

REGS_OPER_EXE  = cmd/registries-operator/registries-operator
REGS_OPER_MAIN = cmd/registries-operator/main.go
.DEFAULT_GOAL: $(REGS_OPER_EXE)

IMAGE_BASENAME = registries-operator
IMAGE_NAME     = opensuse/$(IMAGE_BASENAME)
IMAGE_TAR_GZ   = $(IMAGE_BASENAME)-latest.tar.gz
IMAGE_DEPS     = $(REGS_OPER_EXE) Dockerfile

# should be non-empty when these exes are installed
DEP_EXE       := $(shell command -v dep 2> /dev/null)
KUSTOMIZE_EXE := $(shell command -v kustomize 2> /dev/null)

# These will be provided to the target
REGS_OPER_VERSION := 1.0.0
REGS_OPER_BUILD   := `git rev-parse HEAD 2>/dev/null`

# Use linker flags to provide version/build settings to the target
REGS_OPER_LDFLAGS = -ldflags "-X=main.Version=$(REGS_OPER_VERSION) -X=main.Build=$(REGS_OPER_BUILD)"

# sudo command (and version passing env vars)
SUDO = sudo
SUDO_E = $(SUDO) -E

# the default kubeconfig program generated by kubeadm (used for running things locally)
KUBECONFIG = /etc/kubernetes/admin.conf

# the deployment manifest for the operator
REGS_DEPLOY = deployments/registries-operator-full.yaml

# the kubebuilder generator
CONTROLLER_GEN     := sigs.k8s.io/controller-tools/cmd/controller-gen
CONTROLLER_GEN_EXE := $(shell basename $(CONTROLLER_GEN))

# CONTROLLER_GEN_RBAC_NAME = ":controller"

# increase to 8 for detailed kubeadm logs...
# Example: make local-run VERBOSE_LEVEL=8
VERBOSE_LEVEL = 5

CONTAINER_VOLUMES = \
        -v /sys/fs/cgroup:/sys/fs/cgroup \
        -v /var/run:/var/run

#############################################################
# Build targets
#############################################################

all: $(REGS_OPER_EXE)

deps: go.mod
	@echo ">>> Checking vendored deps..."
	@$(GO) mod download

generate: $(REGS_OPER_GEN_SRCS)
	@echo ">>> Getting deepcopy-gen..."
	@$(GO_NOMOD) get k8s.io/code-generator/cmd/deepcopy-gen
	@echo ">>> Generating files..."
	@$(GO) generate -x $(SOURCES_DIRS_GO)

# Create a new CRD object XXXXX with:
#    kubebuilder create api --namespaced=false --group kubic --version v1beta1 --kind XXXXX

kustomize-exe:
ifndef KUSTOMIZE_EXE
	@echo ">>> kustomize does not seem to be installed. installing kustomize..."
	$(GO) get sigs.k8s.io/kustomize
endif

#
# NOTE: we are currently not using the RBAC rules generated by kubebuilder:
#       we are just assigning the "cluster-admin" role to the manager (as we
#       must generate ClusterRoles/ClusterRoleBindings)
# TODO: investigate if we can reduce these privileges...
#
# manifests-rbac:
# 	@echo ">>> Creating RBAC manifests..."
# 	@rm -rf config/rbac/*.yaml
# 	@$(CONTROLLER_GEN_EXE) rbac --name $(CONTROLLER_GEN_RBAC_NAME)
#

manifests-crd: $(REGS_OPER_CRD_TYPES_SRCS)
	@echo ">>> Getting $(CONTROLLER_GEN_EXE)..."
	@$(GO_NOMOD) get $(CONTROLLER_GEN)
	@echo ">>> Creating CRDs manifests..."
	@rm -rf config/crds/*.yaml
	@$(CONTROLLER_GEN_EXE) crd --domain "opensuse.org"

$(REGS_DEPLOY): kustomize-exe manifests-crd
	@echo ">>> Collecting all the manifests for generating $(REGS_DEPLOY)..."
	@rm -f $(REGS_DEPLOY)
	@echo "#" >> $(REGS_DEPLOY)
	@echo "# DO NOT EDIT! Generated automatically with 'make $(REGS_DEPLOY)'" >> $(REGS_DEPLOY)
	@echo "#              from files in 'config/*'" >> $(REGS_DEPLOY)
	@echo "#" >> $(REGS_DEPLOY)
	@for i in config/sas/*.yaml config/crds/*.yaml ; do \
		echo -e "\n---" >> $(REGS_DEPLOY) ; \
		cat $$i >> $(REGS_DEPLOY) ; \
	done
	@echo -e "\n---" >> $(REGS_DEPLOY)
	@kustomize build config/default >> $(REGS_DEPLOY)

# Generate manifests e.g. CRD, RBAC etc.
manifests: $(REGS_DEPLOY)

$(REGS_OPER_EXE): $(REGS_OPER_MAIN_SRCS) deps generate
	@echo ">>> Building $(REGS_OPER_EXE)..."
	$(GO) build $(REGS_OPER_LDFLAGS) -o $(REGS_OPER_EXE) $(REGS_OPER_MAIN)

.PHONY: fmt
fmt: $(REGS_OPER_SRCS)
	@echo ">>> Reformatting code"
	@go fmt $(SOURCES_DIRS_GO)

.PHONY: simplify
simplify:
	@gofmt -s -l -w $(REGS_OPER_SRCS)

.PHONY: check
check:
	@test -z $(shell gofmt -l $(REGS_OPER_MAIN) | tee /dev/stderr) || echo "[WARN] Fix formatting issues with 'make fmt'"
	@for d in $$(go list ./... | grep -v /vendor/); do golint $${d}; done
	@$(GO) tool vet ${REGS_OPER_SRCS}

.PHONY: test
test:
	@go test -v $(SOURCE_DIRS_GO) -coverprofile cover.out

.PHONY: check
clean: docker-image-clean
	rm -f $(REGS_OPER_EXE)
	rm -rf `find . -name zz_generated.deepcopy.go`

#############################################################
# Some simple run targets
# (for testing things locally)
#############################################################

# assuming the k8s cluster is accessed with $(KUBECONFIG),
# deploy the registries-operator manifest file in this cluster.
local-deploy: $(REGS_DEPLOY) docker-image-local
	@echo ">>> (Re)deploying..."
	@[ -r $(KUBECONFIG) ] || $(SUDO_E) chmod 644 $(KUBECONFIG)
	@echo ">>> Deleting any previous resources..."
	-@kubectl get ldapconnectors -o jsonpath="{..metadata.name}" | \
		xargs -r kubectl delete --all=true ldapconnector 2>/dev/null
	-@kubectl get dexconfigurations -o jsonpath="{..metadata.name}" | \
		xargs -r kubectl delete --all=true dexconfiguration 2>/dev/null
	@sleep 30
	-@kubectl delete --all=true --cascade=true -f $(REGS_DEPLOY) 2>/dev/null
	@echo ">>> Regenerating manifests..."
	@make manifests
	@echo ">>> Loading manifests..."
	kubectl apply --kubeconfig $(KUBECONFIG) -f $(REGS_DEPLOY)

clean-local-deploy:
	@make manifests
	@echo ">>> Uninstalling manifests..."
	kubectl delete --kubeconfig $(KUBECONFIG) -f $(REGS_DEPLOY)

# Usage:
# - Run it locally:
#   make local-run VERBOSE_LEVEL=5
# - Start a Deployment with the manager:
#   make local-run EXTRA_ARGS="--"
#
local-run: $(REGS_OPER_EXE) manifests
	[ -r $(KUBECONFIG) ] || $(SUDO_E) chmod 644 $(KUBECONFIG)
	@echo ">>> Running $(REGS_OPER_EXE) as _root_"
	$(REGS_OPER_EXE) manager \
		-v $(VERBOSE_LEVEL) \
		--kubeconfig /etc/kubernetes/admin.conf \
		$(EXTRA_ARGS)

docker-run: $(IMAGE_TAR_GZ)
	@echo ">>> Running $(IMAGE_NAME):latest in the local Docker"
	docker run -it --rm \
		--privileged=true \
		--net=host \
		--security-opt seccomp:unconfined \
		--cap-add=SYS_ADMIN \
		--name=$(IMAGE_BASENAME) \
		$(CONTAINER_VOLUMES) \
		$(IMAGE_NAME):latest $(EXTRA_ARGS)

local-$(IMAGE_TAR_GZ): $(REGS_OPER_EXE)
	@echo ">>> Creating Docker image (Local build)..."
	docker build -f Dockerfile.local \
		--build-arg BUILT_EXE=$(REGS_OPER_EXE) \
		-t $(IMAGE_NAME):latest .
	@echo ">>> Creating tar for image (Local build)"
	docker save $(IMAGE_NAME):latest | gzip > local-$(IMAGE_TAR_GZ)

docker-image-local: local-$(IMAGE_TAR_GZ)

$(IMAGE_TAR_GZ):
	@echo ">>> Creating Docker image..."
	docker build -t $(IMAGE_NAME):latest .
	@echo ">>> Creating tar for image..."
	docker save $(IMAGE_NAME):latest | gzip > $(IMAGE_TAR_GZ)

docker-image: $(IMAGE_TAR_GZ)
docker-image-clean:
	rm -f $(IMAGE_TAR_GZ)
	-docker rmi $(IMAGE_NAME)


#############################################################
# Other stuff
#############################################################

-include Makefile.local
