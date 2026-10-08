# make -C priv/native
# → ../orbital_serial.so / ../orbital_esp.so (local host build)
# → ../orbital_serial-$(TARGET).so / ../orbital_esp-$(TARGET).so (host prebuilt copy)
#
# make -C priv/native prebuilts
# → all five host_triple artifacts via zig cc (no Docker)
# Requires: brew install zig

PRIV_DIR ?= ..
SERIAL_NAME = orbital_serial
ESP_NAME = orbital_esp
BUILD_ROOT = build

UNAME_S := $(shell uname -s 2>/dev/null || echo Unknown)
UNAME_M := $(shell uname -m 2>/dev/null || echo unknown)
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s/erts-~s/include",[code:root_dir(),erlang:system_info(version)]), halt().')

SP_VENDOR = vendor/libserialport
ESF_VENDOR = vendor/esp-serial-flasher

CFLAGS ?= -O2 -fPIC -Wall -Wextra
SP_CFLAGS = $(CFLAGS) -I$(SP_VENDOR) -DLIBSERIALPORT_ATBUILD -fvisibility=hidden
ESF_DEFS = \
	-DSERIAL_FLASHER_LOG_LEVEL=1 \
	-DSERIAL_FLASHER_RESET_HOLD_TIME_MS=100 \
	-DSERIAL_FLASHER_BOOT_HOLD_TIME_MS=50 \
	-DSERIAL_FLASHER_WRITE_BLOCK_RETRIES=3 \
	-DSERIAL_FLASHER_RESET_INVERT=0 \
	-DSERIAL_FLASHER_BOOT_INVERT=0
ESF_INCLUDES = \
	-I$(ESF_VENDOR)/include \
	-I$(ESF_VENDOR)/private_include \
	-I$(ESF_VENDOR)/port/common \
	-I$(SP_VENDOR) \
	-I.
NIF_CFLAGS = $(CFLAGS) -I$(ERTS_INCLUDE_DIR) $(ESF_INCLUDES) $(ESF_DEFS)
ESF_CFLAGS = $(CFLAGS) $(ESF_INCLUDES) $(ESF_DEFS) -fvisibility=hidden

ifeq ($(OS),Windows_NT)
  UNAME_S := Windows
endif

# Host TARGET must match orbital_*_ffi:host_triple/0.
ifeq ($(UNAME_S),Darwin)
  ifeq ($(UNAME_M),arm64)
    TARGET ?= aarch64-apple-darwin
  else
    TARGET ?= x86_64-apple-darwin
  endif
  PLATFORM_SRC = $(SP_VENDOR)/macosx.c
  HOST_LDFLAGS = -dynamiclib -undefined dynamic_lookup -framework IOKit -framework CoreFoundation
  EXT = so
else ifeq ($(UNAME_S),Linux)
  ifeq ($(UNAME_M),aarch64)
    TARGET ?= aarch64-unknown-linux-gnu
  else
    TARGET ?= x86_64-unknown-linux-gnu
  endif
  PLATFORM_SRC = $(SP_VENDOR)/linux.c $(SP_VENDOR)/linux_termios.c
  HOST_LDFLAGS = -shared
  EXT = so
else ifeq ($(UNAME_S),Windows)
  TARGET ?= x86_64-pc-windows-gnu
  PLATFORM_SRC = $(SP_VENDOR)/windows.c
  HOST_LDFLAGS = -shared -lsetupapi
  EXT = dll
else
  $(error Unsupported OS: $(UNAME_S))
endif

# ---------------------------------------------------------------------------
# Shared source lists
# ---------------------------------------------------------------------------

SERIAL_NIF_SRC = orbital_serial.c
ESP_NIF_SRC = orbital_esp.c libserialport_port.c
SP_COMMON_SRC = $(SP_VENDOR)/serialport.c $(SP_VENDOR)/timing.c

ESF_SRC = \
	$(ESF_VENDOR)/src/md5_hash.c \
	$(ESF_VENDOR)/src/esp_loader.c \
	$(ESF_VENDOR)/src/esp_targets.c \
	$(ESF_VENDOR)/src/protocol_serial.c \
	$(ESF_VENDOR)/src/protocol_uart.c \
	$(ESF_VENDOR)/src/protocol_spi.c \
	$(ESF_VENDOR)/src/protocol_sdio.c \
	$(ESF_VENDOR)/src/slip.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_bundled.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp8266.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp32.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp32s2.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp32c3.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp32s3.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp32c2.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp32c5.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp32h2.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp32h21.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp32c6.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp32p4.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp32p4rev1.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp32c61.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp32s31.c \
	$(ESF_VENDOR)/src/stubs/esp_stub_esp32h4.c

# ---------------------------------------------------------------------------
# Host build (system CC) — local override + matching prebuilt copy
# ---------------------------------------------------------------------------

# Host objects live under build/host/ so they never collide with zig
# prebuilt objects for the same triple (e.g. aarch64-apple-darwin on Apple Silicon).
HOST_BUILD = $(BUILD_ROOT)/host
HOST_SP_SRC = $(SP_COMMON_SRC) $(PLATFORM_SRC)
HOST_SERIAL_OBJS = $(addprefix $(HOST_BUILD)/,$(SERIAL_NIF_SRC:.c=.o) $(HOST_SP_SRC:.c=.o))
HOST_ESP_OBJS = $(addprefix $(HOST_BUILD)/,$(ESP_NIF_SRC:.c=.o) $(HOST_SP_SRC:.c=.o) $(ESF_SRC:.c=.o))

SERIAL_LOCAL = $(PRIV_DIR)/$(SERIAL_NAME).$(EXT)
SERIAL_HOST_PREBUILT = $(PRIV_DIR)/$(SERIAL_NAME)-$(TARGET).$(EXT)
ESP_LOCAL = $(PRIV_DIR)/$(ESP_NAME).$(EXT)
ESP_HOST_PREBUILT = $(PRIV_DIR)/$(ESP_NAME)-$(TARGET).$(EXT)

.PHONY: all clean clean-prebuilts serial esp prebuilts check-zig

all: serial esp

serial: $(SERIAL_LOCAL)

esp: $(ESP_LOCAL)

# Copy into the triple-named path as a side effect (not a separate make target)
# so zig prebuilt-$(TARGET) can own that filename without recipe conflicts.
$(SERIAL_LOCAL): $(HOST_SERIAL_OBJS) | $(PRIV_DIR)
	$(CC) $(HOST_LDFLAGS) -o $@ $(HOST_SERIAL_OBJS)
	cp $@ $(SERIAL_HOST_PREBUILT)

$(ESP_LOCAL): $(HOST_ESP_OBJS) | $(PRIV_DIR)
	$(CC) $(HOST_LDFLAGS) -o $@ $(HOST_ESP_OBJS)
	cp $@ $(ESP_HOST_PREBUILT)

$(PRIV_DIR):
	mkdir -p $@

$(HOST_BUILD)/orbital_serial.o: orbital_serial.c | $(HOST_BUILD)
	$(CC) $(CFLAGS) -I$(ERTS_INCLUDE_DIR) -I$(SP_VENDOR) -c -o $@ $<

$(HOST_BUILD)/orbital_esp.o: orbital_esp.c | $(HOST_BUILD)
	$(CC) $(NIF_CFLAGS) -c -o $@ $<

$(HOST_BUILD)/libserialport_port.o: libserialport_port.c | $(HOST_BUILD)
	$(CC) $(NIF_CFLAGS) -c -o $@ $<

$(HOST_BUILD)/$(SP_VENDOR)/%.o: $(SP_VENDOR)/%.c | $(HOST_BUILD)/$(SP_VENDOR)
	$(CC) $(SP_CFLAGS) -c -o $@ $<

$(HOST_BUILD)/$(ESF_VENDOR)/%.o: $(ESF_VENDOR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(ESF_CFLAGS) -c -o $@ $<

$(HOST_BUILD) $(HOST_BUILD)/$(SP_VENDOR):
	mkdir -p $@

# ---------------------------------------------------------------------------
# Cross prebuilts via zig cc
# ---------------------------------------------------------------------------

PREBUILT_TARGETS = \
	aarch64-apple-darwin \
	x86_64-apple-darwin \
	aarch64-unknown-linux-gnu \
	x86_64-unknown-linux-gnu \
	x86_64-pc-windows-gnu

ZIG_TARGET_aarch64-apple-darwin = aarch64-macos
ZIG_TARGET_x86_64-apple-darwin = x86_64-macos
ZIG_TARGET_aarch64-unknown-linux-gnu = aarch64-linux-gnu
ZIG_TARGET_x86_64-unknown-linux-gnu = x86_64-linux-gnu
ZIG_TARGET_x86_64-pc-windows-gnu = x86_64-windows-gnu

EXT_aarch64-apple-darwin = so
EXT_x86_64-apple-darwin = so
EXT_aarch64-unknown-linux-gnu = so
EXT_x86_64-unknown-linux-gnu = so
EXT_x86_64-pc-windows-gnu = dll

PLATFORM_SRC_aarch64-apple-darwin = $(SP_VENDOR)/macosx.c
PLATFORM_SRC_x86_64-apple-darwin = $(SP_VENDOR)/macosx.c
PLATFORM_SRC_aarch64-unknown-linux-gnu = $(SP_VENDOR)/linux.c $(SP_VENDOR)/linux_termios.c
PLATFORM_SRC_x86_64-unknown-linux-gnu = $(SP_VENDOR)/linux.c $(SP_VENDOR)/linux_termios.c
PLATFORM_SRC_x86_64-pc-windows-gnu = $(SP_VENDOR)/windows.c

# Zig needs the macOS SDK explicitly when -target *-macos is set.
# Paths after --sysroot are SDK-relative (do not pass absolute -L/-F).
MACOSX_SDK ?= $(shell xcrun --show-sdk-path 2>/dev/null)
DARWIN_ZIG_FLAGS = --sysroot $(MACOSX_SDK) -L/usr/lib -F/System/Library/Frameworks

ZIG_FLAGS_aarch64-apple-darwin = $(DARWIN_ZIG_FLAGS)
ZIG_FLAGS_x86_64-apple-darwin = $(DARWIN_ZIG_FLAGS)
ZIG_FLAGS_aarch64-unknown-linux-gnu =
ZIG_FLAGS_x86_64-unknown-linux-gnu =
ZIG_FLAGS_x86_64-pc-windows-gnu =

LDFLAGS_aarch64-apple-darwin = -dynamiclib -undefined dynamic_lookup -framework IOKit -framework CoreFoundation
LDFLAGS_x86_64-apple-darwin = -dynamiclib -undefined dynamic_lookup -framework IOKit -framework CoreFoundation
LDFLAGS_aarch64-unknown-linux-gnu = -shared
LDFLAGS_x86_64-unknown-linux-gnu = -shared
LDFLAGS_x86_64-pc-windows-gnu = -shared -lsetupapi

check-zig:
	@command -v zig >/dev/null 2>&1 || { \
		echo "zig not found; install with: brew install zig"; \
		exit 1; \
	}
	@if [ -z "$(MACOSX_SDK)" ]; then \
		echo "macOS SDK not found (xcrun --show-sdk-path); install Xcode CLT"; \
		exit 1; \
	fi

prebuilts: check-zig $(foreach t,$(PREBUILT_TARGETS),prebuilt-$(t))

# $(1) = orbital host_triple
define PREBUILT_rules
prebuilt-$(1): $$(PRIV_DIR)/$$(SERIAL_NAME)-$(1).$$(EXT_$(1)) $$(PRIV_DIR)/$$(ESP_NAME)-$(1).$$(EXT_$(1))

$(1)_BUILD = $$(BUILD_ROOT)/$(1)
$(1)_ZIG_CC = zig cc -target $$(ZIG_TARGET_$(1)) $$(ZIG_FLAGS_$(1))
$(1)_SP_SRC = $$(SP_COMMON_SRC) $$(PLATFORM_SRC_$(1))
$(1)_SERIAL_OBJS = $$(addprefix $$($(1)_BUILD)/,$$(SERIAL_NIF_SRC:.c=.o) $$($(1)_SP_SRC:.c=.o))
$(1)_ESP_OBJS = $$(addprefix $$($(1)_BUILD)/,$$(ESP_NIF_SRC:.c=.o) $$($(1)_SP_SRC:.c=.o) $$(ESF_SRC:.c=.o))

$$(PRIV_DIR)/$$(SERIAL_NAME)-$(1).$$(EXT_$(1)): $$($(1)_SERIAL_OBJS) | $$(PRIV_DIR)
	$$($(1)_ZIG_CC) $$(LDFLAGS_$(1)) -o $$@ $$($(1)_SERIAL_OBJS)
	@rm -f $$(PRIV_DIR)/$$(SERIAL_NAME)-$(1).pdb

$$(PRIV_DIR)/$$(ESP_NAME)-$(1).$$(EXT_$(1)): $$($(1)_ESP_OBJS) | $$(PRIV_DIR)
	$$($(1)_ZIG_CC) $$(LDFLAGS_$(1)) -o $$@ $$($(1)_ESP_OBJS)
	@rm -f $$(PRIV_DIR)/$$(ESP_NAME)-$(1).pdb

$$($(1)_BUILD)/orbital_serial.o: orbital_serial.c | $$($(1)_BUILD)
	$$($(1)_ZIG_CC) $$(CFLAGS) -I$$(ERTS_INCLUDE_DIR) -I$$(SP_VENDOR) -c -o $$@ $$<

$$($(1)_BUILD)/orbital_esp.o: orbital_esp.c | $$($(1)_BUILD)
	$$($(1)_ZIG_CC) $$(NIF_CFLAGS) -c -o $$@ $$<

$$($(1)_BUILD)/libserialport_port.o: libserialport_port.c | $$($(1)_BUILD)
	$$($(1)_ZIG_CC) $$(NIF_CFLAGS) -c -o $$@ $$<

$$($(1)_BUILD)/$$(SP_VENDOR)/%.o: $$(SP_VENDOR)/%.c | $$($(1)_BUILD)/$$(SP_VENDOR)
	$$($(1)_ZIG_CC) $$(SP_CFLAGS) -c -o $$@ $$<

$$($(1)_BUILD)/$$(ESF_VENDOR)/%.o: $$(ESF_VENDOR)/%.c
	@mkdir -p $$(dir $$@)
	$$($(1)_ZIG_CC) $$(ESF_CFLAGS) -c -o $$@ $$<

$$($(1)_BUILD) $$($(1)_BUILD)/$$(SP_VENDOR):
	mkdir -p $$@

.PHONY: prebuilt-$(1)
endef

$(foreach t,$(PREBUILT_TARGETS),$(eval $(call PREBUILT_rules,$(t))))

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------

clean:
	rm -rf $(BUILD_ROOT)
	rm -f $(SERIAL_LOCAL) $(ESP_LOCAL)
	rm -f $(SERIAL_NIF_SRC:.c=.o) $(ESP_NIF_SRC:.c=.o)
	rm -f $(SP_COMMON_SRC:.c=.o) $(PLATFORM_SRC:.c=.o) $(ESF_SRC:.c=.o)

clean-prebuilts:
	rm -f $(foreach t,$(PREBUILT_TARGETS),$(PRIV_DIR)/$(SERIAL_NAME)-$(t).$(EXT_$(t)) $(PRIV_DIR)/$(ESP_NAME)-$(t).$(EXT_$(t)))
	rm -f $(PRIV_DIR)/$(SERIAL_NAME)-*.pdb $(PRIV_DIR)/$(ESP_NAME)-*.pdb
