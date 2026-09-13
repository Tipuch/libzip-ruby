#ifndef HAD_CONFIG_H
#define HAD_CONFIG_H
/* zipint.h includes config.h before zip.h, and the integer typedefs it needs
   (zip_int8_t, ...) live in zipconf.h.  Pull it in first, guarded exactly as
   upstream's generated config.h does. */
#ifndef _HAD_ZIPCONF_H
#include "zipconf.h"
#endif
/* Hand-resolved from libzip 1.11.4 config.h.in: common POSIX subset.
   Crypto backends, bzip2/lzma/zstd, and Windows-only features are
   deliberately disabled for the v1 static build. */
#define ENABLE_FDOPEN 1
#define HAVE_FILENO 1
#define HAVE_FCHMOD 1
#define HAVE_FSEEKO 1
#define HAVE_FTELLO 1
#define HAVE_LOCALTIME_R 1
#define HAVE_MKSTEMP 1
#define HAVE_SNPRINTF 1
#define HAVE_STRCASECMP 1
#define HAVE_STRDUP 1
#define HAVE_STRTOLL 1
#define HAVE_STRTOULL 1
#define HAVE_STRUCT_TM_TM_ZONE 1
#define HAVE_STDBOOL_H 1
#define HAVE_STRINGS_H 1
#define HAVE_UNISTD_H 1
#define HAVE_DIRENT_H 1
#define SIZEOF_OFF_T 8
#define SIZEOF_SIZE_T 8
#endif /* HAD_CONFIG_H */
