#!/bin/bash
# Patch libssh2 to add streamlocal-forward@openssh.com support.
# This adds Unix domain socket remote forwarding (the equivalent of ssh -R /path).
# Required for iOS waypipe to work with native unmodified waypipe on the remote.
set -e

echo "=== Patching libssh2 for streamlocal (Unix socket forwarding) ==="
chmod -R u+w . 2>/dev/null || true

# --- 1. Patch include/libssh2.h: add public API declarations ---
python3 <<'PATCH_HEADER'
path = "include/libssh2.h"
with open(path, "r") as f:
    content = f.read()

if "forward_listen_streamlocal" in content:
    print("libssh2.h already patched for streamlocal")
else:
    marker = "LIBSSH2_API int libssh2_channel_forward_cancel(LIBSSH2_LISTENER *listener);"
    if marker not in content:
        print("ERROR: Could not find forward_cancel declaration in libssh2.h")
        exit(1)
    insert = """LIBSSH2_API int libssh2_channel_forward_cancel(LIBSSH2_LISTENER *listener);

/* streamlocal-forward@openssh.com: Unix domain socket remote forwarding.
 * Creates a listening Unix socket on the remote. When something connects,
 * a forwarded-streamlocal@openssh.com channel is opened back to us.
 * Requires OpenSSH >= 6.7. Use libssh2_channel_forward_accept() to accept. */
LIBSSH2_API LIBSSH2_LISTENER *
libssh2_channel_forward_listen_streamlocal(LIBSSH2_SESSION *session,
                                           const char *socket_path,
                                           int queue_maxsize);
"""
    content = content.replace(marker, insert)
    with open(path, "w") as f:
        f.write(content)
    print("Patched include/libssh2.h: added streamlocal API")
PATCH_HEADER

# --- 2. Patch src/libssh2_priv.h: add listener fields and state struct ---
python3 <<'PATCH_PRIV'
path = "src/libssh2_priv.h"
with open(path, "r") as f:
    content = f.read()

if "is_streamlocal" in content:
    print("libssh2_priv.h already patched for streamlocal")
else:
    # Add streamlocal fields to LIBSSH2_LISTENER
    old_listener = """    char *host;
    int port;

    /* a list of CHANNELs for this listener */"""
    new_listener = """    char *host;
    int port;

    /* streamlocal-forward@openssh.com: Unix socket path on remote */
    char *streamlocal_path;
    int is_streamlocal;

    /* a list of CHANNELs for this listener */"""
    if old_listener in content:
        content = content.replace(old_listener, new_listener)
        print("Added streamlocal fields to LIBSSH2_LISTENER")
    else:
        print("WARNING: Could not find LIBSSH2_LISTENER fields to patch")

    # Add streamlocal state struct after packet_queue_listener_state_t
    old_state = """} packet_queue_listener_state_t;

#define X11FwdUnAvil"""
    new_state = """} packet_queue_listener_state_t;

#define FwdStreamlocalNotReq "Streamlocal forward not requested"

typedef struct packet_queue_streamlocal_state_t
{
    libssh2_nonblocking_states state;
    unsigned char packet[17 + (sizeof(FwdStreamlocalNotReq) - 1)];
    uint32_t sender_channel;
    uint32_t initial_window_size;
    uint32_t packet_size;
    unsigned char *socket_path;
    uint32_t socket_path_len;
    LIBSSH2_CHANNEL *channel;
} packet_queue_streamlocal_state_t;

#define X11FwdUnAvil"""
    if old_state in content:
        content = content.replace(old_state, new_state)
        print("Added packet_queue_streamlocal_state_t")
    else:
        print("WARNING: Could not find packet_queue_listener_state_t end")

    # Add streamlocal state to session struct
    old_session = """    packet_queue_listener_state_t packAdd_Qlstn_state;
    packet_x11_open_state_t packAdd_x11open_state;"""
    new_session = """    packet_queue_listener_state_t packAdd_Qlstn_state;
    packet_queue_streamlocal_state_t packAdd_Qstreamlocal_state;
    packet_x11_open_state_t packAdd_x11open_state;"""
    if old_session in content:
        content = content.replace(old_session, new_session)
        print("Added packAdd_Qstreamlocal_state to session")
    else:
        print("WARNING: Could not find packAdd_Qlstn_state in session")

    # Add new nonblocking state enum value for streamlocal jump
    old_enum_end = "    libssh2_NB_state_jumpauthagent\n} libssh2_nonblocking_states;"
    new_enum_end = "    libssh2_NB_state_jumpauthagent,\n    libssh2_NB_state_jump_streamlocal\n} libssh2_nonblocking_states;"
    if old_enum_end in content:
        content = content.replace(old_enum_end, new_enum_end)
        print("Added libssh2_NB_state_jump_streamlocal to enum")
    else:
        print("WARNING: Could not find nonblocking_states enum end")

    with open(path, "w") as f:
        f.write(content)
    print("Patched src/libssh2_priv.h")
PATCH_PRIV

# --- 3. Patch src/channel.c: add streamlocal forward_listen and update forward_cancel ---
python3 <<'PATCH_CHANNEL'
path = "src/channel.c"
with open(path, "r") as f:
    content = f.read()

if "channel_forward_listen_streamlocal" in content:
    print("channel.c already patched for streamlocal")
else:
    # Insert streamlocal forward_listen before _libssh2_channel_forward_cancel
    marker = """/*
 * _libssh2_channel_forward_cancel
 *
 * Stop listening on a remote port and free the listener
 * Toss out any pending (un-accept()ed) connections
 *
 * Return 0 on success, LIBSSH2_ERROR_EAGAIN if would block, -1 on error
 */
int _libssh2_channel_forward_cancel(LIBSSH2_LISTENER *listener)"""

    streamlocal_code = r"""/*
 * channel_forward_listen_streamlocal
 *
 * Request remote Unix socket forwarding via streamlocal-forward@openssh.com.
 * The SSH server creates a listening Unix socket at socket_path on the remote.
 */
static LIBSSH2_LISTENER *
channel_forward_listen_streamlocal(LIBSSH2_SESSION *session,
                                   const char *socket_path,
                                   int queue_maxsize)
{
    unsigned char *s;
    static const unsigned char reply_codes[3] =
        { SSH_MSG_REQUEST_SUCCESS, SSH_MSG_REQUEST_FAILURE, 0 };
    int rc;
    static const char req[] = "streamlocal-forward@openssh.com";

    if(!socket_path)
        return NULL;

    if(session->fwdLstn_state == libssh2_NB_state_idle) {
        session->fwdLstn_host_len = (uint32_t)strlen(socket_path);
        /* packet_type(1) + request_len(4) + request + want_reply(1) +
           path_len(4) + path */
        session->fwdLstn_packet_len =
            1 + 4 + (uint32_t)(sizeof(req) - 1) + 1 +
            4 + session->fwdLstn_host_len;

        memset(&session->fwdLstn_packet_requirev_state, 0,
               sizeof(session->fwdLstn_packet_requirev_state));

        _libssh2_debug((session, LIBSSH2_TRACE_CONN,
                        "Requesting streamlocal-forward for %s",
                        socket_path));

        s = session->fwdLstn_packet =
            LIBSSH2_ALLOC(session, session->fwdLstn_packet_len);
        if(!session->fwdLstn_packet) {
            _libssh2_error(session, LIBSSH2_ERROR_ALLOC,
                           "Unable to allocate memory for "
                           "streamlocal-forward packet");
            return NULL;
        }

        *(s++) = SSH_MSG_GLOBAL_REQUEST;
        _libssh2_store_str(&s, req, sizeof(req) - 1);
        *(s++) = 0x01; /* want_reply */
        _libssh2_store_str(&s, socket_path, session->fwdLstn_host_len);

        session->fwdLstn_state = libssh2_NB_state_created;
    }

    if(session->fwdLstn_state == libssh2_NB_state_created) {
        rc = _libssh2_transport_send(session,
                                     session->fwdLstn_packet,
                                     session->fwdLstn_packet_len,
                                     NULL, 0);
        if(rc == LIBSSH2_ERROR_EAGAIN) {
            _libssh2_error(session, LIBSSH2_ERROR_EAGAIN,
                           "Would block sending streamlocal-forward request");
            return NULL;
        }
        else if(rc) {
            _libssh2_error(session, LIBSSH2_ERROR_SOCKET_SEND,
                           "Unable to send streamlocal-forward request");
            LIBSSH2_FREE(session, session->fwdLstn_packet);
            session->fwdLstn_packet = NULL;
            session->fwdLstn_state = libssh2_NB_state_idle;
            return NULL;
        }
        LIBSSH2_FREE(session, session->fwdLstn_packet);
        session->fwdLstn_packet = NULL;
        session->fwdLstn_state = libssh2_NB_state_sent;
    }

    if(session->fwdLstn_state == libssh2_NB_state_sent) {
        unsigned char *data;
        size_t data_len;
        rc = _libssh2_packet_requirev(session, reply_codes, &data, &data_len,
                                      0, NULL, 0,
                                      &session->fwdLstn_packet_requirev_state);
        if(rc == LIBSSH2_ERROR_EAGAIN) {
            _libssh2_error(session, LIBSSH2_ERROR_EAGAIN, "Would block");
            return NULL;
        }
        else if(rc || (data_len < 1)) {
            _libssh2_error(session, LIBSSH2_ERROR_PROTO, "Unknown");
            session->fwdLstn_state = libssh2_NB_state_idle;
            return NULL;
        }

        if(data[0] == SSH_MSG_REQUEST_SUCCESS) {
            LIBSSH2_LISTENER *listener;
            listener = LIBSSH2_CALLOC(session, sizeof(LIBSSH2_LISTENER));
            if(!listener) {
                _libssh2_error(session, LIBSSH2_ERROR_ALLOC,
                               "Unable to allocate streamlocal listener");
            }
            else {
                size_t path_len = strlen(socket_path);
                listener->streamlocal_path =
                    LIBSSH2_ALLOC(session, path_len + 1);
                if(!listener->streamlocal_path) {
                    _libssh2_error(session, LIBSSH2_ERROR_ALLOC,
                                   "Unable to allocate streamlocal path");
                    LIBSSH2_FREE(session, listener);
                    listener = NULL;
                }
                else {
                    listener->session = session;
                    memcpy(listener->streamlocal_path, socket_path, path_len);
                    listener->streamlocal_path[path_len] = 0;
                    listener->is_streamlocal = 1;
                    listener->host = listener->streamlocal_path;
                    listener->port = 0;
                    listener->queue_size = 0;
                    listener->queue_maxsize = queue_maxsize;
                    _libssh2_list_add(&session->listeners, &listener->node);
                }
            }

            LIBSSH2_FREE(session, data);
            session->fwdLstn_state = libssh2_NB_state_idle;
            return listener;
        }
        else if(data[0] == SSH_MSG_REQUEST_FAILURE) {
            LIBSSH2_FREE(session, data);
            _libssh2_error(session, LIBSSH2_ERROR_REQUEST_DENIED,
                           "streamlocal-forward request denied by server");
            session->fwdLstn_state = libssh2_NB_state_idle;
            return NULL;
        }
    }

    session->fwdLstn_state = libssh2_NB_state_idle;
    return NULL;
}

LIBSSH2_API LIBSSH2_LISTENER *
libssh2_channel_forward_listen_streamlocal(LIBSSH2_SESSION *session,
                                           const char *socket_path,
                                           int queue_maxsize)
{
    LIBSSH2_LISTENER *ptr;
    if(!session)
        return NULL;
    BLOCK_ADJUST_ERRNO(ptr, session,
                       channel_forward_listen_streamlocal(session, socket_path,
                                                         queue_maxsize));
    return ptr;
}

""" + marker

    if marker in content:
        content = content.replace(marker, streamlocal_code)
        print("Added channel_forward_listen_streamlocal()")
    else:
        print("WARNING: Could not find _libssh2_channel_forward_cancel marker")

    # Update _libssh2_channel_forward_cancel to handle streamlocal
    old_cancel_body = '    if(listener->chanFwdCncl_state == libssh2_NB_state_idle) {\n        _libssh2_debug((session, LIBSSH2_TRACE_CONN,\n                       "Cancelling tcpip-forward session for %s:%d",\n                       listener->host, listener->port));\n\n        s = packet = LIBSSH2_ALLOC(session, packet_len);\n        if(!packet) {\n            _libssh2_error(session, LIBSSH2_ERROR_ALLOC,\n                           "Unable to allocate memory for setenv packet");\n            return LIBSSH2_ERROR_ALLOC;\n        }\n\n        *(s++) = SSH_MSG_GLOBAL_REQUEST;\n        _libssh2_store_str(&s, "cancel-tcpip-forward",\n                           sizeof("cancel-tcpip-forward") - 1);\n        *(s++) = 0x00;          /* want_reply */\n\n        _libssh2_store_str(&s, listener->host, host_len);\n        _libssh2_store_u32(&s, listener->port);'

    new_cancel_body = """    if(listener->chanFwdCncl_state == libssh2_NB_state_idle) {
        if(listener->is_streamlocal) {
            static const char cancel_sl[] =
                "cancel-streamlocal-forward@openssh.com";
            size_t path_len = strlen(listener->streamlocal_path);
            packet_len = 1 + 4 + (sizeof(cancel_sl) - 1) + 1 + 4 + path_len;
            _libssh2_debug((session, LIBSSH2_TRACE_CONN,
                            "Cancelling streamlocal-forward for %s",
                            listener->streamlocal_path));
            s = packet = LIBSSH2_ALLOC(session, packet_len);
            if(!packet) {
                _libssh2_error(session, LIBSSH2_ERROR_ALLOC,
                               "Unable to allocate cancel-streamlocal packet");
                return LIBSSH2_ERROR_ALLOC;
            }
            *(s++) = SSH_MSG_GLOBAL_REQUEST;
            _libssh2_store_str(&s, cancel_sl, sizeof(cancel_sl) - 1);
            *(s++) = 0x00;
            _libssh2_store_str(&s, listener->streamlocal_path, path_len);
        }
        else {
            _libssh2_debug((session, LIBSSH2_TRACE_CONN,
                            "Cancelling tcpip-forward session for %s:%d",
                            listener->host, listener->port));
            s = packet = LIBSSH2_ALLOC(session, packet_len);
            if(!packet) {
                _libssh2_error(session, LIBSSH2_ERROR_ALLOC,
                               "Unable to allocate cancel-tcpip-forward");
                return LIBSSH2_ERROR_ALLOC;
            }
            *(s++) = SSH_MSG_GLOBAL_REQUEST;
            _libssh2_store_str(&s, "cancel-tcpip-forward",
                               sizeof("cancel-tcpip-forward") - 1);
            *(s++) = 0x00;
            _libssh2_store_str(&s, listener->host, host_len);
            _libssh2_store_u32(&s, listener->port);
        }"""

    if old_cancel_body in content:
        content = content.replace(old_cancel_body, new_cancel_body)
        print("Updated _libssh2_channel_forward_cancel for streamlocal")
    else:
        print("WARNING: Could not find forward_cancel body to patch")

    # Update free to handle streamlocal_path
    old_free = "    LIBSSH2_FREE(session, listener->host);\n\n    /* remove this entry from the parent's list of listeners */"
    new_free = """    if(listener->is_streamlocal && listener->streamlocal_path &&
       listener->streamlocal_path != listener->host) {
        LIBSSH2_FREE(session, listener->streamlocal_path);
    }
    LIBSSH2_FREE(session, listener->host);

    /* remove this entry from the parent's list of listeners */"""
    if old_free in content:
        content = content.replace(old_free, new_free)
        print("Updated listener free for streamlocal")

    with open(path, "w") as f:
        f.write(content)
    print("Patched src/channel.c")
PATCH_CHANNEL

# --- 4. Patch src/packet.c: handle forwarded-streamlocal@openssh.com channel type ---
python3 <<'PATCH_PACKET'
import re

path = "src/packet.c"
with open(path, "r") as f:
    content = f.read()

if "forwarded-streamlocal@openssh.com" in content:
    print("packet.c already patched for streamlocal")
else:
    # Add the streamlocal queue function after the existing packet_queue_listener
    # Find the end of packet_queue_listener function
    streamlocal_handler = r'''
/*
 * packet_queue_streamlocal_listener
 *
 * Queue a forwarded-streamlocal@openssh.com connection for a listener.
 */
static inline int
packet_queue_streamlocal_listener(LIBSSH2_SESSION *session,
                                  unsigned char *data, size_t datalen,
                                  packet_queue_streamlocal_state_t *sl_state)
{
    size_t packet_len = 17 + strlen(FwdStreamlocalNotReq);
    unsigned char *p;
    LIBSSH2_LISTENER *listn = _libssh2_list_first(&session->listeners);
    char failure_code = SSH_OPEN_ADMINISTRATIVELY_PROHIBITED;
    int rc;
    static const char chan_type[] = "forwarded-streamlocal@openssh.com";

    if(sl_state->state == libssh2_NB_state_idle) {
        size_t offset = (sizeof(chan_type) - 1) + 5;
        size_t temp_len = 0;
        struct string_buf buf;
        buf.data = data;
        buf.dataptr = buf.data;
        buf.len = datalen;

        if(datalen < offset) {
            return _libssh2_error(session, LIBSSH2_ERROR_OUT_OF_BOUNDARY,
                                  "Unexpected packet size");
        }

        buf.dataptr += offset;

        if(_libssh2_get_u32(&buf, &(sl_state->sender_channel))) {
            return _libssh2_error(session, LIBSSH2_ERROR_BUFFER_TOO_SMALL,
                                  "Data too short extracting channel");
        }
        if(_libssh2_get_u32(&buf, &(sl_state->initial_window_size))) {
            return _libssh2_error(session, LIBSSH2_ERROR_BUFFER_TOO_SMALL,
                                  "Data too short extracting window size");
        }
        if(_libssh2_get_u32(&buf, &(sl_state->packet_size))) {
            return _libssh2_error(session, LIBSSH2_ERROR_BUFFER_TOO_SMALL,
                                  "Data too short extracting packet size");
        }
        if(_libssh2_get_string(&buf, &(sl_state->socket_path), &temp_len)) {
            return _libssh2_error(session, LIBSSH2_ERROR_BUFFER_TOO_SMALL,
                                  "Data too short extracting socket path");
        }
        sl_state->socket_path_len = (uint32_t)temp_len;

        _libssh2_debug((session, LIBSSH2_TRACE_CONN,
                        "Forwarded streamlocal connection for %.*s",
                        sl_state->socket_path_len, sl_state->socket_path));

        sl_state->state = libssh2_NB_state_allocated;
    }

    if(sl_state->state != libssh2_NB_state_sent) {
        while(listn) {
            if(listn->is_streamlocal && listn->streamlocal_path &&
               (strlen(listn->streamlocal_path) ==
                sl_state->socket_path_len) &&
               (memcmp(listn->streamlocal_path, sl_state->socket_path,
                       sl_state->socket_path_len) == 0)) {
                LIBSSH2_CHANNEL *channel = NULL;
                sl_state->channel = NULL;

                if(sl_state->state == libssh2_NB_state_allocated) {
                    if(listn->queue_maxsize &&
                       (listn->queue_maxsize <= listn->queue_size)) {
                        failure_code = SSH_OPEN_RESOURCE_SHORTAGE;
                        sl_state->state = libssh2_NB_state_sent;
                        break;
                    }
                    channel =
                        LIBSSH2_CALLOC(session, sizeof(LIBSSH2_CHANNEL));
                    if(!channel) {
                        _libssh2_error(session, LIBSSH2_ERROR_ALLOC,
                                       "Unable to allocate channel for "
                                       "streamlocal connection");
                        failure_code = SSH_OPEN_RESOURCE_SHORTAGE;
                        sl_state->state = libssh2_NB_state_sent;
                        break;
                    }
                    sl_state->channel = channel;
                    channel->session = session;
                    channel->channel_type_len = sizeof(chan_type) - 1;
                    channel->channel_type =
                        LIBSSH2_ALLOC(session,
                                      channel->channel_type_len + 1);
                    if(!channel->channel_type) {
                        LIBSSH2_FREE(session, channel);
                        failure_code = SSH_OPEN_RESOURCE_SHORTAGE;
                        sl_state->state = libssh2_NB_state_sent;
                        break;
                    }
                    memcpy(channel->channel_type, chan_type,
                           channel->channel_type_len + 1);

                    channel->remote.id = sl_state->sender_channel;
                    channel->remote.window_size_initial =
                        LIBSSH2_CHANNEL_WINDOW_DEFAULT;
                    channel->remote.window_size =
                        LIBSSH2_CHANNEL_WINDOW_DEFAULT;
                    channel->remote.packet_size =
                        LIBSSH2_CHANNEL_PACKET_DEFAULT;
                    channel->local.id = _libssh2_channel_nextid(session);
                    channel->local.window_size_initial =
                        sl_state->initial_window_size;
                    channel->local.window_size =
                        sl_state->initial_window_size;
                    channel->local.packet_size = sl_state->packet_size;

                    p = sl_state->packet;
                    *(p++) = SSH_MSG_CHANNEL_OPEN_CONFIRMATION;
                    _libssh2_store_u32(&p, channel->remote.id);
                    _libssh2_store_u32(&p, channel->local.id);
                    _libssh2_store_u32(&p,
                                       channel->remote.window_size_initial);
                    _libssh2_store_u32(&p, channel->remote.packet_size);

                    sl_state->state = libssh2_NB_state_created;
                }

                if(sl_state->state == libssh2_NB_state_created) {
                    rc = _libssh2_transport_send(session, sl_state->packet,
                                                 17, NULL, 0);
                    if(rc == LIBSSH2_ERROR_EAGAIN)
                        return rc;
                    else if(rc) {
                        sl_state->state = libssh2_NB_state_idle;
                        return _libssh2_error(session, rc,
                                              "Unable to send channel "
                                              "open confirmation");
                    }
                    if(sl_state->channel) {
                        _libssh2_list_add(&listn->queue,
                                          &sl_state->channel->node);
                        listn->queue_size++;
                    }
                    sl_state->state = libssh2_NB_state_idle;
                    return 0;
                }
            }
            listn = _libssh2_list_next(&listn->node);
        }
        sl_state->state = libssh2_NB_state_sent;
    }

    p = sl_state->packet;
    *(p++) = SSH_MSG_CHANNEL_OPEN_FAILURE;
    _libssh2_store_u32(&p, sl_state->sender_channel);
    _libssh2_store_u32(&p, failure_code);
    _libssh2_store_str(&p, FwdStreamlocalNotReq,
                       strlen(FwdStreamlocalNotReq));
    _libssh2_htonu32(p, 0);

    rc = _libssh2_transport_send(session, sl_state->packet,
                                 packet_len, NULL, 0);
    if(rc == LIBSSH2_ERROR_EAGAIN)
        return rc;
    else if(rc) {
        sl_state->state = libssh2_NB_state_idle;
        return _libssh2_error(session, rc,
                              "Unable to send open failure");
    }
    sl_state->state = libssh2_NB_state_idle;
    return 0;
}

'''
    # Insert after packet_queue_listener function.
    # Find the function start of packet_x11_open (which comes after packet_queue_listener)
    x11_marker = '/*\n * packet_x11_open'
    if x11_marker in content:
        content = content.replace(x11_marker, streamlocal_handler + x11_marker)
        print("Added packet_queue_streamlocal_listener()")
    else:
        print("WARNING: Could not find x11 marker in packet.c")

    # Add forwarded-streamlocal@openssh.com dispatch in SSH_MSG_CHANNEL_OPEN handler
    # Find the x11 check that comes after forwarded-tcpip (12-space indent, 21-space continuation)
    old_x11 = '            else if((datalen >= (strlen("x11") + 5)) &&\n                     ((strlen("x11")) == _libssh2_ntohu32(data + 1)) &&\n                     (memcmp(data + 5, "x11", strlen("x11")) == 0)) {'

    new_dispatch = '            else if((datalen >=\n                     (sizeof("forwarded-streamlocal@openssh.com") - 1 + 5)) &&\n                    ((sizeof("forwarded-streamlocal@openssh.com") - 1) ==\n                     _libssh2_ntohu32(data + 1)) &&\n                    (memcmp(data + 5, "forwarded-streamlocal@openssh.com",\n                            sizeof("forwarded-streamlocal@openssh.com") - 1)\n                     == 0)) {\n\n                memset(&session->packAdd_Qstreamlocal_state, 0,\n                       sizeof(session->packAdd_Qstreamlocal_state));\n\nlibssh2_packet_add_jump_streamlocal:\n                session->packAdd_state = libssh2_NB_state_jump_streamlocal;\n                rc = packet_queue_streamlocal_listener(\n                    session, data, datalen,\n                    &session->packAdd_Qstreamlocal_state);\n            }\n            else if((datalen >= (strlen("x11") + 5)) &&\n                     ((strlen("x11")) == _libssh2_ntohu32(data + 1)) &&\n                     (memcmp(data + 5, "x11", strlen("x11")) == 0)) {'

    if old_x11 in content:
        content = content.replace(old_x11, new_dispatch)
        print("Added forwarded-streamlocal@openssh.com dispatch")
    else:
        print("WARNING: Could not find x11 dispatch in CHANNEL_OPEN handler")

    # Add EAGAIN re-entry case to the switch at the top of _libssh2_packet_add.
    # The goto target is the label inside the dispatch block above.
    # (4-space indent for case, 8-space for goto -- matching actual libssh2 style)
    old_jump_dispatch = "    case libssh2_NB_state_jump3:\n        goto libssh2_packet_add_jump_point3;"
    new_jump_dispatch = "    case libssh2_NB_state_jump_streamlocal:\n        goto libssh2_packet_add_jump_streamlocal;\n    case libssh2_NB_state_jump3:\n        goto libssh2_packet_add_jump_point3;"
    if old_jump_dispatch in content:
        content = content.replace(old_jump_dispatch, new_jump_dispatch)
        print("Added jump_streamlocal dispatch for EAGAIN")
    else:
        print("WARNING: Could not find jump3 dispatch")

    with open(path, "w") as f:
        f.write(content)
    print("Patched src/packet.c")
PATCH_PACKET

echo "✓ libssh2 streamlocal patch applied"
