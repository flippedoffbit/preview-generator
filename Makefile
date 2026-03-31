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
        $(SRC_DIR)/themes.cpp \
        $(SRC_DIR)/glyph_cache.cpp \
        $(SRC_DIR)/stb_impl.cpp \
        $(SRC_DIR)/vendor/fpng.cpp

FONT_FRAUNCES := $(ASSET_DIR)/Fraunces-Bold.ttf
FONT_DMMONO   := $(ASSET_DIR)/DMMono-Medium.ttf
FONT_INTER    := $(ASSET_DIR)/Inter-VariableFont_opsz,wght.ttf

HDR_FRAUNCES  := $(GEN_DIR)/font_fraunces.h
HDR_DMMONO    := $(GEN_DIR)/font_dmmono.h
HDR_INTER     := $(GEN_DIR)/font_inter.h
GENERATED     := $(HDR_FRAUNCES) $(HDR_DMMONO) $(HDR_INTER)

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
                -O2 -g -fno-omit-frame-pointer $(ARCH_NATIVE)
LDFLAGS_DEV  :=

# ── Mac optimised flags ───────────────────────────────────────────────────────
CXXFLAGS_MAC := $(CXXSTD) $(WARNINGS) $(INCLUDES) \
                -Ofast -funroll-loops -fvectorize \
                -fomit-frame-pointer -fno-rtti \
                -flto -fwhole-program-vtables \
                -fstrict-aliasing -fstrict-overflow \
                -fmerge-all-constants \
                -fdata-sections -ffunction-sections \
                -mllvm -inline-threshold=500 \
                -mcpu=apple-m4 \
				-funsafe-math-optimizations \
				-ffp-contract=fast \
				-fno-signed-zeros -fno-trapping-math -freciprocal-math \
                -fno-math-errno

LDFLAGS_MAC  := -flto -dead_strip

# ── San flags ─────────────────────────────────────────────────────────────────
CXXFLAGS_SAN := $(CXXSTD) $(WARNINGS) $(INCLUDES) \
                -O1 -g -fno-omit-frame-pointer \
                -fsanitize=address,undefined $(ARCH_NATIVE)
LDFLAGS_SAN  := -fsanitize=address,undefined

# ── Release base flags ────────────────────────────────────────────────────────
# -ffast-math                    safe for PNG rendering, no NaN/Inf needed
# -fno-exceptions / -fno-rtti    we don't use either; saves unwinding tables + rodata
# -fvisibility=hidden            keeps internals out of export table; better LTO
# -fno-unwind-tables             no .eh_frame; daemon never needs to unwind
# -fmerge-all-constants          merge identical string/float literals across TUs
# -fdata/function-sections       linker can dead-strip unused symbols
# -mllvm -inline-threshold=500   more aggressive inlining than default 225
# -Wl,--gc-sections              actually perform the dead-strip at link time
# -mpclmul                       CRC32 acceleration used by fpng (x86 only)
CXXFLAGS_REL_BASE := $(CXXSTD) $(WARNINGS) $(INCLUDES) \
                     -Ofast \
                     -funroll-loops -fvectorize \
                     -fomit-frame-pointer \
                     -fno-rtti \
                     -fvisibility=hidden \
                     -fno-unwind-tables -fno-asynchronous-unwind-tables \
                     -fmerge-all-constants \
                     -fdata-sections -ffunction-sections \
                     -flto=thin \
                     -mllvm -inline-threshold=1000 \
                     -funsafe-math-optimizations \
                     -ffp-contract=fast \
                     -fno-signed-zeros -fno-trapping-math -freciprocal-math \
                     -floop-interchange \
                     -fno-math-errno

LDFLAGS_REL := -static -flto -Wl,--gc-sections

# ── Profile Guided Optimisation (PGO) ────────────────────────────────────────
# Local workflow (native host):
# 1) make pgo-instrument-local   — build an instrumented binary
# 2) make pgo-run-local          — run the instrumented binary against test cases
# 3) make pgo-merge             — merge .profraw → .profdata (requires llvm-profdata)
# 4) make pgo-opt-local         — rebuild optimized binary using the collected profile

PGO_DIR        := $(OUT_DIR)/pgo
PGO_PROFDATA   := $(PGO_DIR)/default.profdata

# Instrumented build (no LTO, gather runtime profiles)
CXXFLAGS_PGO_INSTR := $(CXXSTD) $(WARNINGS) $(INCLUDES) \
					  -fprofile-instr-generate -O2 -g $(ARCH_NATIVE)
LDFLAGS_PGO_INSTR  :=

# Optimised build using collected profile data (uses release base flags)
CXXFLAGS_PGO_USE := $(CXXFLAGS_REL_BASE) -fprofile-instr-use=$(PGO_PROFDATA)
LDFLAGS_PGO_USE  := $(LDFLAGS_REL)


# ─────────────────────────────────────────────────────────────────────────────
# Protocol flag legend
#   (empty)       Legacy tab-delimited UDS  — default, Go daemon talks to this
#   -DPROTO_HTTP  Bare HTTP/1.0 over UDS    — nginx proxy_pass unix:...
#   -DPROTO_FCGI  FastCGI over UDS          — nginx fastcgi_pass unix:...
# ─────────────────────────────────────────────────────────────────────────────

# ── release_variant macro ─────────────────────────────────────────────────────
# $(call release_variant, suffix, zig-triple, arch-flags, proto-flag)
# proto-flag is optional — pass empty string for legacy UDS
define release_variant
$(OUT_DIR)/billpreview-$(strip $(1)): $(GENERATED) | $(OUT_DIR)
	$(ZIG) -target $(strip $(2)) \
		$(CXXFLAGS_REL_BASE) $(strip $(3)) $(strip $(4)) \
		-o $$@ $(SRCS) $(LDFLAGS_REL)
	@printf "  ✓ %-44s %s\n" "billpreview-$(strip $(1))" "$$(ls -lh $$@ | awk '{print $$5}')"
endef

# ── Zig target triples ────────────────────────────────────────────────────────
ZIG_X86   := x86_64-linux-musl
ZIG_ARM64 := aarch64-linux-musl

# ─────────────────────────────────────────────────────────────────────────────
# x86_64 variants
#   generic   x86-64-v3        AVX2, no AVX-512. Safe for any post-2015 server.
#   v4        x86-64-v4        AVX-512. Modern Xeon Scalable / EPYC Genoa+.
#   znver4    zen4 tuned       AMD EPYC Genoa. AWS c7a, Hetzner AX162.
#   znver3    zen3 tuned       AMD EPYC Milan. Common in cloud.
#   spr       sapphirerapids   Intel Sapphire Rapids (Xeon 4th gen).
#   skx       skylake          Intel Skylake-X / older Xeon. No AVX-512.
# ─────────────────────────────────────────────────────────────────────────────
$(eval $(call release_variant, x86_64-generic,        $(ZIG_X86), -mcpu=x86_64_v3 -mpclmul,      ))
$(eval $(call release_variant, x86_64-generic-http,   $(ZIG_X86), -mcpu=x86_64_v3 -mpclmul,      -DPROTO_HTTP))
$(eval $(call release_variant, x86_64-generic-fcgi,   $(ZIG_X86), -mcpu=x86_64_v3 -mpclmul,      -DPROTO_FCGI))

$(eval $(call release_variant, x86_64-v4,             $(ZIG_X86), -mcpu=x86_64_v4 -mpclmul,      ))
$(eval $(call release_variant, x86_64-v4-http,        $(ZIG_X86), -mcpu=x86_64_v4 -mpclmul,      -DPROTO_HTTP))
$(eval $(call release_variant, x86_64-v4-fcgi,        $(ZIG_X86), -mcpu=x86_64_v4 -mpclmul,      -DPROTO_FCGI))

$(eval $(call release_variant, x86_64-v4-znver4,      $(ZIG_X86), -mcpu=znver4 -mpclmul,         ))
$(eval $(call release_variant, x86_64-v4-znver4-http, $(ZIG_X86), -mcpu=znver4 -mpclmul,         -DPROTO_HTTP))
$(eval $(call release_variant, x86_64-v4-znver4-fcgi, $(ZIG_X86), -mcpu=znver4 -mpclmul,         -DPROTO_FCGI))

$(eval $(call release_variant, x86_64-v4-znver3,      $(ZIG_X86), -mcpu=znver3 -mpclmul,         ))
$(eval $(call release_variant, x86_64-v4-znver3-http, $(ZIG_X86), -mcpu=znver3 -mpclmul,         -DPROTO_HTTP))
$(eval $(call release_variant, x86_64-v4-znver3-fcgi, $(ZIG_X86), -mcpu=znver3 -mpclmul,         -DPROTO_FCGI))

$(eval $(call release_variant, x86_64-v4-spr,         $(ZIG_X86), -mcpu=sapphirerapids -mpclmul, ))
$(eval $(call release_variant, x86_64-v4-spr-http,    $(ZIG_X86), -mcpu=sapphirerapids -mpclmul, -DPROTO_HTTP))
$(eval $(call release_variant, x86_64-v4-spr-fcgi,    $(ZIG_X86), -mcpu=sapphirerapids -mpclmul, -DPROTO_FCGI))

$(eval $(call release_variant, x86_64-v3-skx,         $(ZIG_X86), -mcpu=skylake -mpclmul,        ))
$(eval $(call release_variant, x86_64-v3-skx-http,    $(ZIG_X86), -mcpu=skylake -mpclmul,        -DPROTO_HTTP))
$(eval $(call release_variant, x86_64-v3-skx-fcgi,    $(ZIG_X86), -mcpu=skylake -mpclmul,        -DPROTO_FCGI))

# ─────────────────────────────────────────────────────────────────────────────
# arm64 variants
#   generic    armv8-a       Baseline ARM64. Any server.
#   graviton2  neoverse-n1   AWS Graviton2 (c6g/m6g/r6g).
#   graviton3  neoverse-v1   AWS Graviton3 (c7g/m7g/r7g). SVE enabled.
#   ampere     ampere1       Ampere Altra. OCI, Azure Cobalt, some Hetzner.
# ─────────────────────────────────────────────────────────────────────────────
$(eval $(call release_variant, arm64-generic,          $(ZIG_ARM64), -mcpu=generic,      ))
$(eval $(call release_variant, arm64-generic-http,     $(ZIG_ARM64), -mcpu=generic,      -DPROTO_HTTP))
$(eval $(call release_variant, arm64-generic-fcgi,     $(ZIG_ARM64), -mcpu=generic,      -DPROTO_FCGI))

$(eval $(call release_variant, arm64-graviton2,        $(ZIG_ARM64), -mcpu=neoverse_n1,  ))
$(eval $(call release_variant, arm64-graviton2-http,   $(ZIG_ARM64), -mcpu=neoverse_n1,  -DPROTO_HTTP))
$(eval $(call release_variant, arm64-graviton2-fcgi,   $(ZIG_ARM64), -mcpu=neoverse_n1,  -DPROTO_FCGI))

$(eval $(call release_variant, arm64-graviton3,        $(ZIG_ARM64), -mcpu=neoverse_v1,  ))
$(eval $(call release_variant, arm64-graviton3-http,   $(ZIG_ARM64), -mcpu=neoverse_v1,  -DPROTO_HTTP))
$(eval $(call release_variant, arm64-graviton3-fcgi,   $(ZIG_ARM64), -mcpu=neoverse_v1,  -DPROTO_FCGI))

$(eval $(call release_variant, arm64-ampere,           $(ZIG_ARM64), -mcpu=ampere1,      ))
$(eval $(call release_variant, arm64-ampere-http,      $(ZIG_ARM64), -mcpu=ampere1,      -DPROTO_HTTP))
$(eval $(call release_variant, arm64-ampere-fcgi,      $(ZIG_ARM64), -mcpu=ampere1,      -DPROTO_FCGI))

# ── macOS arm64 — system clang, all proto variants ────────────────────────────
$(OUT_DIR)/billpreview-mac-arm64: $(GENERATED) | $(OUT_DIR)
	$(CXX_NATIVE) $(CXXFLAGS_MAC) -o $@ $(SRCS) $(LDFLAGS_MAC)
	@strip $@
	@printf "  ✓ %-44s %s\n" "billpreview-mac-arm64" "$$(ls -lh $@ | awk '{print $$5}')"

$(OUT_DIR)/billpreview-mac-arm64-http: $(GENERATED) | $(OUT_DIR)
	$(CXX_NATIVE) $(CXXFLAGS_MAC) -DPROTO_HTTP -o $@ $(SRCS) $(LDFLAGS_MAC)
	@strip $@
	@printf "  ✓ %-44s %s\n" "billpreview-mac-arm64-http" "$$(ls -lh $@ | awk '{print $$5}')"

$(OUT_DIR)/billpreview-mac-arm64-fcgi: $(GENERATED) | $(OUT_DIR)
	$(CXX_NATIVE) $(CXXFLAGS_MAC) -DPROTO_FCGI -o $@ $(SRCS) $(LDFLAGS_MAC)
	@strip $@
	@printf "  ✓ %-44s %s\n" "billpreview-mac-arm64-fcgi" "$$(ls -lh $@ | awk '{print $$5}')"

# ── Release target lists ──────────────────────────────────────────────────────
RELEASE_UDS := \
	$(OUT_DIR)/billpreview-x86_64-generic    \
	$(OUT_DIR)/billpreview-x86_64-v4         \
	$(OUT_DIR)/billpreview-x86_64-v4-znver4  \
	$(OUT_DIR)/billpreview-x86_64-v4-znver3  \
	$(OUT_DIR)/billpreview-x86_64-v4-spr     \
	$(OUT_DIR)/billpreview-x86_64-v3-skx     \
	$(OUT_DIR)/billpreview-arm64-generic     \
	$(OUT_DIR)/billpreview-arm64-graviton2   \
	$(OUT_DIR)/billpreview-arm64-graviton3   \
	$(OUT_DIR)/billpreview-arm64-ampere      \
	$(OUT_DIR)/billpreview-mac-arm64

RELEASE_HTTP := \
	$(OUT_DIR)/billpreview-x86_64-generic-http    \
	$(OUT_DIR)/billpreview-x86_64-v4-http         \
	$(OUT_DIR)/billpreview-x86_64-v4-znver4-http  \
	$(OUT_DIR)/billpreview-x86_64-v4-znver3-http  \
	$(OUT_DIR)/billpreview-x86_64-v4-spr-http     \
	$(OUT_DIR)/billpreview-x86_64-v3-skx-http     \
	$(OUT_DIR)/billpreview-arm64-generic-http     \
	$(OUT_DIR)/billpreview-arm64-graviton2-http   \
	$(OUT_DIR)/billpreview-arm64-graviton3-http   \
	$(OUT_DIR)/billpreview-arm64-ampere-http      \
	$(OUT_DIR)/billpreview-mac-arm64-http

RELEASE_FCGI := \
	$(OUT_DIR)/billpreview-x86_64-generic-fcgi    \
	$(OUT_DIR)/billpreview-x86_64-v4-fcgi         \
	$(OUT_DIR)/billpreview-x86_64-v4-znver4-fcgi  \
	$(OUT_DIR)/billpreview-x86_64-v4-znver3-fcgi  \
	$(OUT_DIR)/billpreview-x86_64-v4-spr-fcgi     \
	$(OUT_DIR)/billpreview-x86_64-v3-skx-fcgi     \
	$(OUT_DIR)/billpreview-arm64-generic-fcgi     \
	$(OUT_DIR)/billpreview-arm64-graviton2-fcgi   \
	$(OUT_DIR)/billpreview-arm64-graviton3-fcgi   \
	$(OUT_DIR)/billpreview-arm64-ampere-fcgi      \
	$(OUT_DIR)/billpreview-mac-arm64-fcgi

RELEASE_ALL := $(RELEASE_UDS) $(RELEASE_HTTP) $(RELEASE_FCGI)

# ─────────────────────────────────────────────────────────────────────────────
.PHONY: all dev mac san prof \
        release release-uds release-http release-fcgi \
        _release_summary clean info

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

$(HDR_INTER): $(FONT_INTER) | $(GEN_DIR)
	xxd -i $< > $@
	@echo "[xxd] $< → $@"

# ── Dev ───────────────────────────────────────────────────────────────────────
dev: $(GENERATED) | $(OUT_DIR)
	$(CXX_NATIVE) $(CXXFLAGS_DEV) -o $(OUT_DIR)/billpreview $(SRCS) $(LDFLAGS_DEV)
	@echo ""
	@echo "  ✓ dev  $(OUT_DIR)/billpreview  [$(HOST_ARCH) / $(HOST_OS)]"
	@ls -lh $(OUT_DIR)/billpreview

# ── Mac optimised ─────────────────────────────────────────────────────────────
mac: $(GENERATED) | $(OUT_DIR)
	$(CXX_NATIVE) $(CXXFLAGS_MAC) -o $(OUT_DIR)/billpreview-mac $(SRCS) $(LDFLAGS_MAC)
	@strip $(OUT_DIR)/billpreview-mac
	@echo ""
	@echo "  ✓ mac  $(OUT_DIR)/billpreview-mac  [$(HOST_ARCH) / $(HOST_OS) optimised]"
	@ls -lh $(OUT_DIR)/billpreview-mac

# ── San ───────────────────────────────────────────────────────────────────────
san: $(GENERATED) | $(OUT_DIR)
	$(CXX_NATIVE) $(CXXFLAGS_SAN) -o $(OUT_DIR)/billpreview-san $(SRCS) $(LDFLAGS_SAN)
	@echo ""
	@echo "  ✓ san  $(OUT_DIR)/billpreview-san  [asan + ubsan]"
	@ls -lh $(OUT_DIR)/billpreview-san

# ── Prof ──────────────────────────────────────────────────────────────────────
prof: $(GENERATED) | $(OUT_DIR)
	$(CXX_NATIVE) $(CXXFLAGS_MAC) -DPROFILE -o $(OUT_DIR)/billpreview-prof $(SRCS) $(LDFLAGS_MAC)
	@strip $(OUT_DIR)/billpreview-prof
	@echo ""
	@echo "  ✓ prof  $(OUT_DIR)/billpreview-prof  [profiling build]"

# ── PGO workflow (local/native) ──────────────────────────────────────────────
.PHONY: pgo pgo-instrument-local pgo-run-local pgo-merge pgo-opt-local

$(PGO_DIR):
	mkdir -p $@

pgo-instrument-local: $(GENERATED) | $(OUT_DIR) $(PGO_DIR)
	$(CXX_NATIVE) $(CXXFLAGS_PGO_INSTR) -o $(OUT_DIR)/billpreview-pgo-instr $(SRCS) $(LDFLAGS_PGO_INSTR)
	@echo ""
	@printf "  ✓ pgo-instrument-local  %s\n" $(OUT_DIR)/billpreview-pgo-instr

# Run the instrumented binary through the test harness to produce .profraw files.
pgo-run-local: pgo-instrument-local
	@echo "running instrumented binary to collect profiles in $(PGO_DIR)..."
	@mkdir -p $(PGO_DIR)
	@LLVM_PROFILE_FILE="$(PGO_DIR)/profile-%p.profraw" bash ./test.sh $(OUT_DIR)/billpreview-pgo-instr
	@echo "collected profile data in $(PGO_DIR)"

# Merge raw profiles into a single profdata file (requires llvm-profdata)
pgo-merge:
	@if command -v llvm-profdata >/dev/null 2>&1; then \
		echo "merging profraw → $(PGO_PROFDATA)..."; \
		llvm-profdata merge -o $(PGO_PROFDATA) $(PGO_DIR)/*.profraw; \
		ls -lh $(PGO_PROFDATA); \
	else \
		echo "llvm-profdata not found; install llvm (e.g. 'brew install llvm' or use system llvm)"; exit 1; \
	fi

# Build an optimized binary using the collected profile data
pgo-opt-local: $(GENERATED) | $(OUT_DIR)
	@if [ -f $(PGO_PROFDATA) ]; then \
		echo "building PGO-optimised binary..."; \
		$(CXX_NATIVE) $(CXXFLAGS_PGO_USE) -o $(OUT_DIR)/billpreview-pgo-opt $(SRCS) $(LDFLAGS_PGO_USE); \
		strip $(OUT_DIR)/billpreview-pgo-opt || true; \
		printf "  ✓ pgo-opt-local %s\n" $(OUT_DIR)/billpreview-pgo-opt; \
	else \
		echo "missing $(PGO_PROFDATA) — run 'make pgo-run-local' then 'make pgo-merge'"; exit 1; \
	fi

# Convenience target: run the full PGO flow (instrument → run → merge → opt)
pgo: pgo-run-local pgo-merge pgo-opt-local
	@echo "PGO flow complete. Optimised binary: $(OUT_DIR)/billpreview-pgo-opt"

# ── Release — focused proto targets ───────────────────────────────────────────
release-uds: $(GENERATED) | $(OUT_DIR)
	@echo ""
	@echo "building UDS (tab-delimited) variants..."
	@echo ""
	@$(MAKE) --no-print-directory $(RELEASE_UDS)
	@$(MAKE) --no-print-directory _release_summary

release-http: $(GENERATED) | $(OUT_DIR)
	@echo ""
	@echo "building HTTP variants..."
	@echo ""
	@$(MAKE) --no-print-directory $(RELEASE_HTTP)
	@$(MAKE) --no-print-directory _release_summary

release-fcgi: $(GENERATED) | $(OUT_DIR)
	@echo ""
	@echo "building FCGI variants..."
	@echo ""
	@$(MAKE) --no-print-directory $(RELEASE_FCGI)
	@$(MAKE) --no-print-directory _release_summary

release: $(GENERATED) | $(OUT_DIR)
	@echo ""
	@echo "building all variants (UDS + HTTP + FCGI)..."
	@echo ""
	@$(MAKE) --no-print-directory $(RELEASE_ALL)
	@$(MAKE) --no-print-directory _release_summary

# ── Summary helper (internal) ─────────────────────────────────────────────────
_release_summary:
	@echo ""
	@echo "── x86_64 ────────────────────────────────────────────────"
	@ls -lh $(OUT_DIR)/billpreview-x86_64-* 2>/dev/null | awk '{print "  "$$5"  "$$9}'
	@echo "── arm64 ─────────────────────────────────────────────────"
	@ls -lh $(OUT_DIR)/billpreview-arm64-*  2>/dev/null | awk '{print "  "$$5"  "$$9}'
	@echo "── macOS arm64 ───────────────────────────────────────────"
	@ls -lh $(OUT_DIR)/billpreview-mac-arm64* 2>/dev/null | awk '{print "  "$$5"  "$$9}'
	@echo ""

# ── Info ──────────────────────────────────────────────────────────────────────
info:
	@echo "host arch  : $(HOST_ARCH)"
	@echo "host os    : $(HOST_OS)"
	@echo "native cxx : $(CXX_NATIVE)"
	@echo "arch flags : $(ARCH_NATIVE)"
	@echo ""
	@echo "targets:"
	@echo "  make dev           — debug build (current machine)"
	@echo "  make mac           — optimised build (current machine)"
	@echo "  make san           — asan + ubsan build"
	@echo "  make prof          — profiling build (-DPROFILE)"
	@echo "  make release-uds   — all arches, tab-delimited UDS (default)"
	@echo "  make release-http  — all arches, bare HTTP/1.0 over UDS"
	@echo "  make release-fcgi  — all arches, FastCGI over UDS"
	@echo "  make release       — full matrix (all arches x all protos)"
	@echo ""
	@echo "nginx:"
	@echo "  HTTP:  proxy_pass http://unix:/tmp/billpreview.sock;"
	@echo "  FCGI:  fastcgi_pass unix:/tmp/billpreview.sock;"
	@echo ""

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -rf $(GEN_DIR) $(OUT_DIR)
