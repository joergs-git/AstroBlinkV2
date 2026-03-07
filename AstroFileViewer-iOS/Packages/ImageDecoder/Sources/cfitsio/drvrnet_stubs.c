// Stub implementations for network-related cfitsio functions
// AstroTriage only reads local files, no network FITS access needed
#include "fitsio.h"
#include <string.h>

int fits_net_timeout(int timeout) { (void)timeout; return 0; }
int fits_dwnld_prog_bar(int flag) { (void)flag; return 0; }

// FTP stubs
int ftp_checkfile(char *url) { (void)url; return -1; }
int ftp_open(char *url, int *handle) { (void)url; (void)handle; return -1; }
int ftp_file_open(char *url, int *handle) { (void)url; (void)handle; return -1; }
int ftp_compress_open(char *url, int *handle) { (void)url; (void)handle; return -1; }
int ftps_checkfile(char *url) { (void)url; return -1; }
int ftps_open(char *url, int *handle) { (void)url; (void)handle; return -1; }
int ftps_file_open(char *url, int *handle) { (void)url; (void)handle; return -1; }
int ftps_compress_open(char *url, int *handle) { (void)url; (void)handle; return -1; }

// HTTP stubs
int http_checkfile(char *url) { (void)url; return -1; }
int http_open(char *url, int *handle) { (void)url; (void)handle; return -1; }
int http_file_open(char *url, int *handle) { (void)url; (void)handle; return -1; }
int http_compress_open(char *url, int *handle) { (void)url; (void)handle; return -1; }
int https_checkfile(char *url) { (void)url; return -1; }
int https_open(char *url, int *handle) { (void)url; (void)handle; return -1; }
int https_file_open(char *url, int *handle) { (void)url; (void)handle; return -1; }
int https_compress_open(char *url, int *handle) { (void)url; (void)handle; return -1; }

// HTTPS verbose
void https_set_verbose(int flag) { (void)flag; }

// Root driver stubs (full interface required by cfitsio init)
int root_init(void) { return -1; }
int root_open(char *url, int *handle, int rwmode) { (void)url; (void)handle; (void)rwmode; return -1; }
int root_create(char *url, int *handle) { (void)url; (void)handle; return -1; }
int root_close(int handle) { (void)handle; return 0; }
int root_flush(int handle) { (void)handle; return 0; }
int root_read(int handle, void *buf, long nbytes) { (void)handle; (void)buf; (void)nbytes; return -1; }
int root_write(int handle, void *buf, long nbytes) { (void)handle; (void)buf; (void)nbytes; return -1; }
int root_seek(int handle, long offset) { (void)handle; (void)offset; return 0; }
int root_size(int handle, long *size) { (void)handle; (void)size; return -1; }
int root_getoptions(int *options) { if (options) *options = 0; return 0; }
int root_getversion(int *version) { if (version) *version = 0; return 0; }
int root_setoptions(int options) { (void)options; return 0; }
int root_shutdown(void) { return 0; }
