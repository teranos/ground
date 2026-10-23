CC ?= cc
AR ?= ar
PKG_CONFIG ?= pkg-config
PREFIX ?= /usr/local
BUILD ?= build
CPPFLAGS += -Iinclude $(shell $(PKG_CONFIG) --cflags json-c)
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Wpedantic -Werror -fPIC
LDLIBS += $(shell $(PKG_CONFIG) --libs json-c)
UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
SHARED = $(BUILD)/libmcp.dylib
SHARED_FLAGS = -dynamiclib -Wl,-install_name,@rpath/libmcp.dylib
else
SHARED = $(BUILD)/libmcp.so
SHARED_FLAGS = -shared -Wl,-soname,libmcp.so
endif

.PHONY: all test test-d install clean
all: $(BUILD)/libmcp.a $(SHARED)

$(BUILD):
	mkdir -p $@

$(BUILD)/mcp.o: src/mcp.c include/mcp.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/libmcp.a: $(BUILD)/mcp.o
	$(AR) rcs $@ $<

$(SHARED): $(BUILD)/mcp.o
	$(CC) $(CFLAGS) $(LDFLAGS) $(SHARED_FLAGS) -o $@ $< $(LDLIBS)

test: all
	python3 tests/test_mcp.py $(SHARED)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) tests/client.c $(BUILD)/libmcp.a $(LDLIBS) -o $(BUILD)/c-client
	$(BUILD)/c-client "$$(command -v python3)" "$$(pwd)/tests/server.py"

test-d: all
	$(CC) $(CPPFLAGS) $(CFLAGS) -c tests/abi.c -o $(BUILD)/abi.o
	ldc2 -betterC -I=../source -of=$(BUILD)/abi-test tests/abi.d $(BUILD)/abi.o
	$(BUILD)/abi-test
	ldc2 -betterC -I=../source -of=$(BUILD)/mcp-client examples/client.d ../source/mcpcmd.d $(BUILD)/libmcp.a $(foreach lib,$(LDLIBS),-L$(lib))
	python3 tests/test_d.py $(BUILD)/mcp-client
	ldc2 -betterC -I=../source -of=$(BUILD)/mcp-harness tests/harness.d ../source/code/mcp.d ../source/code/reply.d ../source/libjsonc.d $(BUILD)/libmcp.a $(foreach lib,$(LDLIBS),-L$(lib))
	python3 tests/test_harness.py $(BUILD)/mcp-harness

install: all
	install -d $(DESTDIR)$(PREFIX)/include/d $(DESTDIR)$(PREFIX)/lib/pkgconfig
	install -m 644 include/mcp.h $(DESTDIR)$(PREFIX)/include/
	install -m 644 ../source/libmcp.d $(DESTDIR)$(PREFIX)/include/d/
	install -m 644 $(BUILD)/libmcp.a $(SHARED) $(DESTDIR)$(PREFIX)/lib/
	sed 's|@PREFIX@|$(PREFIX)|g' libmcp.pc.in > $(BUILD)/libmcp.pc
	install -m 644 $(BUILD)/libmcp.pc $(DESTDIR)$(PREFIX)/lib/pkgconfig/

clean:
	rm -rf $(BUILD)
