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
SHARED = $(BUILD)/libacp.dylib
SHARED_FLAGS = -dynamiclib -Wl,-install_name,@rpath/libacp.dylib
else
SHARED = $(BUILD)/libacp.so
SHARED_FLAGS = -shared -Wl,-soname,libacp.so
endif

.PHONY: all test install clean
all: $(BUILD)/libacp.a $(SHARED)

$(BUILD):
	mkdir -p $@

OBJECTS = $(addprefix $(BUILD)/,acp.o initialize.o)

$(BUILD)/%.o: src/%.c src/internal.h include/acp.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/libacp.a: $(OBJECTS)
	$(AR) rcs $@ $^

$(SHARED): $(OBJECTS)
	$(CC) $(CFLAGS) $(LDFLAGS) $(SHARED_FLAGS) -o $@ $^ $(LDLIBS)

test: all
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) tests/initialize.c $(BUILD)/libacp.a $(LDLIBS) -o $(BUILD)/initialize-test
	$(BUILD)/initialize-test

install: all
	install -d $(DESTDIR)$(PREFIX)/include $(DESTDIR)$(PREFIX)/lib/pkgconfig
	install -m 644 include/acp.h $(DESTDIR)$(PREFIX)/include/
# The archive alone, as libmcp installs: -lacp resolves to it with nothing to find at run time.
	install -m 644 $(BUILD)/libacp.a $(DESTDIR)$(PREFIX)/lib/
	sed -e 's|@PREFIX@|$(PREFIX)|g' libacp.pc.in > $(BUILD)/libacp.pc
	install -m 644 $(BUILD)/libacp.pc $(DESTDIR)$(PREFIX)/lib/pkgconfig/

clean:
	rm -rf $(BUILD)
