/*
 * esp-serial-flasher port using libserialport.
 * Reset/boot sequences mirror Espressif's linux_port DTR/RTS behaviour.
 * Apache-2.0 — Orbital.
 */

#include "libserialport_port.h"
#include "esp_loader.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <time.h>
#include <unistd.h>
#endif

#ifndef SERIAL_FLASHER_RESET_HOLD_TIME_MS
#define SERIAL_FLASHER_RESET_HOLD_TIME_MS 100
#endif
#ifndef SERIAL_FLASHER_BOOT_HOLD_TIME_MS
#define SERIAL_FLASHER_BOOT_HOLD_TIME_MS 50
#endif
#ifndef SERIAL_FLASHER_BOOT_INVERT
#define SERIAL_FLASHER_BOOT_INVERT 0
#endif
#ifndef SERIAL_FLASHER_RESET_INVERT
#define SERIAL_FLASHER_RESET_INVERT 0
#endif

#define ESPRESSIF_USB_JTAG_VID 0x303A
#define ESPRESSIF_USB_JTAG_PID 0x1001

#define DTR_BOOT_ASSERT (!SERIAL_FLASHER_BOOT_INVERT)
#define DTR_BOOT_DEASSERT (SERIAL_FLASHER_BOOT_INVERT)
#define RTS_RESET_ASSERT (!SERIAL_FLASHER_RESET_INVERT)
#define RTS_RESET_DEASSERT (SERIAL_FLASHER_RESET_INVERT)

static int64_t time_now_ms(void)
{
#if defined(_WIN32)
    return (int64_t)GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000LL + (int64_t)ts.tv_nsec / 1000000LL;
#endif
}

static void delay_ms_raw(uint32_t ms)
{
#if defined(_WIN32)
    Sleep(ms);
#else
    usleep((useconds_t)ms * 1000u);
#endif
}

static void set_dtr_rts(struct sp_port *sp, int dtr_assert, int rts_assert)
{
    (void)sp_set_dtr(sp, dtr_assert ? SP_DTR_ON : SP_DTR_OFF);
    (void)sp_set_rts(sp, rts_assert ? SP_RTS_ON : SP_RTS_OFF);
}

static bool detect_usb_jtag(struct sp_port *sp)
{
    int vid = 0;
    int pid = 0;
    if (sp_get_port_usb_vid_pid(sp, &vid, &pid) != SP_OK) {
        return false;
    }
    return vid == ESPRESSIF_USB_JTAG_VID && pid == ESPRESSIF_USB_JTAG_PID;
}

static esp_loader_error_t libsp_init(esp_loader_port_t *port)
{
    libserialport_port_t *p = container_of(port, libserialport_port_t, port);
    enum sp_return rc;

    if (p->device == NULL || p->device[0] == '\0') {
        return ESP_LOADER_ERROR_INVALID_PARAM;
    }

    rc = sp_get_port_by_name(p->device, &p->sp);
    if (rc != SP_OK) {
        return ESP_LOADER_ERROR_FAIL;
    }

    rc = sp_open(p->sp, SP_MODE_READ_WRITE);
    if (rc != SP_OK) {
        sp_free_port(p->sp);
        p->sp = NULL;
        return ESP_LOADER_ERROR_FAIL;
    }

    if (p->baudrate == 0) {
        p->baudrate = 115200;
    }
    (void)sp_set_baudrate(p->sp, (int)p->baudrate);
    (void)sp_set_bits(p->sp, 8);
    (void)sp_set_parity(p->sp, SP_PARITY_NONE);
    (void)sp_set_stopbits(p->sp, 1);
    (void)sp_set_flowcontrol(p->sp, SP_FLOWCONTROL_NONE);

    p->is_usb_jtag = detect_usb_jtag(p->sp);
    p->time_end_ms = 0;
    delay_ms_raw(10);
    return ESP_LOADER_SUCCESS;
}

static void libsp_deinit(esp_loader_port_t *port)
{
    libserialport_port_t *p = container_of(port, libserialport_port_t, port);
    if (p->sp != NULL) {
        sp_close(p->sp);
        sp_free_port(p->sp);
        p->sp = NULL;
    }
}

static void libsp_start_timer(esp_loader_port_t *port, uint32_t ms)
{
    libserialport_port_t *p = container_of(port, libserialport_port_t, port);
    p->time_end_ms = time_now_ms() + (int64_t)ms;
}

static uint32_t libsp_remaining_time(esp_loader_port_t *port)
{
    libserialport_port_t *p = container_of(port, libserialport_port_t, port);
    int64_t remaining = p->time_end_ms - time_now_ms();
    return remaining > 0 ? (uint32_t)remaining : 0;
}

static void libsp_delay_ms(esp_loader_port_t *port, uint32_t ms)
{
    (void)port;
    delay_ms_raw(ms);
}

static esp_loader_error_t libsp_write(esp_loader_port_t *port, const uint8_t *data,
                                      uint16_t size, uint32_t timeout)
{
    libserialport_port_t *p = container_of(port, libserialport_port_t, port);
    int written;

    if (p->sp == NULL) {
        return ESP_LOADER_ERROR_FAIL;
    }
    written = sp_blocking_write(p->sp, data, size, timeout == 0 ? 1 : timeout);
    if (written < 0) {
        return ESP_LOADER_ERROR_FAIL;
    }
    if ((uint16_t)written < size) {
        return ESP_LOADER_ERROR_TIMEOUT;
    }
    (void)sp_drain(p->sp);
    return ESP_LOADER_SUCCESS;
}

static esp_loader_error_t libsp_read(esp_loader_port_t *port, uint8_t *data, uint16_t size,
                                     uint32_t timeout)
{
    libserialport_port_t *p = container_of(port, libserialport_port_t, port);
    uint16_t got = 0;

    if (p->sp == NULL) {
        return ESP_LOADER_ERROR_FAIL;
    }

    while (got < size) {
        uint32_t remaining = libsp_remaining_time(port);
        uint32_t slice = remaining;
        int n;

        if (timeout > 0 && remaining == 0 && got == 0) {
            /* Fall back to caller-supplied timeout when timer already elapsed. */
            slice = timeout;
        }
        if (slice == 0) {
            return ESP_LOADER_ERROR_TIMEOUT;
        }

        n = sp_blocking_read(p->sp, data + got, (size_t)(size - got), slice);
        if (n < 0) {
            return ESP_LOADER_ERROR_FAIL;
        }
        if (n == 0) {
            if (libsp_remaining_time(port) == 0) {
                return ESP_LOADER_ERROR_TIMEOUT;
            }
            continue;
        }
        got += (uint16_t)n;
    }
    return ESP_LOADER_SUCCESS;
}

static esp_loader_error_t libsp_change_rate(esp_loader_port_t *port, uint32_t baudrate)
{
    libserialport_port_t *p = container_of(port, libserialport_port_t, port);
    if (p->sp == NULL) {
        return ESP_LOADER_ERROR_FAIL;
    }
    if (sp_set_baudrate(p->sp, (int)baudrate) != SP_OK) {
        return ESP_LOADER_ERROR_INVALID_PARAM;
    }
    p->baudrate = baudrate;
    return ESP_LOADER_SUCCESS;
}

static void libsp_reset_target(esp_loader_port_t *port)
{
    libserialport_port_t *p = container_of(port, libserialport_port_t, port);
    if (p->sp == NULL) {
        return;
    }
    set_dtr_rts(p->sp, 0, RTS_RESET_ASSERT);
    delay_ms_raw(SERIAL_FLASHER_RESET_HOLD_TIME_MS);
    set_dtr_rts(p->sp, 0, RTS_RESET_DEASSERT);
    delay_ms_raw(50);
}

static void libsp_enter_bootloader(esp_loader_port_t *port)
{
    libserialport_port_t *p = container_of(port, libserialport_port_t, port);
    if (p->sp == NULL) {
        return;
    }

    if (p->is_usb_jtag) {
        set_dtr_rts(p->sp, DTR_BOOT_DEASSERT, RTS_RESET_DEASSERT);
        delay_ms_raw(SERIAL_FLASHER_RESET_HOLD_TIME_MS);
        set_dtr_rts(p->sp, DTR_BOOT_ASSERT, RTS_RESET_DEASSERT);
        delay_ms_raw(SERIAL_FLASHER_RESET_HOLD_TIME_MS);
        set_dtr_rts(p->sp, DTR_BOOT_ASSERT, RTS_RESET_ASSERT);
        set_dtr_rts(p->sp, DTR_BOOT_DEASSERT, RTS_RESET_ASSERT);
        delay_ms_raw(SERIAL_FLASHER_RESET_HOLD_TIME_MS);
        set_dtr_rts(p->sp, DTR_BOOT_DEASSERT, RTS_RESET_DEASSERT);
        delay_ms_raw(200);
    } else {
        set_dtr_rts(p->sp, DTR_BOOT_DEASSERT, RTS_RESET_DEASSERT);
        set_dtr_rts(p->sp, DTR_BOOT_ASSERT, RTS_RESET_ASSERT);
        set_dtr_rts(p->sp, DTR_BOOT_DEASSERT, RTS_RESET_ASSERT);
        delay_ms_raw(SERIAL_FLASHER_RESET_HOLD_TIME_MS);
        set_dtr_rts(p->sp, DTR_BOOT_ASSERT, RTS_RESET_DEASSERT);
        delay_ms_raw(SERIAL_FLASHER_BOOT_HOLD_TIME_MS);
        set_dtr_rts(p->sp, DTR_BOOT_DEASSERT, RTS_RESET_DEASSERT);
    }
    (void)sp_flush(p->sp, SP_BUF_BOTH);
}

const esp_loader_port_ops_t libserialport_uart_ops = {
    .init = libsp_init,
    .deinit = libsp_deinit,
    .enter_bootloader = libsp_enter_bootloader,
    .reset_target = libsp_reset_target,
    .start_timer = libsp_start_timer,
    .remaining_time = libsp_remaining_time,
    .delay_ms = libsp_delay_ms,
    .log = NULL,
    .log_hex = NULL,
    .change_transmission_rate = libsp_change_rate,
    .write = libsp_write,
    .read = libsp_read,
};
