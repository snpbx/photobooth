#include "gphoto_shim.h"
#include <gphoto2/gphoto2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static Camera     *g_cam = NULL;
static GPContext  *g_ctx = NULL;
static char        g_err[256]  = "";
static char        g_name[128] = "";
static CameraFilePath g_last_path;
static int         g_has_last = 0;

static void set_err(const char *what, int code) {
    snprintf(g_err, sizeof(g_err), "%s: %s", what, gp_result_as_string(code));
}

int gpshim_is_connected(void) { return g_cam != NULL; }
const char *gpshim_last_error(void) { return g_err; }
const char *gpshim_camera_name(void) { return g_name; }
void gpshim_free(unsigned char *p) { if (p) free(p); }

// Not every PTP device on the bus is a camera.
//
// This booth runs its guest screen on an iPad over USB, and an iPad answers
// PTP well enough that libgphoto2 lists it, lets us open it, and then refuses
// every preview and every capture with "Unsupported operation" — so the booth
// sat there connected to a tablet, reporting a camera that could not take a
// photograph. Apple's own devices are never the booth camera, so they are kept
// out of both the list and the choice of what to open.
static int is_not_a_camera(const char *model) {
    if (!model) return 1;
    static const char *skip[] = { "Apple", "iPad", "iPhone", "iPod", NULL };
    for (int i = 0; skip[i]; i++) {
        if (strcasestr(model, skip[i])) return 1;
    }
    return 0;
}

int gpshim_detect_summary(char *out, int cap) {
    if (cap > 0) out[0] = '\0';
    GPContext *ctx = gp_context_new();
    CameraList *list = NULL;
    if (gp_list_new(&list) < GP_OK) { gp_context_unref(ctx); return -1; }

    int n = gp_camera_autodetect(list, ctx);
    if (n < GP_OK) { gp_list_free(list); gp_context_unref(ctx); return n; }

    int used = 0, count = 0;
    for (int i = 0; i < n; i++) {
        const char *model = NULL, *port = NULL;
        gp_list_get_name(list, i, &model);
        gp_list_get_value(list, i, &port);
        if (is_not_a_camera(model)) continue;
        int wrote = snprintf(out + used, (size_t)(cap - used), "%s\t%s\n",
                             model ? model : "", port ? port : "");
        if (wrote < 0 || wrote >= cap - used) break;
        used += wrote;
        count++;
    }
    gp_list_free(list);
    gp_context_unref(ctx);
    return count;
}

/// Points the camera at one specific model on one specific port.
///
/// Without this, gp_camera_init opens whatever the bus offers first, which on
/// this booth is the iPad. Returns 0, or <0 with the reason in g_err.
static int bind_to(Camera *cam, GPContext *ctx, const char *model, const char *port) {
    CameraAbilitiesList *abilities = NULL;
    GPPortInfoList *ports = NULL;
    int rc = -1;

    if (gp_abilities_list_new(&abilities) < GP_OK) goto done;
    if (gp_abilities_list_load(abilities, ctx) < GP_OK) goto done;
    int m = gp_abilities_list_lookup_model(abilities, model);
    if (m < GP_OK) { snprintf(g_err, sizeof(g_err), "unknown model %s", model); goto done; }
    CameraAbilities a;
    if (gp_abilities_list_get_abilities(abilities, m, &a) < GP_OK) goto done;
    if (gp_camera_set_abilities(cam, a) < GP_OK) goto done;

    if (gp_port_info_list_new(&ports) < GP_OK) goto done;
    if (gp_port_info_list_load(ports) < GP_OK) goto done;
    int p = gp_port_info_list_lookup_path(ports, port);
    if (p < GP_OK) { snprintf(g_err, sizeof(g_err), "no port %s", port); goto done; }
    GPPortInfo info;
    if (gp_port_info_list_get_info(ports, p, &info) < GP_OK) goto done;
    if (gp_camera_set_port_info(cam, info) < GP_OK) goto done;
    rc = 0;

done:
    if (ports) gp_port_info_list_free(ports);
    if (abilities) gp_abilities_list_free(abilities);
    return rc;
}

int gpshim_connect(void) {
    if (g_cam) return 0;
    g_ctx = gp_context_new();
    if (gp_camera_new(&g_cam) < GP_OK) {
        g_cam = NULL;
        snprintf(g_err, sizeof(g_err), "camera_new failed");
        return -1;
    }

    // Pick the first real camera on the bus rather than the first PTP device.
    // If nothing on the bus qualifies, say so plainly instead of opening a
    // tablet and failing at the first shutter press.
    int bound = 0, ptp_devices = 0;
    CameraList *list = NULL;
    if (gp_list_new(&list) >= GP_OK) {
        int n = gp_camera_autodetect(list, g_ctx);
        for (int i = 0; i < n; i++) {
            const char *model = NULL, *port = NULL;
            gp_list_get_name(list, i, &model);
            gp_list_get_value(list, i, &port);
            ptp_devices++;
            if (is_not_a_camera(model)) continue;
            if (bind_to(g_cam, g_ctx, model, port) == 0) { bound = 1; break; }
        }
        gp_list_free(list);
    }
    if (!bound && ptp_devices > 0) {
        snprintf(g_err, sizeof(g_err),
                 "No camera on USB — the only devices found are not cameras.");
        gp_camera_free(g_cam); g_cam = NULL;
        gp_context_unref(g_ctx); g_ctx = NULL;
        return -1;
    }

    int r = gp_camera_init(g_cam, g_ctx);
    if (r < GP_OK) {
        set_err("init", r);
        gp_camera_free(g_cam); g_cam = NULL;
        gp_context_unref(g_ctx); g_ctx = NULL;
        return r;
    }
    CameraAbilities ab;
    if (gp_camera_get_abilities(g_cam, &ab) == GP_OK) {
        snprintf(g_name, sizeof(g_name), "%s", ab.model);
    } else {
        snprintf(g_name, sizeof(g_name), "DSLR");
    }
    g_err[0] = '\0';
    g_has_last = 0;
    return 0;
}

int gpshim_liveview_frame(unsigned char **out, unsigned long *len) {
    *out = NULL; *len = 0;
    if (!g_cam) { snprintf(g_err, sizeof(g_err), "not connected"); return -1; }
    CameraFile *file;
    if (gp_file_new(&file) < GP_OK) { snprintf(g_err, sizeof(g_err), "file_new failed"); return -1; }

    int r = gp_camera_capture_preview(g_cam, file, g_ctx);
    if (r < GP_OK) { set_err("preview", r); gp_file_free(file); return r; }

    const char *data; unsigned long size;
    r = gp_file_get_data_and_size(file, &data, &size);
    if (r < GP_OK) { set_err("get_data", r); gp_file_free(file); return r; }

    unsigned char *buf = (unsigned char *)malloc(size ? size : 1);
    if (!buf) { gp_file_free(file); snprintf(g_err, sizeof(g_err), "oom"); return -1; }
    memcpy(buf, data, size);
    *out = buf; *len = size;
    gp_file_free(file);
    return 0;
}

// MARK: - Taking a photograph
//
// A Canon EOS refuses the shutter in more ways than one, and the driver reports
// most of them as the same thing: "Unspecified error". Three defences, in the
// order they matter.

/// Flips a camera setting that may or may not exist on this body. Returns 0
/// when it was there and took the value.
static int set_flag(const char *name, int value) {
    CameraWidget *w = NULL;
    if (gp_camera_get_single_config(g_cam, name, &w, g_ctx) != GP_OK || !w) return -1;
    CameraWidgetType type;
    gp_widget_get_type(w, &type);
    int r;
    if (type == GP_WIDGET_TOGGLE) {
        r = gp_widget_set_value(w, &value);
    } else {
        const char *text = value ? "1" : "0";
        r = gp_widget_set_value(w, text);
    }
    if (r == GP_OK) r = gp_camera_set_single_config(g_cam, name, w, g_ctx);
    gp_widget_free(w);
    return r == GP_OK ? 0 : -1;
}

/// Reads a setting as text, for saying something useful when the shutter is
/// refused — "the dial is on Auto" is the answer nine times in ten.
static void read_flag(const char *name, char *out, size_t cap) {
    if (cap) out[0] = '\0';
    CameraWidget *w = NULL;
    if (gp_camera_get_single_config(g_cam, name, &w, g_ctx) != GP_OK || !w) return;
    const char *value = NULL;
    CameraWidgetType type;
    gp_widget_get_type(w, &type);
    if ((type == GP_WIDGET_RADIO || type == GP_WIDGET_MENU || type == GP_WIDGET_TEXT)
        && gp_widget_get_value(w, &value) == GP_OK && value) {
        snprintf(out, cap, "%s", value);
    }
    gp_widget_free(w);
}

/// Clears events the camera has been sitting on. A session that failed halfway
/// leaves them queued, and the next capture is answered with one of those.
static void drain_events(int ms) {
    CameraEventType type = GP_EVENT_UNKNOWN;
    void *data = NULL;
    int waited = 0;
    while (waited < ms) {
        if (gp_camera_wait_for_event(g_cam, 50, &type, &data, g_ctx) < GP_OK) break;
        free(data); data = NULL;
        waited += 50;
        if (type == GP_EVENT_TIMEOUT) break;
    }
    free(data);
}

/// The other way to take a photograph: ask the body to fire, then wait for it
/// to announce the file. Canon bodies that refuse `gp_camera_capture` outright
/// will very often do this instead, because it does not wait on the same
/// autofocus confirmation.
static int trigger_and_wait(CameraFilePath *path, int timeout_ms) {
    int r = gp_camera_trigger_capture(g_cam, g_ctx);
    if (r < GP_OK) return r;

    int waited = 0;
    while (waited < timeout_ms) {
        CameraEventType type = GP_EVENT_UNKNOWN;
        void *data = NULL;
        r = gp_camera_wait_for_event(g_cam, 400, &type, &data, g_ctx);
        waited += 400;
        if (r < GP_OK) { free(data); return r; }
        if (type == GP_EVENT_FILE_ADDED && data) {
            *path = *(CameraFilePath *)data;
            free(data);
            return GP_OK;
        }
        free(data);
    }
    return GP_ERROR_TIMEOUT;
}

int gpshim_capture(unsigned char **out, unsigned long *len) {
    *out = NULL; *len = 0;
    if (!g_cam) { snprintf(g_err, sizeof(g_err), "not connected"); return -1; }

    // Live view down for the duration. An EOS with the mirror up for the
    // preview will not release the shutter, which is most of what the booth
    // was seeing: connect fine, preview fine, every capture refused.
    int viewfinder_was_on = (set_flag("viewfinder", 0) == 0);
    drain_events(150);

    CameraFilePath path;
    int r = gp_camera_capture(g_cam, GP_CAPTURE_IMAGE, &path, g_ctx);
    if (r < GP_OK) {
        // Give the body a moment to finish whatever it was doing, then ask the
        // other way round before giving up on the shot.
        usleep(400 * 1000);
        r = trigger_and_wait(&path, 8000);
    }
    if (viewfinder_was_on) set_flag("viewfinder", 1);

    if (r < GP_OK) {
        char mode[64];
        read_flag("autoexposuremode", mode, sizeof(mode));
        if (mode[0]) {
            snprintf(g_err, sizeof(g_err), "capture: %s (mode dial: %s)",
                     gp_result_as_string(r), mode);
        } else {
            set_err("capture", r);
        }
        return r;
    }

    CameraFile *file;
    if (gp_file_new(&file) < GP_OK) { snprintf(g_err, sizeof(g_err), "file_new failed"); return -1; }
    r = gp_camera_file_get(g_cam, path.folder, path.name, GP_FILE_TYPE_NORMAL, file, g_ctx);
    if (r < GP_OK) { set_err("file_get", r); gp_file_free(file); return r; }

    const char *data; unsigned long size;
    r = gp_file_get_data_and_size(file, &data, &size);
    if (r < GP_OK) { set_err("get_data", r); gp_file_free(file); return r; }

    unsigned char *buf = (unsigned char *)malloc(size ? size : 1);
    if (!buf) { gp_file_free(file); snprintf(g_err, sizeof(g_err), "oom"); return -1; }
    memcpy(buf, data, size);
    *out = buf; *len = size;
    gp_file_free(file);

    // Card cleanup is deferred until the caller has written the JPEG to disk.
    g_last_path = path;
    g_has_last  = 1;
    return 0;
}

// MARK: - Camera settings
//
// One widget at a time through gp_camera_{get,set}_single_config: on a Canon
// the whole-config round trip is slow enough to be felt between shots, and
// writing back a config tree read minutes ago would push stale values the
// operator had since changed on the body itself.

static void append_choices(CameraWidget *w, char *out, int cap, int *used) {
    int n = gp_widget_count_choices(w);
    for (int i = 0; i < n; i++) {
        const char *ch = NULL;
        if (gp_widget_get_choice(w, i, &ch) < GP_OK || !ch) continue;
        int wrote = snprintf(out + *used, (size_t)(cap - *used), "%s%s", i ? "|" : "", ch);
        if (wrote < 0 || wrote >= cap - *used) return;
        *used += wrote;
    }
}

/// The widget's current value as text, whatever its type. Returns 0 on success.
static int widget_value(CameraWidget *w, CameraWidgetType type, char *buf, size_t cap) {
    if (type == GP_WIDGET_TOGGLE) {
        int v = 0;
        if (gp_widget_get_value(w, &v) < GP_OK) return -1;
        snprintf(buf, cap, "%s", v ? "1" : "0");
        return 0;
    }
    if (type == GP_WIDGET_RANGE) {
        float v = 0;
        if (gp_widget_get_value(w, &v) < GP_OK) return -1;
        snprintf(buf, cap, "%g", v);
        return 0;
    }
    const char *s = NULL;
    if (gp_widget_get_value(w, &s) < GP_OK) return -1;
    snprintf(buf, cap, "%s", s ? s : "");
    return 0;
}

int gpshim_config_read(const char *names, char *out, int cap) {
    if (cap > 0) out[0] = '\0';
    if (!g_cam) { snprintf(g_err, sizeof(g_err), "not connected"); return -1; }
    if (!names || cap <= 1) return 0;

    int used = 0, rows = 0;
    const char *p = names;
    while (*p) {
        const char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        char name[64];
        if (len > 0 && len < sizeof(name)) {
            memcpy(name, p, len);
            name[len] = '\0';

            CameraWidget *w = NULL;
            if (gp_camera_get_single_config(g_cam, name, &w, g_ctx) == GP_OK && w) {
                CameraWidgetType type;
                const char *label = NULL;
                int readonly = 0;
                char value[128] = "";
                gp_widget_get_type(w, &type);
                gp_widget_get_label(w, &label);
                gp_widget_get_readonly(w, &readonly);

                if (widget_value(w, type, value, sizeof(value)) == 0) {
                    int wrote = snprintf(out + used, (size_t)(cap - used), "%s\t%s\t%s\t%d\t",
                                         name, label ? label : name, value, readonly ? 1 : 0);
                    if (wrote > 0 && wrote < cap - used) {
                        used += wrote;
                        if (type == GP_WIDGET_RADIO || type == GP_WIDGET_MENU) {
                            append_choices(w, out, cap, &used);
                        }
                        if (used < cap - 1) { out[used++] = '\n'; out[used] = '\0'; rows++; }
                    } else {
                        out[used] = '\0';   // no room — stop cleanly rather than truncate a row
                        gp_widget_free(w);
                        break;
                    }
                }
                gp_widget_free(w);
            }
        }
        if (!nl) break;
        p = nl + 1;
    }
    g_err[0] = '\0';
    return rows;
}

int gpshim_config_write(const char *name, const char *value) {
    if (!g_cam) { snprintf(g_err, sizeof(g_err), "not connected"); return -1; }
    if (!name || !value) { snprintf(g_err, sizeof(g_err), "no setting given"); return -1; }

    CameraWidget *w = NULL;
    int r = gp_camera_get_single_config(g_cam, name, &w, g_ctx);
    if (r < GP_OK || !w) { set_err("get_config", r < GP_OK ? r : GP_ERROR); return -1; }

    CameraWidgetType type;
    gp_widget_get_type(w, &type);

    int readonly = 0;
    gp_widget_get_readonly(w, &readonly);
    if (readonly) {
        snprintf(g_err, sizeof(g_err), "the camera will not let this be set from here");
        gp_widget_free(w);
        return -1;
    }

    if (type == GP_WIDGET_TOGGLE) {
        int v = (value[0] == '1');
        r = gp_widget_set_value(w, &v);
    } else if (type == GP_WIDGET_RANGE) {
        float v = (float)atof(value);
        r = gp_widget_set_value(w, &v);
    } else {
        r = gp_widget_set_value(w, value);
    }
    if (r < GP_OK) { set_err("set_value", r); gp_widget_free(w); return -1; }

    r = gp_camera_set_single_config(g_cam, name, w, g_ctx);
    gp_widget_free(w);
    if (r < GP_OK) { set_err("set_config", r); return -1; }
    g_err[0] = '\0';
    return 0;
}

int gpshim_delete_last(void) {
    if (!g_cam || !g_has_last) return -1;
    int r = gp_camera_file_delete(g_cam, g_last_path.folder, g_last_path.name, g_ctx);
    g_has_last = 0;
    if (r < GP_OK) { set_err("delete", r); return r; }
    return 0;
}

void gpshim_disconnect(void) {
    if (g_cam) { gp_camera_exit(g_cam, g_ctx); gp_camera_free(g_cam); g_cam = NULL; }
    if (g_ctx) { gp_context_unref(g_ctx); g_ctx = NULL; }
    g_name[0] = '\0';
    g_has_last = 0;
}
