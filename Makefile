# ─────────────────────────────────────────────────────────────────────────────
# billpreview — Makefile
# zig cc is a clang passthrough with bundled musl + target sysroot
# ─────────────────────────────────────────────────────────────────────────────

# ── Detect host ───────────────────────────────────────────────────────────────
HOST_ARCH := $(shell uname -m)
HOST_OS   := $(shell uname -s)

# ── Toolchains ────────────────────────────────────────────────────────────────
ifeq ($(HOST_OS), Darwin)
    CXX_NATIVE := clang++
else
    CXX_NATIVE := g++
endif

# zig c++ — target passed per variant below
ZIG := zig c++

# ── Paths ─────────────────────────────────────────────────────────────────────
SRC_DIR    := src
GEN_DIR    := $(SRC_DIR)/gen
VENDOR_DIR := $(SRC_DIR)/vendor
ASSET_DIR  := assets
OUT_DIR    := out

SRCS := $(SRC_DIR)/main.cpp \
        $(SRC_DIR)/stb_impl.cpp

FONT_FRAUNCES  := $(ASSET_DIR)/Fraunces-Bold.ttf
FONT_DMMONO    := $(ASSET_DIR)/DMMono-Medium.ttf

HDR_FRAUNCES   := $(GEN_DIR)/font_fraunces.h
HDR_DMMONO     := $(GEN_DIR)/font_dmmono.h
GENERATED      := $(HDR_FRAUNCES) $(HDR_DMMONO)

# ── Common flags (all builds) ─────────────────────────────────────────────────
CXXSTD   := -std=c++20
WARNINGS := -Wall -Wextra -Wno-unused-parameter
INCLUDES := -I$(GEN_DIR) -I$(VENDOR_DIR) -I$(SRC_DIR)

# ── Dev flags ─────────────────────────────────────────────────────────────────
ifeq ($(HOST_ARCH), arm64)
    ARCH_NATIVE := -march=native -mcpu=native
else
    ARCH_NATIVE := -march=native
endif

CXXFLAGS_DEV := $(CXXSTD) $(WARNINGS) $(INCLUDES) \
                -O0 -g -fno-omit-frame-pointer $(ARCH_NATIVE)
LDFLAGS_DEV  :=

# ── San flags ─────────────────────────────────────────────────────────────────
CXXFLAGS_SAN := $(CXXSTD) $(WARNINGS) $(INCLUDES) \
                -O1 -g -fno-omit-frame-pointer \
                -fsanitize=address,undefined $(ARCH_NATIVE)
LDFLAGS_SAN  := -fsanitize=address,undefined

# ── Release base flags (shared across all variants) ───────────────────────────
CXXFLAGS_REL_BASE := $(CXXSTD) $(WARNINGS) $(INCLUDES) \
                     -O3 -ffast-math -funroll-loops \
                     -fomit-frame-pointer -fno-exceptions -flto
LDFLAGS_REL       := -static -flto

# ─────────────────────────────────────────────────────────────────────────────
# Release variants
#
# Naming: billpreview-<arch>-<variant>
# Pull in docker-compose:
#   RUN curl -fsSL http://your-host/billpreview-x86_64-v4-znver4
#
# ── x86_64 variants ───────────────────────────────────────────────────────────
#
#   generic    x86-64-v3   AVX2, no AVX-512. Safe for any post-2015 server.
#   v4         x86-64-v4   AVX-512. Modern Xeon Scalable / EPYC Genoa+.
#   znver4     x86-64-v4   Tuned for AMD EPYC Genoa (zen4). AWS c7a, Hetzner AX.
#   znver3     x86-64-v4   Tuned for AMD EPYC Milan (zen3). Common in cloud.
#   spr        x86-64-v4   Tuned for Intel Sapphire Rapids (Xeon 4th gen).
#   skx        x86-64-v3   Tuned for Intel Skylake-X / older Xeon. No AVX-512.
#
# ── arm64 variants ────────────────────────────────────────────────────────────
#
#   generic    armv8-a     Baseline ARM64. Any server.
#   graviton2  neoverse-n1 AWS Graviton2 (c6g/m6g/r6g).
#   graviton3  neoverse-v1 AWS Graviton3 (c7g/m7g/r7g). SVE enabled.
#   ampere     ampere1     Ampere Altra. OCI, Azure Cobalt, some Hetzner.
#
# ─────────────────────────────────────────────────────────────────────────────

# zig target triples
ZIG_X86   := x86_64-linux-musl
ZIG_ARM64 := aarch64-linux-musl

# helper — build one release variant
# $(call release_variant, suffix, zig-triple, arch-flags)
define release_variant
$(OUT_DIR)/billpreview-$(1): $(GENERATED) | $(OUT_DIR)
	$(ZIG) -target $(2) \
	    $(CXXFLAGS_REL_BASE) $(3) \
	    -o $$@ $(SRCS) $(LDFLAGS_REL)
	@printf "  ✓ %-40s $$(shell ls -lh $$@ | awk '{print $$5}')\n" "billpreview-$(1)"
endef

# ── x86_64 variants ───────────────────────────────────────────────────────────
$(eval $(call release_variant,\
    x86_64-generic,\
    $(ZIG_X86),\
    -march=x86-64-v3 -mtune=generic))

$(eval $(call release_variant,\
    x86_64-v4,\
    $(ZIG_X86),\
    -march=x86-64-v4 -mavx512f -mavx512bw -mavx512dq -mavx512vl -mtune=generic))

$(eval $(call release_variant,\
    x86_64-v4-znver4,\
    $(ZIG_X86),\
    -march=x86-64-v4 -mavx512f -mavx512bw -mavx512dq -mavx512vl -mtune=znver4))

$(eval $(call release_variant,\
    x86_64-v4-znver3,\
    $(ZIG_X86),\
    -march=x86-64-v4 -mavx512f -mavx512bw -mavx512dq -mavx512vl -mtune=znver3))

$(eval $(call release_variant,\
    x86_64-v4-spr,\
    $(ZIG_X86),\
    -march=x86-64-v4 -mavx512f -mavx512bw -mavx512dq -mavx512vl -mtune=sapphirerapids))

$(eval $(call release_variant,\
    x86_64-v3-skx,\
    $(ZIG_X86),\
    -march=x86-64-v3 -mtune=skylake))

# ── arm64 variants ────────────────────────────────────────────────────────────
$(eval $(call release_variant,\
    arm64-generic,\
    $(ZIG_ARM64),\
    -march=armv8-a -mtune=generic))

$(eval $(call release_variant,\
    arm64-graviton2,\
    $(ZIG_ARM64),\
    -march=armv8.2-a -mcpu=neoverse-n1 -mtune=neoverse-n1))

$(eval $(call release_variant,\
    arm64-graviton3,\
    $(ZIG_ARM64),\
    -march=armv8.4-a+sve -mcpu=neoverse-v1 -mtune=neoverse-v1))

$(eval $(call release_variant,\
    arm64-ampere,\
    $(ZIG_ARM64),\
    -march=armv8.6-a -mcpu=ampere1 -mtune=ampere1))

# ── Collect all release targets ───────────────────────────────────────────────
RELEASE_TARGETS := \
    $(OUT_DIR)/billpreview-x86_64-generic    \
    $(OUT_DIR)/billpreview-x86_64-v4         \
    $(OUT_DIR)/billpreview-x86_64-v4-znver4  \
    $(OUT_DIR)/billpreview-x86_64-v4-znver3  \
    $(OUT_DIR)/billpreview-x86_64-v4-spr     \
    $(OUT_DIR)/billpreview-x86_64-v3-skx     \
    $(OUT_DIR)/billpreview-arm64-generic     \
    $(OUT_DIR)/billpreview-arm64-graviton2   \
    $(OUT_DIR)/billpreview-arm64-graviton3   \
    $(OUT_DIR)/billpreview-arm64-ampere

# ─────────────────────────────────────────────────────────────────────────────
.PHONY: all dev san release clean info

all: dev

# ── Directories ───────────────────────────────────────────────────────────────
$(GEN_DIR) $(OUT_DIR):
	mkdir -p $@

# ── Asset pipeline ────────────────────────────────────────────────────────────
$(HDR_FRAUNCES): $(FONT_FRAUNCES) | $(GEN_DIR)
	xxd -i $< > $@
	@echo "[xxd] $< → $@"

$(HDR_DMMONO): $(FONT_DMMONO) | $(GEN_DIR)
	xxd -i $< > $@
	@echo "[xxd] $< → $@"

# ── Dev ───────────────────────────────────────────────────────────────────────
dev: $(GENERATED) | $(OUT_DIR)
	$(CXX_NATIVE) $(CXXFLAGS_DEV) -o $(OUT_DIR)/billpreview $(SRCS) $(LDFLAGS_DEV)
	@echo ""
	@echo "  ✓ dev  $(OUT_DIR)/billpreview  [$(HOST_ARCH) / $(HOST_OS)]"
	@ls -lh $(OUT_DIR)/billpreview

# ── San ───────────────────────────────────────────────────────────────────────
san: $(GENERATED) | $(OUT_DIR)
	$(CXX_NATIVE) $(CXXFLAGS_SAN) -o $(OUT_DIR)/billpreview-san $(SRCS) $(LDFLAGS_SAN)
	@echo ""
	@echo "  ✓ san  $(OUT_DIR)/billpreview-san  [asan + ubsan]"
	@ls -lh $(OUT_DIR)/billpreview-san

# ── Release — all variants ────────────────────────────────────────────────────
release: $(GENERATED) | $(OUT_DIR)
	@echo ""
	@echo "building release variants..."
	@echo ""
	@$(MAKE) --no-print-directory $(RELEASE_TARGETS)
	@echo ""
	@echo "── x86_64 ───────────────────────────────"
	@ls -lh $(OUT_DIR)/billpreview-x86_64-* 2>/dev/null | awk '{print "  "$$5"  "$$9}'
	@echo "── arm64 ────────────────────────────────"
	@ls -lh $(OUT_DIR)/billpreview-arm64-*  2>/dev/null | awk '{print "  "$$5"  "$$9}'
	@echo ""

# ── Info ──────────────────────────────────────────────────────────────────────
info:
	@echo "host arch  : $(HOST_ARCH)"
	@echo "host os    : $(HOST_OS)"
	@echo "native cxx : $(CXX_NATIVE)"
	@echo "arch flags : $(ARCH_NATIVE)"
	@echo ""
	@echo "release variants:"
	@$(foreach t,$(RELEASE_TARGETS),echo "  $(t)";)

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -rf $(GEN_DIR) $(OUT_DIR)