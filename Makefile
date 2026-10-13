# nim-qrscan — local development build.
# Nim dependencies are cloned (not submoduled) into .deps/ at the same commits
# status-desktop vendors. zxing-cpp is a git submodule (vendor/zxing-cpp).

SEAQT_REV    := 7d40abd7b493036b4ede5b111fc4260237504796
NIMQML_REV   := fa084a8d9bcf00c9ed4c2adf857793fcc059357f
RESULTS_REV  := 06deae1c81fd27b6c94bbc7cd0e619b6905d49da
PRLTOPC_REV  := 03a8a91707db7d9257d8617453fefb58fe848904
QRGEN_REV    := d1c87af693b0c93fd0b6ff34f098d3011944eb82
# Example only: the camera demo in examples/scan. Library code and tests never
# use nim-qtcamera.
QTCAMERA_REV := d7bd4c0875a49628d20abd70e8111032dddbb64c
QTCAMERA_URL ?= https://github.com/status-im/nim-qtcamera.git

DEPS  := .deps
NIM   ?= nim
QMAKE ?= qmake
# Nim does not recompile {.compile.}'d C++ when it changes: after editing a
# shim run `make test EXTRA_NIMFLAGS=-f`.
NIMFLAGS ?= --hints:off $(EXTRA_NIMFLAGS)

ZXING_SRC   := vendor/zxing-cpp
ZXING_BUILD := build/zxing
ZXING_LIB   := $(ZXING_BUILD)/core/libZXing.a

define clone_pinned
	@test -d $(DEPS)/$(1) || git clone --quiet $(2) $(DEPS)/$(1)
	@git -C $(DEPS)/$(1) cat-file -e $(3)^{commit} 2>/dev/null || git -C $(DEPS)/$(1) fetch --quiet origin
	@git -C $(DEPS)/$(1) checkout --quiet $(3)
endef

all: test

deps:
	@git submodule update --init vendor/zxing-cpp
	$(call clone_pinned,nim-seaqt,https://github.com/seaqt/nim-seaqt.git,$(SEAQT_REV))
	$(call clone_pinned,nimqml-seaqt,https://github.com/seaqt/nimqml-seaqt.git,$(NIMQML_REV))
	$(call clone_pinned,nim-results,https://github.com/arnetheduck/nim-results.git,$(RESULTS_REV))
	$(call clone_pinned,prl-to-pc,https://github.com/status-im/prl-to-pc.git,$(PRLTOPC_REV))
	$(call clone_pinned,QR-Code-generator,https://github.com/status-im/QR-Code-generator.git,$(QRGEN_REV))

example-deps: deps
	$(call clone_pinned,nim-qtcamera,$(QTCAMERA_URL),$(QTCAMERA_REV))

# Exports PKG_CONFIG_PATH (and, in generated mode, the pkg-config wrapper on
# PATH) so seaqt's compile-time gorge("pkg-config ...") finds Qt.
-include $(DEPS)/prl-to-pc/qt-pkgconfig.mk

ifeq ($(shell uname -s),Darwin)
 QT_LIBDIR := $(shell $(QMAKE) -query QT_INSTALL_LIBS 2>/dev/null)
 NIMFLAGS += --passL:"-F$(QT_LIBDIR)" --passL:"-Wl,-rpath,$(QT_LIBDIR)"
 CXXRUNTIME := -lc++
else
 CXXRUNTIME := -lstdc++
endif

$(ZXING_LIB):
	cmake -S $(ZXING_SRC) -B $(ZXING_BUILD) -DCMAKE_BUILD_TYPE=Release \
	  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF \
	  -DZXING_READERS=ON -DZXING_WRITERS=OFF -DZXING_C_API=ON \
	  -DZXING_EXAMPLES=OFF -DZXING_BLACKBOX_TESTS=OFF -DZXING_UNIT_TESTS=OFF -Wno-dev
	cmake --build $(ZXING_BUILD) -j

zxing: $(ZXING_LIB)

TESTS := $(sort $(filter-out tests/testutils.nim,$(wildcard tests/t*.nim)))

# The library must not depend on nim-qtcamera (frames come from any source).
independence:
	@! grep -rnE "(import|from|include) +[^#]*qtcamera" qrscan tests || \
	  (echo "nim-qrscan must not import nim-qtcamera" && false)

test: independence | qt-pkgconfig $(ZXING_LIB)
	@for t in $(TESTS); do echo "== $$t"; $(NIM) c -r $(NIMFLAGS) -d:qrscanTesting $$t || exit 1; done

# C ABI: static library + header (include/qrscan.h). C hosts link
# build/libqrscan.a + libZXing.a + the C++ runtime.
CAPI_LIB := build/libqrscan.a

capi: $(ZXING_LIB)
	$(NIM) c --app:staticlib --noMain -d:release --hints:off \
	  --nimcache:build/nimcache-capi --out:$(CURDIR)/$(CAPI_LIB) qrscan/capi.nim

QRGEN_C := .deps/QR-Code-generator/c

ctest: capi
	$(CC) -std=c11 -O1 -Iinclude -I$(QRGEN_C) tests/c/tcapi.c $(QRGEN_C)/qrcodegen.c \
	  $(CAPI_LIB) $(ZXING_LIB) $(CXXRUNTIME) -lpthread -lm -o tests/c/tcapi
	tests/c/tcapi

.PHONY: all deps example-deps zxing independence test capi ctest
