# make -C priv/native
# → ../orbital_serial.so / ../orbital_esp.so (local)
# → ../orbital_serial-$(TARGET).so / ../orbital_esp-$(TARGET).so (prebuilt)

PRIV_DIR ?= ..
SERIAL_NAME = orbital_serial
ESP_NAME = orbital_esp

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
LDFLAGS ?=

ifeq ($(OS),Windows_NT)
  UNAME_S := Windows
endif

# TARGET must match orbital_*_ffi:host_triple/0.
ifeq ($(UNAME_S),Darwin)
  ifeq ($(UNAME_M),arm64)
    TARGET ?= aarch64-apple-darwin
  else
    TARGET ?= x86_64-apple-darwin
  endif
  PLATFORM_SRC = $(SP_VENDOR)/macosx.c
  LDFLAGS += -dynamiclib -undefined dynamic_lookup -framework IOKit -framework CoreFoundation
  EXT = so
else ifeq ($(UNAME_S),Linux)
  ifeq ($(UNAME_M),aarch64)
    TARGET ?= aarch64-unknown-linux-gnu
  else
    TARGET ?= x86_64-unknown-linux-gnu
  endif
  PLATFORM_SRC = $(SP_VENDOR)/linux.c $(SP_VENDOR)/linux_termios.c
  LDFLAGS += -shared
  EXT = so
else ifeq ($(UNAME_S),Windows)
  TARGET ?= x86_64-pc-windows-gnu
  PLATFORM_SRC = $(SP_VENDOR)/windows.c
  LDFLAGS += -shared -lsetupapi
  EXT = dll
else
  $(error Unsupported OS: $(UNAME_S))
endif

SERIAL_LOCAL = $(PRIV_DIR)/$(SERIAL_NAME).$(EXT)
SERIAL_PREBUILT = $(PRIV_DIR)/$(SERIAL_NAME)-$(TARGET).$(EXT)
ESP_LOCAL = $(PRIV_DIR)/$(ESP_NAME).$(EXT)
ESP_PREBUILT = $(PRIV_DIR)/$(ESP_NAME)-$(TARGET).$(EXT)

SP_SRC = $(SP_VENDOR)/serialport.c $(SP_VENDOR)/timing.c $(PLATFORM_SRC)
SP_OBJ = $(SP_SRC:.c=.o)

SERIAL_NIF_SRC = orbital_serial.c
SERIAL_NIF_OBJ = $(SERIAL_NIF_SRC:.c=.o)

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

ESF_OBJ = $(ESF_SRC:.c=.o)

ESP_NIF_SRC = orbital_esp.c libserialport_port.c
ESP_NIF_OBJ = $(ESP_NIF_SRC:.c=.o)

.PHONY: all clean serial esp

all: serial esp

serial: $(SERIAL_LOCAL) $(SERIAL_PREBUILT)

esp: $(ESP_LOCAL) $(ESP_PREBUILT)

$(SERIAL_LOCAL): $(SERIAL_NIF_OBJ) $(SP_OBJ) | $(PRIV_DIR)
	$(CC) $(LDFLAGS) -o $@ $(SERIAL_NIF_OBJ) $(SP_OBJ)

$(SERIAL_PREBUILT): $(SERIAL_LOCAL)
	cp $< $@

$(ESP_LOCAL): $(ESP_NIF_OBJ) $(SP_OBJ) $(ESF_OBJ) | $(PRIV_DIR)
	$(CC) $(LDFLAGS) -o $@ $(ESP_NIF_OBJ) $(SP_OBJ) $(ESF_OBJ)

$(ESP_PREBUILT): $(ESP_LOCAL)
	cp $< $@

$(PRIV_DIR):
	mkdir -p $@

$(SERIAL_NIF_OBJ): %.o: %.c
	$(CC) $(CFLAGS) -I$(ERTS_INCLUDE_DIR) -I$(SP_VENDOR) -c -o $@ $<

$(ESP_NIF_OBJ): %.o: %.c
	$(CC) $(NIF_CFLAGS) -c -o $@ $<

$(SP_OBJ): %.o: %.c
	$(CC) $(SP_CFLAGS) -c -o $@ $<

$(ESF_OBJ): %.o: %.c
	$(CC) $(ESF_CFLAGS) -c -o $@ $<

clean:
	rm -f $(SERIAL_NIF_OBJ) $(ESP_NIF_OBJ) $(SP_OBJ) $(ESF_OBJ) $(SERIAL_LOCAL) $(ESP_LOCAL)
