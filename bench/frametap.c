// frametap: passive Wayland frame-callback logger.
// Opens a small window, commits one buffer, then sits idle (so the compositor can idle too).
// SIGUSR1 starts a frame-callback loop, SIGUSR2 stops it; each callback is logged as
// CLOCK_MONOTONIC microseconds. Intervals between lines are the compositor's repaint cadence;
// a gap > 1 vsync during an animation is a dropped frame. (A commit with no damage still makes
// niri repaint every frame, so the loop must not run while measuring idle.)
// Build: make  (needs wayland-client + wayland-scanner + wayland-protocols' xdg-shell.xml).
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <sys/mman.h>
#include <poll.h>
#include <fcntl.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

static struct wl_compositor *comp; static struct wl_shm *shm; static struct xdg_wm_base *wm;
static struct wl_surface *surf; static struct wl_buffer *buf;
static volatile sig_atomic_t quit; static FILE *out; static int configured;

static int sigpipe[2]; static int running;
static void on_sig(int s) { char c = (s == SIGUSR1) ? 'S' : (s == SIGUSR2) ? 'E' : 'Q'; if (write(sigpipe[1], &c, 1) < 0) {} }
static long long now_us(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec*1000000LL + t.tv_nsec/1000; }

static void frame_done(void *d, struct wl_callback *cb, uint32_t t);
static const struct wl_callback_listener frame_l = { frame_done };
static void request_frame(void);
static void request_frame(void) { struct wl_callback *cb = wl_surface_frame(surf); wl_callback_add_listener(cb, &frame_l, NULL); wl_surface_commit(surf); }
static void frame_done(void *d, struct wl_callback *cb, uint32_t t) { (void)d; (void)t; wl_callback_destroy(cb); fprintf(out, "%lld\n", now_us()); fflush(out); if (running) request_frame(); }

static void ping(void *d, struct xdg_wm_base *w, uint32_t s) { (void)d; xdg_wm_base_pong(w, s); }
static const struct xdg_wm_base_listener wm_l = { ping };
static void reg(void *d, struct wl_registry *r, uint32_t n, const char *i, uint32_t v) {
    (void)d; (void)v;
    if (!strcmp(i, "wl_compositor")) comp = wl_registry_bind(r, n, &wl_compositor_interface, 4);
    else if (!strcmp(i, "wl_shm")) shm = wl_registry_bind(r, n, &wl_shm_interface, 1);
    else if (!strcmp(i, "xdg_wm_base")) { wm = wl_registry_bind(r, n, &xdg_wm_base_interface, 1); xdg_wm_base_add_listener(wm, &wm_l, NULL); }
}
static void reg_rm(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener reg_l = { reg, reg_rm };
static void xs_conf(void *d, struct xdg_surface *x, uint32_t s) { (void)d; xdg_surface_ack_configure(x, s);
    if (!configured) { configured = 1; wl_surface_attach(surf, buf, 0, 0); wl_surface_damage_buffer(surf, 0, 0, 64, 64); wl_surface_commit(surf); } }
static const struct xdg_surface_listener xs_l = { xs_conf };
static void tl_conf(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s) { (void)d; (void)t; (void)w; (void)h; (void)s; }
static void tl_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; quit = 1; }
static const struct xdg_toplevel_listener tl_l = { tl_conf, tl_close, NULL, NULL };

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: frametap OUTFILE\n"); return 2; }
    out = fopen(argv[1], "w"); if (!out) { perror("open"); return 1; }
    if (pipe(sigpipe)) return 1; fcntl(sigpipe[0], F_SETFL, O_NONBLOCK);
    signal(SIGTERM, on_sig); signal(SIGINT, on_sig); signal(SIGUSR1, on_sig); signal(SIGUSR2, on_sig);
    struct wl_display *dpy = wl_display_connect(NULL); if (!dpy) { fprintf(stderr, "no wayland\n"); return 1; }
    wl_registry_add_listener(wl_display_get_registry(dpy), &reg_l, NULL); wl_display_roundtrip(dpy);
    if (!comp || !shm || !wm) { fprintf(stderr, "missing globals\n"); return 1; }
    int fd = memfd_create("frametap", 0); ftruncate(fd, 64*64*4);
    uint32_t *px = mmap(NULL, 64*64*4, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    for (int i = 0; i < 64*64; i++) px[i] = 0xff00f5ff;   // aether cyan
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, 64*64*4);
    buf = wl_shm_pool_create_buffer(pool, 0, 64, 64, 64*4, WL_SHM_FORMAT_ARGB8888);
    surf = wl_compositor_create_surface(comp);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm, surf); xdg_surface_add_listener(xs, &xs_l, NULL);
    struct xdg_toplevel *tl = xdg_surface_get_toplevel(xs); xdg_toplevel_add_listener(tl, &tl_l, NULL);
    xdg_toplevel_set_title(tl, "rabble-frametap"); xdg_toplevel_set_app_id(tl, "rabble-frametap");
    wl_surface_commit(surf);
    while (!quit) {
        while (wl_display_prepare_read(dpy) != 0) wl_display_dispatch_pending(dpy);
        wl_display_flush(dpy);
        struct pollfd p[2] = { { wl_display_get_fd(dpy), POLLIN, 0 }, { sigpipe[0], POLLIN, 0 } };
        poll(p, 2, -1);
        if (p[0].revents & POLLIN) wl_display_read_events(dpy); else wl_display_cancel_read(dpy);
        wl_display_dispatch_pending(dpy);
        char c; while (read(sigpipe[0], &c, 1) > 0) {
            if (c == 'S') { running = 1; request_frame(); }
            else if (c == 'E') running = 0;
            else quit = 1;
        }
    }
    fclose(out); return 0;
}
