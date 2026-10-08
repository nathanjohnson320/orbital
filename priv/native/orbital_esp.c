/*
 * Orbital ESP32 flash NIF — wraps esp-serial-flasher over libserialport.
 * Apache-2.0 — Orbital.
 */

#include <erl_nif.h>
#include <libserialport.h>
#include <esp_loader.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <ctype.h>

#include "libserialport_port.h"

#define DEFAULT_BAUD 115200
#define FLASH_BLOCK 0x4000
#define ATOMVM_PROBE_ADDR 0x10030
#define ATOMVM_PROBE_SIZE 128

static ERL_NIF_TERM
make_atom(ErlNifEnv *env, const char *name)
{
    ERL_NIF_TERM atom;
    if (enif_make_existing_atom(env, name, &atom, ERL_NIF_LATIN1)) {
        return atom;
    }
    return enif_make_atom(env, name);
}

static ERL_NIF_TERM
make_binary(ErlNifEnv *env, const char *text)
{
    size_t len;
    ERL_NIF_TERM out;
    unsigned char *buf;

    if (text == NULL) {
        text = "";
    }
    len = strlen(text);
    buf = enif_make_new_binary(env, len, &out);
    if (buf != NULL && len > 0) {
        memcpy(buf, text, len);
    }
    return out;
}

static ERL_NIF_TERM
make_ok(ErlNifEnv *env, ERL_NIF_TERM value)
{
    return enif_make_tuple2(env, make_atom(env, "ok"), value);
}

static ERL_NIF_TERM
make_error_bin(ErlNifEnv *env, const char *msg)
{
    return enif_make_tuple2(env, make_atom(env, "error"), make_binary(env, msg));
}

static const char *
loader_error_str(esp_loader_error_t err)
{
    switch (err) {
    case ESP_LOADER_SUCCESS:
        return "success";
    case ESP_LOADER_ERROR_FAIL:
        return "unspecified flash error";
    case ESP_LOADER_ERROR_TIMEOUT:
        return "timeout talking to ESP32";
    case ESP_LOADER_ERROR_IMAGE_SIZE:
        return "image larger than flash";
    case ESP_LOADER_ERROR_INVALID_MD5:
        return "flash MD5 mismatch";
    case ESP_LOADER_ERROR_INVALID_PARAM:
        return "invalid flash parameter";
    case ESP_LOADER_ERROR_INVALID_TARGET:
        return "invalid ESP target";
    case ESP_LOADER_ERROR_UNSUPPORTED_CHIP:
        return "unsupported ESP chip";
    case ESP_LOADER_ERROR_UNSUPPORTED_FUNC:
        return "unsupported flash function";
    case ESP_LOADER_ERROR_INVALID_RESPONSE:
        return "invalid response from ESP";
    default:
        return "ESP flash error";
    }
}

static const char *
chip_name(target_chip_t chip)
{
    switch (chip) {
    case ESP8266_CHIP:
        return "ESP8266";
    case ESP32_CHIP:
        return "ESP32";
    case ESP32S2_CHIP:
        return "ESP32-S2";
    case ESP32C3_CHIP:
        return "ESP32-C3";
    case ESP32S3_CHIP:
        return "ESP32-S3";
    case ESP32C2_CHIP:
        return "ESP32-C2";
    case ESP32C5_CHIP:
        return "ESP32-C5";
    case ESP32H2_CHIP:
        return "ESP32-H2";
    case ESP32C6_CHIP:
        return "ESP32-C6";
    case ESP32P4_CHIP:
        return "ESP32-P4";
    case ESP32C61_CHIP:
        return "ESP32-C61";
    case ESP32S31_CHIP:
        return "ESP32-S31";
    case ESP32H21_CHIP:
        return "ESP32-H21";
    case ESP32H4_CHIP:
        return "ESP32-H4";
    default:
        return "unknown";
    }
}

static uint32_t
bootloader_offset_for(target_chip_t chip)
{
    switch (chip) {
    case ESP32_CHIP:
    case ESP32S2_CHIP:
        return 0x1000;
    case ESP32C5_CHIP:
    case ESP32P4_CHIP:
        return 0x2000;
    default:
        return 0x0;
    }
}

static const char *
flash_size_name(uint32_t bytes)
{
    switch (bytes) {
    case 1 * 1024 * 1024:
        return "1MB";
    case 2 * 1024 * 1024:
        return "2MB";
    case 4 * 1024 * 1024:
        return "4MB";
    case 8 * 1024 * 1024:
        return "8MB";
    case 16 * 1024 * 1024:
        return "16MB";
    case 32 * 1024 * 1024:
        return "32MB";
    case 64 * 1024 * 1024:
        return "64MB";
    case 128 * 1024 * 1024:
        return "128MB";
    default:
        return "detect";
    }
}

static int
flash_size_id(uint32_t bytes)
{
    switch (bytes) {
    case 1 * 1024 * 1024:
        return 0x00;
    case 2 * 1024 * 1024:
        return 0x10;
    case 4 * 1024 * 1024:
        return 0x20;
    case 8 * 1024 * 1024:
        return 0x30;
    case 16 * 1024 * 1024:
        return 0x40;
    case 32 * 1024 * 1024:
        return 0x50;
    case 64 * 1024 * 1024:
        return 0x60;
    case 128 * 1024 * 1024:
        return 0x70;
    default:
        return 0x00;
    }
}

static int
get_cstring(ErlNifEnv *env, ERL_NIF_TERM term, char *buf, size_t buflen)
{
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin) || bin.size == 0 || bin.size >= buflen) {
        return 0;
    }
    memcpy(buf, bin.data, bin.size);
    buf[bin.size] = '\0';
    return 1;
}

typedef struct {
    esp_loader_t loader;
    libserialport_port_t port;
    int connected;
} esp_session;

static void
session_close(esp_session *session)
{
    if (session->connected) {
        esp_loader_deinit(&session->loader);
        session->connected = 0;
    }
}

static esp_loader_error_t
session_open(esp_session *session, const char *device, uint32_t baud, int with_stub)
{
    esp_loader_error_t err;
    esp_loader_connect_args_t args = ESP_LOADER_CONNECT_DEFAULT();

    memset(session, 0, sizeof(*session));
    session->port.port.ops = &libserialport_uart_ops;
    session->port.device = device;
    session->port.baudrate = baud == 0 ? DEFAULT_BAUD : baud;

    err = esp_loader_init_serial(&session->loader, &session->port.port);
    if (err != ESP_LOADER_SUCCESS) {
        return err;
    }
    session->connected = 1;

    if (with_stub) {
        err = esp_loader_connect_with_stub(&session->loader, &args);
    } else {
        err = esp_loader_connect(&session->loader, &args);
    }
    if (err != ESP_LOADER_SUCCESS) {
        session_close(session);
        return err;
    }

    if (with_stub && baud > DEFAULT_BAUD) {
        (void)esp_loader_change_transmission_rate(&session->loader, baud);
    }
    return ESP_LOADER_SUCCESS;
}

static int
is_usb_candidate(struct sp_port *port, const char *os_family)
{
    enum sp_transport transport;
    int vid = 0;
    int pid = 0;
    const char *name;

    transport = sp_get_port_transport(port);
    if (transport != SP_TRANSPORT_USB) {
        /* Some OS builds report native for USB-serial; require a VID. */
        if (sp_get_port_usb_vid_pid(port, &vid, &pid) != SP_OK || vid == 0) {
            return 0;
        }
    } else if (sp_get_port_usb_vid_pid(port, &vid, &pid) != SP_OK || vid == 0) {
        return 0;
    }

    name = sp_get_port_name(port);
    if (name == NULL) {
        return 0;
    }
    if (os_family != NULL && strcmp(os_family, "darwin") == 0) {
        if (strncmp(name, "/dev/tty.", 9) == 0) {
            return 0;
        }
    }
    return 1;
}

static void
format_mac(char *out, size_t out_len, const uint8_t mac[6])
{
    snprintf(out, out_len, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3],
             mac[4], mac[5]);
}

static int
probe_atomvm(esp_loader_t *loader, char *build_info_out, size_t build_info_len, int *count_out)
{
    uint8_t buf[ATOMVM_PROBE_SIZE];
    esp_loader_error_t err;
    size_t i;
    size_t start = 0;
    int count = 0;
    size_t out_used = 0;

    *count_out = 0;
    if (build_info_len > 0) {
        build_info_out[0] = '\0';
    }

    err = esp_loader_flash_read(loader, buf, ATOMVM_PROBE_ADDR, ATOMVM_PROBE_SIZE);
    if (err != ESP_LOADER_SUCCESS) {
        return 0;
    }

    for (i = 0; i <= ATOMVM_PROBE_SIZE; i++) {
        if (i == ATOMVM_PROBE_SIZE || buf[i] == 0) {
            size_t len = i - start;
            if (len > 0) {
                int printable = 1;
                size_t j;
                for (j = 0; j < len; j++) {
                    if (!isprint(buf[start + j])) {
                        printable = 0;
                        break;
                    }
                }
                if (printable) {
                    if (count > 0 && out_used + 1 < build_info_len) {
                        build_info_out[out_used++] = '\n';
                    }
                    if (out_used + len < build_info_len) {
                        memcpy(build_info_out + out_used, buf + start, len);
                        out_used += len;
                        build_info_out[out_used] = '\0';
                        count++;
                    }
                }
            }
            start = i + 1;
        }
    }
    *count_out = count;
    return strstr(build_info_out, "atomvm-esp32") != NULL;
}

static ERL_NIF_TERM
make_build_info_list(ErlNifEnv *env, const char *joined)
{
    ERL_NIF_TERM list = enif_make_list(env, 0);
    const char *p = joined;
    const char *start = joined;
    ERL_NIF_TERM parts[32];
    int n = 0;
    int i;

    if (joined == NULL || joined[0] == '\0') {
        return list;
    }

    while (*p && n < 32) {
        if (*p == '\n') {
            char tmp[128];
            size_t len = (size_t)(p - start);
            if (len >= sizeof(tmp)) {
                len = sizeof(tmp) - 1;
            }
            memcpy(tmp, start, len);
            tmp[len] = '\0';
            parts[n++] = make_binary(env, tmp);
            start = p + 1;
        }
        p++;
    }
    if (start < p && n < 32) {
        parts[n++] = make_binary(env, start);
    }
    list = enif_make_list(env, 0);
    for (i = n - 1; i >= 0; i--) {
        list = enif_make_list_cell(env, parts[i], list);
    }
    return list;
}

static ERL_NIF_TERM
make_device_term(ErlNifEnv *env, const char *port_name, target_chip_t chip, const char *mac,
                 int atomvm, const char *build_joined)
{
    ERL_NIF_TERM empty = enif_make_list(env, 0);
    return enif_make_tuple8(
        env,
        make_atom(env, "device"),
        make_binary(env, port_name),
        make_binary(env, chip_name(chip)),
        make_binary(env, mac),
        make_binary(env, "uart"),
        atomvm ? make_atom(env, "true") : make_atom(env, "false"),
        make_build_info_list(env, build_joined),
        empty);
}

static ERL_NIF_TERM
make_flash_read_term(ErlNifEnv *env, target_chip_t chip, uint32_t flash_size, int bytes_written,
                     const char *output)
{
    return enif_make_tuple8(
        env,
        make_atom(env, "flash_read"),
        enif_make_int(env, (int)bootloader_offset_for(chip)),
        make_binary(env, chip_name(chip)),
        enif_make_int(env, (int)flash_size),
        enif_make_int(env, flash_size_id(flash_size)),
        make_binary(env, flash_size_name(flash_size)),
        enif_make_int(env, bytes_written),
        make_binary(env, output));
}

static uint32_t
align4_up(uint32_t n)
{
    return (n + 3u) & ~3u;
}

static esp_loader_error_t
flash_bytes(esp_loader_t *loader, uint32_t address, const uint8_t *data, uint32_t size)
{
    esp_loader_flash_cfg_t cfg;
    uint32_t padded = align4_up(size);
    uint8_t *pad_buf = NULL;
    const uint8_t *payload = data;
    esp_loader_error_t err;
    uint32_t offset = 0;

    memset(&cfg, 0, sizeof(cfg));
    cfg.offset = address;
    cfg.image_size = padded;
    cfg.block_size = FLASH_BLOCK;
    cfg.skip_verify = false;

    if (padded != size) {
        pad_buf = (uint8_t *)malloc(padded);
        if (pad_buf == NULL) {
            return ESP_LOADER_ERROR_FAIL;
        }
        memcpy(pad_buf, data, size);
        memset(pad_buf + size, 0xff, padded - size);
        payload = pad_buf;
    }

    err = esp_loader_flash_start(loader, &cfg);
    if (err != ESP_LOADER_SUCCESS) {
        free(pad_buf);
        return err;
    }

    while (offset < padded) {
        uint32_t chunk = padded - offset;
        if (chunk > cfg.block_size) {
            chunk = cfg.block_size;
        }
        err = esp_loader_flash_write(loader, &cfg, payload + offset, chunk);
        if (err != ESP_LOADER_SUCCESS) {
            free(pad_buf);
            return err;
        }
        offset += chunk;
    }

    err = esp_loader_flash_finish(loader, &cfg);
    free(pad_buf);
    return err;
}

static int
read_file(const char *path, uint8_t **out_data, uint32_t *out_size)
{
    FILE *f = fopen(path, "rb");
    long sz;
    uint8_t *buf;

    if (f == NULL) {
        return 0;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return 0;
    }
    sz = ftell(f);
    if (sz < 0) {
        fclose(f);
        return 0;
    }
    rewind(f);
    buf = (uint8_t *)malloc((size_t)sz);
    if (buf == NULL) {
        fclose(f);
        return 0;
    }
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        free(buf);
        fclose(f);
        return 0;
    }
    fclose(f);
    *out_data = buf;
    *out_size = (uint32_t)sz;
    return 1;
}

static int
write_file(const char *path, const uint8_t *data, uint32_t size)
{
    FILE *f = fopen(path, "wb");
    if (f == NULL) {
        return 0;
    }
    if (fwrite(data, 1, size, f) != size) {
        fclose(f);
        return 0;
    }
    fclose(f);
    return 1;
}

/* --- NIF entries --------------------------------------------------------- */

static ERL_NIF_TERM
nif_list_devices(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct sp_port **ports = NULL;
    ERL_NIF_TERM list;
    int i;
    char os_family[32] = "other";

    (void)argc;
    if (argc >= 1) {
        (void)get_cstring(env, argv[0], os_family, sizeof(os_family));
    }

    if (sp_list_ports(&ports) != SP_OK) {
        return make_error_bin(env, "failed to list serial ports");
    }

    list = enif_make_list(env, 0);
    if (ports != NULL) {
        for (i = 0; ports[i] != NULL; i++) {
            const char *name;
            esp_session session;
            esp_loader_error_t err;
            uint8_t mac[6];
            char mac_str[32];
            char build_joined[512];
            int build_count = 0;
            int atomvm;
            target_chip_t chip;

            if (!is_usb_candidate(ports[i], os_family)) {
                continue;
            }
            name = sp_get_port_name(ports[i]);
            if (name == NULL) {
                continue;
            }

            err = session_open(&session, name, DEFAULT_BAUD, 1);
            if (err != ESP_LOADER_SUCCESS) {
                continue;
            }

            chip = esp_loader_get_target(&session.loader);
            memset(mac, 0, sizeof(mac));
            (void)esp_loader_read_mac(&session.loader, mac);
            format_mac(mac_str, sizeof(mac_str), mac);
            atomvm = probe_atomvm(&session.loader, build_joined, sizeof(build_joined), &build_count);
            (void)build_count;
            esp_loader_reset_target(&session.loader);
            session_close(&session);

            list = enif_make_list_cell(
                env, make_device_term(env, name, chip, mac_str, atomvm, build_joined), list);
        }
        sp_free_port_list(ports);
    }

    return make_ok(env, list);
}

static ERL_NIF_TERM
nif_select_port(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char port[512];
    char os_family[32] = "other";
    ERL_NIF_TERM devices_term;
    ERL_NIF_TERM list;
    unsigned len;

    (void)argc;
    if (!get_cstring(env, argv[0], port, sizeof(port))) {
        return make_error_bin(env, "port must be a non-empty string");
    }
    if (argc >= 2) {
        (void)get_cstring(env, argv[1], os_family, sizeof(os_family));
    }

    if (strcmp(port, "auto") != 0) {
        return make_ok(env, make_binary(env, port));
    }

    {
        const ERL_NIF_TERM os_arg = make_binary(env, os_family);
        const ERL_NIF_TERM args[1] = {os_arg};
        devices_term = nif_list_devices(env, 1, args);
    }

    if (!enif_is_tuple(env, devices_term)) {
        return make_error_bin(env, "failed to probe devices");
    }
    {
        int arity = 0;
        const ERL_NIF_TERM *tuple;
        if (!enif_get_tuple(env, devices_term, &arity, &tuple) || arity != 2) {
            return make_error_bin(env, "failed to probe devices");
        }
        if (tuple[0] != make_atom(env, "ok")) {
            return devices_term;
        }
        list = tuple[1];
    }

    if (!enif_get_list_length(env, list, &len)) {
        return make_error_bin(env, "failed to probe devices");
    }
    if (len == 0) {
        return make_error_bin(
            env, "Found no ESP32 devices.\nHold BOOT while plugging in the device and try again.");
    }
    if (len > 1) {
        return make_error_bin(env, "Several ESP32 devices found.\nPass one with --port.");
    }
    {
        ERL_NIF_TERM head;
        ERL_NIF_TERM tail;
        const ERL_NIF_TERM *dev;
        int arity = 0;
        if (!enif_get_list_cell(env, list, &head, &tail)) {
            return make_error_bin(env, "failed to probe devices");
        }
        if (!enif_get_tuple(env, head, &arity, &dev) || arity != 8) {
            return make_error_bin(env, "invalid device record");
        }
        return make_ok(env, dev[1]);
    }
}

static ERL_NIF_TERM
nif_select_device(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char port[512];
    char os_family[32] = "other";
    char resolved[512];
    ERL_NIF_TERM select_result;
    ERL_NIF_TERM devices_term;
    ERL_NIF_TERM list;

    (void)argc;
    if (!get_cstring(env, argv[0], port, sizeof(port))) {
        return make_error_bin(env, "port must be a non-empty string");
    }
    if (argc >= 2) {
        (void)get_cstring(env, argv[1], os_family, sizeof(os_family));
    }

    {
        ERL_NIF_TERM args[2] = {argv[0], make_binary(env, os_family)};
        select_result = nif_select_port(env, 2, args);
    }
    {
        int arity = 0;
        const ERL_NIF_TERM *tuple;
        ErlNifBinary bin;
        if (!enif_get_tuple(env, select_result, &arity, &tuple) || arity != 2) {
            return select_result;
        }
        if (tuple[0] != make_atom(env, "ok")) {
            return select_result;
        }
        if (!enif_inspect_binary(env, tuple[1], &bin) || bin.size >= sizeof(resolved)) {
            return make_error_bin(env, "invalid resolved port");
        }
        memcpy(resolved, bin.data, bin.size);
        resolved[bin.size] = '\0';
    }

    {
        ERL_NIF_TERM args[1] = {make_binary(env, os_family)};
        devices_term = nif_list_devices(env, 1, args);
    }
    {
        int arity = 0;
        const ERL_NIF_TERM *tuple;
        if (!enif_get_tuple(env, devices_term, &arity, &tuple) || arity != 2) {
            return devices_term;
        }
        if (tuple[0] != make_atom(env, "ok")) {
            return devices_term;
        }
        list = tuple[1];
    }

    while (!enif_is_empty_list(env, list)) {
        ERL_NIF_TERM head;
        ERL_NIF_TERM tail;
        const ERL_NIF_TERM *dev;
        int arity = 0;
        ErlNifBinary bin;
        if (!enif_get_list_cell(env, list, &head, &tail)) {
            break;
        }
        list = tail;
        if (!enif_get_tuple(env, head, &arity, &dev) || arity != 8) {
            continue;
        }
        if (!enif_inspect_binary(env, dev[1], &bin)) {
            continue;
        }
        if (bin.size == strlen(resolved) && memcmp(bin.data, resolved, bin.size) == 0) {
            return make_ok(env, head);
        }
    }

    return make_ok(env, make_device_term(env, resolved, ESP_UNKNOWN_CHIP, "unknown", 0, ""));
}

static ERL_NIF_TERM
nif_erase_flash(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char port[512];
    esp_session session;
    esp_loader_error_t err;

    (void)argc;
    if (!get_cstring(env, argv[0], port, sizeof(port))) {
        return make_error_bin(env, "port must be a non-empty string");
    }

    err = session_open(&session, port, DEFAULT_BAUD, 1);
    if (err != ESP_LOADER_SUCCESS) {
        return make_error_bin(env, loader_error_str(err));
    }
    err = esp_loader_flash_erase(&session.loader);
    if (err == ESP_LOADER_SUCCESS) {
        esp_loader_reset_target(&session.loader);
    }
    session_close(&session);
    if (err != ESP_LOADER_SUCCESS) {
        return make_error_bin(env, loader_error_str(err));
    }
    return make_ok(env, make_atom(env, "nil"));
}

static ERL_NIF_TERM
nif_read_flash(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char port[512];
    char output[1024];
    int address;
    int size;
    int reset_after = 0;
    esp_session session;
    esp_loader_error_t err;
    uint8_t *buf;
    uint32_t flash_size = 0;
    target_chip_t chip;

    (void)argc;
    if (!get_cstring(env, argv[0], port, sizeof(port))) {
        return make_error_bin(env, "port must be a non-empty string");
    }
    if (!enif_get_int(env, argv[1], &address) || address < 0) {
        return make_error_bin(env, "address must be a non-negative integer");
    }
    if (!enif_get_int(env, argv[2], &size) || size <= 0) {
        return make_error_bin(env, "size must be a positive integer");
    }
    if (!get_cstring(env, argv[3], output, sizeof(output))) {
        return make_error_bin(env, "output path must be a non-empty string");
    }
    if (argv[4] == make_atom(env, "true")) {
        reset_after = 1;
    }

    buf = (uint8_t *)malloc((size_t)size);
    if (buf == NULL) {
        return make_error_bin(env, "out of memory");
    }

    err = session_open(&session, port, DEFAULT_BAUD, 1);
    if (err != ESP_LOADER_SUCCESS) {
        free(buf);
        return make_error_bin(env, loader_error_str(err));
    }

    chip = esp_loader_get_target(&session.loader);
    (void)esp_loader_flash_detect_size(&session.loader, &flash_size);
    err = esp_loader_flash_read(&session.loader, buf, (uint32_t)address, (uint32_t)size);
    if (err == ESP_LOADER_SUCCESS) {
        if (!write_file(output, buf, (uint32_t)size)) {
            err = ESP_LOADER_ERROR_FAIL;
        }
    }
    if (reset_after) {
        esp_loader_reset_target(&session.loader);
    }
    session_close(&session);
    free(buf);

    if (err != ESP_LOADER_SUCCESS) {
        return make_error_bin(env, loader_error_str(err));
    }
    return make_ok(env, make_flash_read_term(env, chip, flash_size, size, output));
}

static ERL_NIF_TERM
nif_write_flash_data(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char port[512];
    char path[1024];
    int address;
    int baud = DEFAULT_BAUD;
    uint8_t *data = NULL;
    uint32_t size = 0;
    esp_session session;
    esp_loader_error_t err;

    (void)argc;
    if (!get_cstring(env, argv[0], port, sizeof(port))) {
        return make_error_bin(env, "port must be a non-empty string");
    }
    if (!enif_get_int(env, argv[1], &address) || address < 0) {
        return make_error_bin(env, "address must be a non-negative integer");
    }
    if (!get_cstring(env, argv[2], path, sizeof(path))) {
        return make_error_bin(env, "file path must be a non-empty string");
    }
    if (argc >= 4) {
        (void)enif_get_int(env, argv[3], &baud);
    }

    if (!read_file(path, &data, &size)) {
        return make_error_bin(env, "could not read flash payload file");
    }

    err = session_open(&session, port, (uint32_t)baud, 1);
    if (err != ESP_LOADER_SUCCESS) {
        free(data);
        return make_error_bin(env, loader_error_str(err));
    }
    err = flash_bytes(&session.loader, (uint32_t)address, data, size);
    if (err == ESP_LOADER_SUCCESS) {
        esp_loader_reset_target(&session.loader);
    }
    session_close(&session);
    free(data);
    if (err != ESP_LOADER_SUCCESS) {
        return make_error_bin(env, loader_error_str(err));
    }
    return make_ok(env, make_atom(env, "nil"));
}

static ERL_NIF_TERM
nif_write_flash_image(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    /* port, baud, address, file */
    const ERL_NIF_TERM args[4] = {argv[0], argv[2], argv[3], argv[1]};
    (void)argc;
    return nif_write_flash_data(env, 4, args);
}

static ERL_NIF_TERM
nif_write_flash_parts(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char port[512];
    int baud;
    ERL_NIF_TERM parts;
    esp_session session;
    esp_loader_error_t err;

    (void)argc;
    if (!get_cstring(env, argv[0], port, sizeof(port))) {
        return make_error_bin(env, "port must be a non-empty string");
    }
    if (!enif_get_int(env, argv[1], &baud) || baud <= 0) {
        return make_error_bin(env, "baud must be a positive integer");
    }
    parts = argv[2];
    if (!enif_is_list(env, parts)) {
        return make_error_bin(env, "parts must be a list of {address, path}");
    }

    err = session_open(&session, port, (uint32_t)baud, 1);
    if (err != ESP_LOADER_SUCCESS) {
        return make_error_bin(env, loader_error_str(err));
    }

    while (!enif_is_empty_list(env, parts)) {
        ERL_NIF_TERM head;
        ERL_NIF_TERM tail;
        const ERL_NIF_TERM *tuple;
        int arity = 0;
        int address;
        char path[1024];
        uint8_t *data = NULL;
        uint32_t size = 0;

        if (!enif_get_list_cell(env, parts, &head, &tail)) {
            break;
        }
        parts = tail;
        if (!enif_get_tuple(env, head, &arity, &tuple) || arity != 2) {
            session_close(&session);
            return make_error_bin(env, "each part must be {address, path}");
        }
        if (!enif_get_int(env, tuple[0], &address) || address < 0) {
            session_close(&session);
            return make_error_bin(env, "invalid part address");
        }
        if (!get_cstring(env, tuple[1], path, sizeof(path))) {
            session_close(&session);
            return make_error_bin(env, "invalid part path");
        }
        if (!read_file(path, &data, &size)) {
            session_close(&session);
            return make_error_bin(env, "firmware part not found");
        }
        err = flash_bytes(&session.loader, (uint32_t)address, data, size);
        free(data);
        if (err != ESP_LOADER_SUCCESS) {
            session_close(&session);
            return make_error_bin(env, loader_error_str(err));
        }
    }

    esp_loader_reset_target(&session.loader);
    session_close(&session);
    return make_ok(env, make_atom(env, "nil"));
}

static ErlNifFunc nif_funcs[] = {
    {"list_devices_nif", 1, nif_list_devices, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"select_port_nif", 2, nif_select_port, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"select_device_nif", 2, nif_select_device, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"erase_flash_nif", 1, nif_erase_flash, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"read_flash_nif", 5, nif_read_flash, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"write_flash_data_nif", 3, nif_write_flash_data, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"write_flash_image_nif", 4, nif_write_flash_image, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"write_flash_parts_nif", 3, nif_write_flash_parts, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(orbital_esp_ffi, nif_funcs, NULL, NULL, NULL, NULL)
