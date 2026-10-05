# Build the IR-camera tools for the phone (aarch64, glibc / Ubuntu Touch 24.04).
# Run through Docker so nothing is installed on the host:
#   docker run --rm -v "$PWD:/work" -w /work/apps/ircam ircam-build:24.04 make

# make has a built-in default for CC, so ?= would never take effect here.
CC       = aarch64-linux-gnu-gcc
CFLAGS  ?= -O2 -g -Wall -Wextra -Wno-unused-parameter -std=gnu11
# -MMD -MP makes gcc emit .d files so editing a header rebuilds what includes it.
CPPFLAGS = -Indk -Indk/compat -Isrc -MMD -MP
LDFLAGS  = -Wl,-z,now
LDLIBS   = -ldl -lpthread

BIN     = build/ircam-shot
OBJS    = build/ircam-shot.o build/hybris_ndk.o build/imgwrite.o build/camutil.o

all: $(BIN)

build:
	mkdir -p build

build/%.o: src/%.c | build
	$(CC) $(CFLAGS) $(CPPFLAGS) -c -o $@ $<

$(BIN): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

-include $(OBJS:.o=.d)

clean:
	rm -rf build

.PHONY: all clean
