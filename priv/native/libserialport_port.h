/*
 * esp-serial-flasher port backed by libserialport (macOS / Linux / Windows).
 * Apache-2.0 — Orbital.
 */
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include "esp_loader_io.h"
#include <libserialport.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    esp_loader_port_t port;
    const char *device;
    uint32_t baudrate;
    struct sp_port *sp;
    int64_t time_end_ms;
    bool is_usb_jtag;
} libserialport_port_t;

extern const esp_loader_port_ops_t libserialport_uart_ops;

#ifdef __cplusplus
}
#endif
