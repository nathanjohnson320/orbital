#include <erl_nif.h>
#include <libserialport.h>
#include <string.h>
#include <stdlib.h>

typedef struct {
    struct sp_port *port;
} serial_handle;

static ErlNifResourceType *serial_resource_type = NULL;

static void
serial_destructor(ErlNifEnv *env, void *obj)
{
    serial_handle *handle = (serial_handle *)obj;
    (void)env;
    if (handle->port != NULL) {
        sp_close(handle->port);
        sp_free_port(handle->port);
        handle->port = NULL;
    }
}

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

static ERL_NIF_TERM
sp_error_term(ErlNifEnv *env, enum sp_return code)
{
    char *msg;
    ERL_NIF_TERM term;

    if (code == SP_ERR_FAIL) {
        msg = sp_last_error_message();
        if (msg != NULL) {
            term = make_error_bin(env, msg);
            sp_free_error_message(msg);
            return term;
        }
        return make_error_bin(env, "serial port operation failed");
    }
    if (code == SP_ERR_ARG) {
        return make_error_bin(env, "invalid serial port argument");
    }
    if (code == SP_ERR_MEM) {
        return make_error_bin(env, "out of memory");
    }
    if (code == SP_ERR_SUPP) {
        return make_error_bin(env, "serial operation not supported");
    }
    return make_error_bin(env, "unknown serial port error");
}

static int
get_handle(ErlNifEnv *env, ERL_NIF_TERM term, serial_handle **out)
{
    serial_handle *handle;
    if (!enif_get_resource(env, term, serial_resource_type, (void **)&handle)) {
        return 0;
    }
    if (handle->port == NULL) {
        return 0;
    }
    *out = handle;
    return 1;
}

static int
get_bool(ErlNifEnv *env, ERL_NIF_TERM term, int *out)
{
    if (term == make_atom(env, "true")) {
        *out = 1;
        return 1;
    }
    if (term == make_atom(env, "false")) {
        *out = 0;
        return 1;
    }
    return 0;
}

static const char *
transport_name(enum sp_transport transport)
{
    switch (transport) {
    case SP_TRANSPORT_NATIVE:
        return "native";
    case SP_TRANSPORT_USB:
        return "usb";
    case SP_TRANSPORT_BLUETOOTH:
        return "bluetooth";
    default:
        return "unknown";
    }
}

static ERL_NIF_TERM
list_ports(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct sp_port **ports;
    enum sp_return rc;
    ERL_NIF_TERM list;
    int i;

    (void)argc;
    (void)argv;

    rc = sp_list_ports(&ports);
    if (rc != SP_OK) {
        return sp_error_term(env, rc);
    }

    list = enif_make_list(env, 0);
    if (ports != NULL) {
        for (i = 0; ports[i] != NULL; i++) {
            const char *name = sp_get_port_name(ports[i]);
            const char *description = sp_get_port_description(ports[i]);
            const char *transport = transport_name(sp_get_port_transport(ports[i]));
            ERL_NIF_TERM entry = enif_make_tuple3(
                env,
                make_binary(env, name),
                make_binary(env, description),
                make_binary(env, transport));
            list = enif_make_list_cell(env, entry, list);
        }
        sp_free_port_list(ports);
    }

    return make_ok(env, list);
}

static ERL_NIF_TERM
open_port(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary name_bin;
    char name[512];
    int baud;
    struct sp_port *port = NULL;
    serial_handle *handle;
    ERL_NIF_TERM term;
    enum sp_return rc;

    (void)argc;

    if (!enif_inspect_binary(env, argv[0], &name_bin) || name_bin.size == 0 || name_bin.size >= sizeof(name)) {
        return make_error_bin(env, "port name must be a non-empty string");
    }
    memcpy(name, name_bin.data, name_bin.size);
    name[name_bin.size] = '\0';

    if (!enif_get_int(env, argv[1], &baud) || baud <= 0) {
        return make_error_bin(env, "baud must be a positive integer");
    }

    rc = sp_get_port_by_name(name, &port);
    if (rc != SP_OK) {
        return sp_error_term(env, rc);
    }

    rc = sp_open(port, SP_MODE_READ_WRITE);
    if (rc != SP_OK) {
        sp_free_port(port);
        return sp_error_term(env, rc);
    }

    rc = sp_set_baudrate(port, baud);
    if (rc != SP_OK) {
        sp_close(port);
        sp_free_port(port);
        return sp_error_term(env, rc);
    }
    (void)sp_set_bits(port, 8);
    (void)sp_set_parity(port, SP_PARITY_NONE);
    (void)sp_set_stopbits(port, 1);
    (void)sp_set_flowcontrol(port, SP_FLOWCONTROL_NONE);

    handle = enif_alloc_resource(serial_resource_type, sizeof(serial_handle));
    if (handle == NULL) {
        sp_close(port);
        sp_free_port(port);
        return make_error_bin(env, "out of memory");
    }
    handle->port = port;
    term = enif_make_resource(env, handle);
    enif_release_resource(handle);
    return make_ok(env, term);
}

static ERL_NIF_TERM
close_port(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    serial_handle *handle;

    (void)argc;
    if (!enif_get_resource(env, argv[0], serial_resource_type, (void **)&handle)) {
        return make_error_bin(env, "invalid serial port handle");
    }
    if (handle->port != NULL) {
        sp_close(handle->port);
        sp_free_port(handle->port);
        handle->port = NULL;
    }
    return make_atom(env, "ok");
}

static ERL_NIF_TERM
read_port(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    serial_handle *handle;
    int max_bytes;
    int timeout_ms;
    unsigned char *buf;
    int n;
    ERL_NIF_TERM binary;

    (void)argc;
    if (!get_handle(env, argv[0], &handle)) {
        return enif_make_tuple2(env, make_atom(env, "error"), make_atom(env, "disconnected"));
    }
    if (!enif_get_int(env, argv[1], &max_bytes) || max_bytes <= 0) {
        return make_error_bin(env, "max_bytes must be a positive integer");
    }
    if (!enif_get_int(env, argv[2], &timeout_ms) || timeout_ms < 0) {
        return make_error_bin(env, "timeout_ms must be a non-negative integer");
    }
    if (max_bytes > 65536) {
        max_bytes = 65536;
    }

    buf = enif_make_new_binary(env, (size_t)max_bytes, &binary);
    if (buf == NULL) {
        return make_error_bin(env, "out of memory");
    }

    n = sp_blocking_read(handle->port, buf, (size_t)max_bytes, (unsigned int)timeout_ms);
    if (n < 0) {
        return enif_make_tuple2(env, make_atom(env, "error"), make_atom(env, "disconnected"));
    }
    if (n == 0) {
        return enif_make_tuple2(env, make_atom(env, "ok"), make_atom(env, "empty"));
    }
    if (n != max_bytes) {
        binary = enif_make_sub_binary(env, binary, 0, (size_t)n);
    }
    return make_ok(env, binary);
}

static ERL_NIF_TERM
set_rts(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    serial_handle *handle;
    int value;

    (void)argc;
    if (!get_handle(env, argv[0], &handle)) {
        return make_error_bin(env, "invalid serial port handle");
    }
    if (!get_bool(env, argv[1], &value)) {
        return make_error_bin(env, "rts value must be a boolean");
    }
    (void)sp_set_rts(handle->port, value ? SP_RTS_ON : SP_RTS_OFF);
    return make_atom(env, "ok");
}

static ERL_NIF_TERM
set_dtr(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    serial_handle *handle;
    int value;

    (void)argc;
    if (!get_handle(env, argv[0], &handle)) {
        return make_error_bin(env, "invalid serial port handle");
    }
    if (!get_bool(env, argv[1], &value)) {
        return make_error_bin(env, "dtr value must be a boolean");
    }
    (void)sp_set_dtr(handle->port, value ? SP_DTR_ON : SP_DTR_OFF);
    return make_atom(env, "ok");
}

static int
on_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    ErlNifResourceFlags tried;
    (void)priv_data;
    (void)load_info;

    serial_resource_type = enif_open_resource_type(
        env,
        NULL,
        "orbital_serial_port",
        serial_destructor,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
        &tried);
    return serial_resource_type == NULL ? 1 : 0;
}

static ErlNifFunc nif_funcs[] = {
    {"list_ports_nif", 0, list_ports, 0},
    {"open_nif", 2, open_port, 0},
    {"close_nif", 1, close_port, 0},
    {"read_nif", 3, read_port, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"set_rts_nif", 2, set_rts, 0},
    {"set_dtr_nif", 2, set_dtr, 0},
};

ERL_NIF_INIT(orbital_serial_ffi, nif_funcs, on_load, NULL, NULL, NULL)
