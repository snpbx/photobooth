#include "gphoto_shim.h"
#include <gphoto2/gphoto2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

int gpshim_connect(void) {
    if (g_cam) return 0;
    g_ctx = gp_context_new();
    if (gp_camera_new(&g_cam) < GP_OK) {
        g_cam = NULL;
        snprintf(g_err, sizeof(g_err), "camera_new failed");
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

int gpshim_capture(unsigned char **out, unsigned long *len) {
    *out = NULL; *len = 0;
    if (!g_cam) { snprintf(g_err, sizeof(g_err), "not connected"); return -1; }

    CameraFilePath path;
    int r = gp_camera_capture(g_cam, GP_CAPTURE_IMAGE, &path, g_ctx);
    if (r < GP_OK) { set_err("capture", r); return r; }

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
