CC ?= cc
AR ?= ar
PKG_CONFIG ?= pkg-config
PREFIX ?= /usr/local
BUILD ?= build
CPPFLAGS += -Iinclude $(shell $(PKG_CONFIG) --cflags json-c libcurl)
CPPFLAGS += -Ivendor/corvus/corvus-json-schema-capi/include
CARGO ?= cargo
CORVUS_MANIFEST = vendor/corvus/corvus-json-schema-capi/Cargo.toml
CORVUS_LIB ?= $(BUILD)/corvus/release/libcorvus_json_schema.a
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Wpedantic -Werror -fPIC
LDLIBS += $(shell $(PKG_CONFIG) --libs json-c libcurl)
LDLIBS += -lm -lpthread
UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
LDLIBS += -liconv
SHARED = $(BUILD)/libmcp.dylib
SHARED_FLAGS = -dynamiclib -Wl,-install_name,@rpath/libmcp.dylib
else
LDLIBS += -ldl
SHARED = $(BUILD)/libmcp.so
SHARED_FLAGS = -shared -Wl,-soname,libmcp.so
endif

.PHONY: all test test-interop install clean
all: $(BUILD)/libmcp.a $(SHARED)

$(BUILD):
	mkdir -p $@

OBJECTS = $(addprefix $(BUILD)/,mcp.o json.o protocol.o stdio.o http.o schema.o)

$(CORVUS_LIB): $(shell find vendor/corvus -type f) | $(BUILD)
	$(CARGO) build --offline --locked --release --manifest-path $(CORVUS_MANIFEST) --target-dir $(abspath $(BUILD)/corvus)

$(BUILD)/%.o: src/%.c src/internal.h include/mcp.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/libmcp.a: $(OBJECTS) $(CORVUS_LIB)
ifeq ($(UNAME),Darwin)
	libtool -static -o $@ $^
else
	printf 'create $@\naddlib $(CORVUS_LIB)\n$(foreach o,$(OBJECTS),addmod $(o)\n)save\nend\n' | $(AR) -M
endif

$(SHARED): $(OBJECTS) $(CORVUS_LIB)
	$(CC) $(CFLAGS) $(LDFLAGS) $(SHARED_FLAGS) -o $@ $^ $(LDLIBS)

test: all
	python3 tests/test_mcp.py $(SHARED)
	python3 tests/test_runtime.py $(SHARED)
	python3 tests/test_features.py $(SHARED)
	python3 tests/test_http.py $(SHARED)
	python3 tests/test_schema.py $(SHARED)
	python3 tests/test_checked.py $(SHARED)
	python3 tests/test_schema_suite.py $(SHARED)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) tests/client.c $(BUILD)/libmcp.a $(LDLIBS) -o $(BUILD)/c-client
	$(BUILD)/c-client "$$(command -v python3)" "$$(pwd)/tests/server.py"
ifeq ($(UNAME),Linux)
	$(CC) $(CPPFLAGS) $(CFLAGS) -Isrc tests/json.c $(BUILD)/json.o -Wl,--wrap=json_tokener_new_ex $(LDLIBS) -o $(BUILD)/json-test
	$(BUILD)/json-test
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/failure.c $(BUILD)/libmcp.a -Wl,--wrap=mcp_stdio_poll $(LDLIBS) -o $(BUILD)/failure-test
	$(BUILD)/failure-test "$$(command -v python3)" "$$(pwd)/tests/server.py"
endif

test-interop: all
	test -n "$(SDK_ROOT)" && test -n "$(SDK_PYTHON)"
	SDK_ROOT="$(SDK_ROOT)" SDK_PYTHON="$(SDK_PYTHON)" $(SDK_PYTHON) tests/test_sdk.py $(SHARED)

install: all
	install -d $(DESTDIR)$(PREFIX)/include $(DESTDIR)$(PREFIX)/lib/pkgconfig
	install -m 644 include/mcp.h $(DESTDIR)$(PREFIX)/include/
# The archive alone: a consumer embeds the client, and -lmcp then resolves to
# it with no shared library to find at run time. The shared one is for the tests.
	install -m 644 $(BUILD)/libmcp.a $(DESTDIR)$(PREFIX)/lib/
	sed -e 's|@PREFIX@|$(PREFIX)|g' -e 's|@PLATFORM_LIBS@|$(if $(filter Darwin,$(UNAME)),-liconv,-ldl)|g' libmcp.pc.in > $(BUILD)/libmcp.pc
	install -m 644 $(BUILD)/libmcp.pc $(DESTDIR)$(PREFIX)/lib/pkgconfig/

clean:
	rm -rf $(BUILD)
