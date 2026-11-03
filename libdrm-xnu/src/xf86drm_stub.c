/*
 * libdrm-xnu: stub implementation of the subset of libdrm used by Mesa's
 * panfrost gallium driver, panfrost/panthor kmod and gallium renderonly.
 *
 * Every entry point currently fails with ENOSYS (errno set, -ENOSYS returned)
 * or returns NULL. They are to be implemented on top of the XNU/IOKit Mali
 * kernel interface. The symbol list is in ../SYMBOLS.txt (regenerate with
 * ../collect-symbols.sh after rebuilding Mesa).
 *
 * SPDX-License-Identifier: MIT
 */
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>

#include "xf86drm.h"

#define DRM_XNU_ENOSYS() do { errno = ENOSYS; return -ENOSYS; } while (0)

/* ---- generic ioctl / device ------------------------------------------- */

int drmIoctl(int fd, unsigned long request, void *arg)
{
   (void)fd; (void)request; (void)arg;
   DRM_XNU_ENOSYS();
}

drmVersionPtr drmGetVersion(int fd)
{
   (void)fd;
   errno = ENOSYS;
   return NULL;
}

void drmFreeVersion(drmVersionPtr v)
{
   if (!v)
      return;
   free(v->name);
   free(v->date);
   free(v->desc);
   free(v);
}

/* ---- GEM handles / PRIME ---------------------------------------------- */

int drmCloseBufferHandle(int fd, uint32_t handle)
{
   (void)fd; (void)handle;
   DRM_XNU_ENOSYS();
}

int drmPrimeHandleToFD(int fd, uint32_t handle, uint32_t flags, int *prime_fd)
{
   (void)fd; (void)handle; (void)flags;
   if (prime_fd)
      *prime_fd = -1;
   DRM_XNU_ENOSYS();
}

int drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle)
{
   (void)fd; (void)prime_fd;
   if (handle)
      *handle = 0;
   DRM_XNU_ENOSYS();
}

/* ---- syncobj ---------------------------------------------------------- */

int drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle)
{
   (void)fd; (void)flags;
   if (handle)
      *handle = 0;
   DRM_XNU_ENOSYS();
}

int drmSyncobjDestroy(int fd, uint32_t handle)
{
   (void)fd; (void)handle;
   DRM_XNU_ENOSYS();
}

int drmSyncobjFDToHandle(int fd, int obj_fd, uint32_t *handle)
{
   (void)fd; (void)obj_fd;
   if (handle)
      *handle = 0;
   DRM_XNU_ENOSYS();
}

int drmSyncobjImportSyncFile(int fd, uint32_t handle, int sync_file_fd)
{
   (void)fd; (void)handle; (void)sync_file_fd;
   DRM_XNU_ENOSYS();
}

int drmSyncobjExportSyncFile(int fd, uint32_t handle, int *sync_file_fd)
{
   (void)fd; (void)handle;
   if (sync_file_fd)
      *sync_file_fd = -1;
   DRM_XNU_ENOSYS();
}

int drmSyncobjReset(int fd, const uint32_t *handles, uint32_t handle_count)
{
   (void)fd; (void)handles; (void)handle_count;
   DRM_XNU_ENOSYS();
}

int drmSyncobjWait(int fd, uint32_t *handles, unsigned num_handles,
                   int64_t timeout_nsec, unsigned flags,
                   uint32_t *first_signaled)
{
   (void)fd; (void)handles; (void)num_handles; (void)timeout_nsec;
   (void)flags; (void)first_signaled;
   DRM_XNU_ENOSYS();
}

int drmSyncobjTimelineWait(int fd, uint32_t *handles, uint64_t *points,
                           unsigned num_handles, int64_t timeout_nsec,
                           unsigned flags, uint32_t *first_signaled)
{
   (void)fd; (void)handles; (void)points; (void)num_handles;
   (void)timeout_nsec; (void)flags; (void)first_signaled;
   DRM_XNU_ENOSYS();
}

int drmSyncobjTransfer(int fd, uint32_t dst_handle, uint64_t dst_point,
                       uint32_t src_handle, uint64_t src_point,
                       uint32_t flags)
{
   (void)fd; (void)dst_handle; (void)dst_point; (void)src_handle;
   (void)src_point; (void)flags;
   DRM_XNU_ENOSYS();
}
