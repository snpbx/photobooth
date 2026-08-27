#ifndef GPHOTO_SHIM_H
#define GPHOTO_SHIM_H

// Thin C wrapper around libgphoto2 for the Photobooth app.
// Buffers returned via `out` are malloc'd and must be released with gpshim_free().

// Enumerate attached PTP cameras without initialising them.
// Writes newline-separated "model\tport" rows into `out`. Returns count (>=0) or <0 on error.
int  gpshim_detect_summary(char *out, int cap);

int  gpshim_connect(void);                                           // 0 = ok, <0 = gphoto error
int  gpshim_liveview_frame(unsigned char **out, unsigned long *len);  // JPEG live-view frame
int  gpshim_capture(unsigned char **out, unsigned long *len);         // full-resolution JPEG
int  gpshim_delete_last(void);       // remove the last capture from the card (call after it is safely on disk)
void gpshim_free(unsigned char *p);
void gpshim_disconnect(void);
int  gpshim_is_connected(void);
const char *gpshim_last_error(void);
const char *gpshim_camera_name(void);

#endif
