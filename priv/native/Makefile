# make -C priv/native
# → ../orbital_serial.so (local) and ../orbital_serial-$(TARGET).so (prebuilt)

PRIV_DIR ?= ..
NIF_NAME = orbital_serial

UNAME_S := $(shell uname -s 2>/dev/null || echo Unknown)
UNAME_M := $(shell uname -m 2>/dev/null || echo unknown)
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s/erts-~s/include",[code:root_dir(),erlang:system_info(version)]), halt().')

VENDOR = vendor/libserialport
CFLAGS ?= -O2 -fPIC -Wall -Wextra
NIF_CFLAGS = $(CFLAGS) -I$(ERTS_INCLUDE_DIR) -I$(VENDOR)
LIB_CFLAGS = $(CFLAGS) -I$(VENDOR) -DLIBSERIALPORT_ATBUILD -fvisibility=hidden
LDFLAGS ?=

ifeq ($(OS),Windows_NT)
  UNAME_S := Windows
endif

# TARGET must match orbital_serial_ffi:host_triple/0.
ifeq ($(UNAME_S),Darwin)
  ifeq ($(UNAME_M),arm64)
    TARGET ?= aarch64-apple-darwin
  else
    TARGET ?= x86_64-apple-darwin
  endif
  PLATFORM_SRC = $(VENDOR)/macosx.c
  LDFLAGS += -dynamiclib -undefined dynamic_lookup -framework IOKit -framework CoreFoundation
  EXT = so
else ifeq ($(UNAME_S),Linux)
  ifeq ($(UNAME_M),aarch64)
    TARGET ?= aarch64-unknown-linux-gnu
  else
    TARGET ?= x86_64-unknown-linux-gnu
  endif
  PLATFORM_SRC = $(VENDOR)/linux.c $(VENDOR)/linux_termios.c
  LDFLAGS += -shared
  EXT = so
else ifeq ($(UNAME_S),Windows)
  TARGET ?= x86_64-pc-windows-gnu
  PLATFORM_SRC = $(VENDOR)/windows.c
  LDFLAGS += -shared -lsetupapi
  EXT = dll
else
  $(error Unsupported OS: $(UNAME_S))
endif

NIF_LOCAL = $(PRIV_DIR)/$(NIF_NAME).$(EXT)
NIF_PREBUILT = $(PRIV_DIR)/$(NIF_NAME)-$(TARGET).$(EXT)

LIB_SRC = $(VENDOR)/serialport.c $(VENDOR)/timing.c $(PLATFORM_SRC)
NIF_SRC = orbital_serial.c
LIB_OBJ = $(LIB_SRC:.c=.o)
NIF_OBJ = $(NIF_SRC:.c=.o)
OBJ = $(NIF_OBJ) $(LIB_OBJ)

.PHONY: all clean

all: $(NIF_LOCAL) $(NIF_PREBUILT)

$(NIF_LOCAL): $(OBJ) | $(PRIV_DIR)
	$(CC) $(LDFLAGS) -o $@ $(OBJ)

$(NIF_PREBUILT): $(NIF_LOCAL)
	cp $< $@

$(PRIV_DIR):
	mkdir -p $@

$(NIF_OBJ): %.o: %.c
	$(CC) $(NIF_CFLAGS) -c -o $@ $<

$(LIB_OBJ): %.o: %.c
	$(CC) $(LIB_CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJ) $(NIF_LOCAL)
