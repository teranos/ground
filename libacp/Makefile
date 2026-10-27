CC ?= cc
AR ?= ar
PKG_CONFIG ?= pkg-config
PREFIX ?= /usr/local
BUILD ?= build
CPPFLAGS += -Iinclude $(shell $(PKG_CONFIG) --cflags json-c)
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Wpedantic -Werror -fPIC
# Every implicit narrowing, shadowed name, unprototyped function and non-literal format is an error.
CFLAGS += -Wshadow -Wconversion -Wsign-conversion -Wstrict-prototypes -Wmissing-prototypes \
	-Wcast-qual -Wformat=2 -Wundef -Wvla -Wnull-dereference -Wdouble-promotion -Wimplicit-fallthrough
SANITIZE = -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
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

OBJECTS = $(addprefix $(BUILD)/,acp.o initialize.o session.o modes.o config.o prompt.o)

$(BUILD)/%.o: src/%.c src/internal.h include/acp.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/libacp.a: $(OBJECTS)
	$(AR) rcs $@ $^

$(SHARED): $(OBJECTS)
	$(CC) $(CFLAGS) $(LDFLAGS) $(SHARED_FLAGS) -o $@ $^ $(LDLIBS)

TESTS = initialize session modes config prompt

test: all
	for t in $(TESTS); do \
		$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) tests/$$t.c $(BUILD)/libacp.a $(LDLIBS) -o $(BUILD)/$$t-test && $(BUILD)/$$t-test || exit 1; \
	done
# The same tests built with the library's sources under AddressSanitizer and UndefinedBehaviorSanitizer.
	for t in $(TESTS); do \
		$(CC) $(CPPFLAGS) $(CFLAGS) $(SANITIZE) $(LDFLAGS) tests/$$t.c $(addprefix src/,$(notdir $(OBJECTS:.o=.c))) $(LDLIBS) -o $(BUILD)/$$t-sanitized && $(BUILD)/$$t-sanitized || exit 1; \
	done

install: all
	install -d $(DESTDIR)$(PREFIX)/include $(DESTDIR)$(PREFIX)/lib/pkgconfig
	install -m 644 include/acp.h $(DESTDIR)$(PREFIX)/include/
# The archive alone, as libmcp installs: -lacp resolves to it with nothing to find at run time.
	install -m 644 $(BUILD)/libacp.a $(DESTDIR)$(PREFIX)/lib/
	sed -e 's|@PREFIX@|$(PREFIX)|g' libacp.pc.in > $(BUILD)/libacp.pc
	install -m 644 $(BUILD)/libacp.pc $(DESTDIR)$(PREFIX)/lib/pkgconfig/

clean:
	rm -rf $(BUILD)
