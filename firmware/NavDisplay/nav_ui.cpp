/*
 * NavDisplay UI (LVGL 8) for a 240 x 240 round panel.
 *   Waiting / Idle / Navigating / Arrived screens.
 *   Navigation: heading-up route view (equirectangular projection around the
 *   current position), fixed position arrow near the bottom centre, top bar with
 *   the next turn, bottom bar with remaining distance, ETA, speed, BLE state.
 */
#include "nav_ui.h"
#include "config.h"
#include <lvgl.h>
#include <math.h>
#include <time.h>

#define COL_BG      0x0B0F14
#define COL_TEXT    0xFFFFFF
#define COL_MUTED   0x8B98A8
#define COL_ROUTE   0x3D8BFD
#define COL_CASING  0x14325E
#define COL_GOLD    0xD4AF37
#define COL_OK      0x3DD68C
#define COL_BAD     0xFF6B6B

#define ARROW_X     120          // my position on screen
#define ARROW_Y     166
#define MAX_VIS     180          // route points drawn per frame

static UiMode     s_mode = UI_WAITING;
static lv_obj_t  *s_wait, *s_idle, *s_nav, *s_arrived;
// waiting / idle
static lv_obj_t  *s_wait_dot, *s_idle_clock, *s_idle_bat;
// navigation
static lv_obj_t  *s_route_casing, *s_route_line, *s_me, *s_top, *s_bottom;
static lv_obj_t  *s_turn_shaft, *s_turn_head, *s_turn_ring, *s_turn_exit;
static lv_obj_t  *s_dist, *s_street, *s_info1, *s_info2, *s_lost, *s_north;
static lv_point_t s_pts[MAX_VIS];
static lv_point_t s_shaft_pts[6], s_head_pts[5];
static float      s_span_m = 300;   // metres from my arrow to the top of the view

// ── helpers ───────────────────────────────────────────────────────────
static lv_obj_t *layer(lv_obj_t *parent) {
    lv_obj_t *o = lv_obj_create(parent);
    lv_obj_remove_style_all(o);
    lv_obj_set_size(o, SCREEN_W, SCREEN_H);
    lv_obj_clear_flag(o, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_clear_flag(o, LV_OBJ_FLAG_CLICKABLE);
    return o;
}

static lv_obj_t *label(lv_obj_t *p, const lv_font_t *f, uint32_t col, lv_align_t al, int x, int y) {
    lv_obj_t *l = lv_label_create(p);
    lv_obj_set_style_text_font(l, f, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(col), 0);
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_text(l, "");
    lv_obj_align(l, al, x, y);
    return l;
}

static lv_obj_t *line(lv_obj_t *p, int w, uint32_t col) {
    lv_obj_t *l = lv_line_create(p);
    lv_obj_set_style_line_width(l, w, 0);
    lv_obj_set_style_line_color(l, lv_color_hex(col), 0);
    lv_obj_set_style_line_rounded(l, true, 0);
    return l;
}

static lv_obj_t *bar(lv_obj_t *p, int y, int h) {
    lv_obj_t *b = lv_obj_create(p);
    lv_obj_remove_style_all(b);
    lv_obj_set_size(b, SCREEN_W, h);
    lv_obj_set_pos(b, 0, y);
    lv_obj_set_style_bg_color(b, lv_color_hex(0x000000), 0);
    lv_obj_set_style_bg_opa(b, LV_OPA_80, 0);
    lv_obj_clear_flag(b, LV_OBJ_FLAG_CLICKABLE);
    return b;
}

static void fmt_dist(char *o, size_t n, uint32_t m) {
    if (m < 1000) snprintf(o, n, "%lu m", (unsigned long)(m < 100 ? m : (m + 5) / 10 * 10));
    else if (m < 10000) snprintf(o, n, "%lu.%lu km", (unsigned long)(m / 1000), (unsigned long)(m % 1000 / 100));
    else snprintf(o, n, "%lu km", (unsigned long)((m + 500) / 1000));
}

static bool fmt_clock(char *o, size_t n, uint32_t unix_utc, int32_t off, bool valid) {
    if (!valid || unix_utc < 1600000000UL) { snprintf(o, n, "--:--"); return false; }
    time_t t = (time_t)unix_utc + off;
    struct tm tm;
    gmtime_r(&t, &tm);
    snprintf(o, n, "%02d:%02d", tm.tm_hour, tm.tm_min);
    return true;
}

// ── turn arrows (same shapes as the phone app), 100 x 100 box ─────────
struct Pt { uint8_t x, y; };
struct Shape { uint8_t ns; Pt shaft[6]; uint8_t nh; Pt head[5]; uint8_t ring; };
static const Shape SHAPES[TURN_COUNT] = {
    /* STRAIGHT     */ {2, {{50, 95}, {50, 12}}, 3, {{24, 38}, {50, 12}, {76, 38}}, 0},
    /* SLIGHT_LEFT  */ {3, {{64, 95}, {64, 60}, {26, 22}}, 3, {{50, 20}, {24, 20}, {24, 46}}, 0},
    /* LEFT         */ {3, {{70, 95}, {70, 50}, {18, 50}}, 3, {{38, 30}, {16, 50}, {38, 70}}, 0},
    /* SHARP_LEFT   */ {3, {{70, 95}, {70, 30}, {30, 72}}, 3, {{30, 48}, {28, 74}, {54, 74}}, 0},
    /* SLIGHT_RIGHT */ {3, {{36, 95}, {36, 60}, {74, 22}}, 3, {{50, 20}, {76, 20}, {76, 46}}, 0},
    /* RIGHT        */ {3, {{30, 95}, {30, 50}, {82, 50}}, 3, {{62, 30}, {84, 50}, {62, 70}}, 0},
    /* SHARP_RIGHT  */ {3, {{30, 95}, {30, 30}, {70, 72}}, 3, {{70, 48}, {72, 74}, {46, 74}}, 0},
    /* UTURN        */ {6, {{70, 95}, {70, 36}, {62, 20}, {38, 20}, {30, 36}, {30, 70}}, 3,
                          {{14, 54}, {30, 72}, {46, 54}}, 0},
    /* ROUNDABOUT   */ {2, {{50, 96}, {50, 76}}, 5, {{63, 37}, {84, 16}, {64, 16}, {84, 16}, {84, 36}}, 2},
    /* ARRIVE       */ {0, {}, 0, {}, 1},
    /* DEPART       */ {2, {{50, 95}, {50, 12}}, 3, {{24, 38}, {50, 12}, {76, 38}}, 0},
};
#define TBOX_X 56       // turn icon box on screen (44 x 44)
#define TBOX_Y 18
#define TBOX_S 0.44f

static void set_poly(lv_obj_t *l, lv_point_t *dst, const Pt *src, uint8_t n) {
    if (n < 2) { lv_obj_add_flag(l, LV_OBJ_FLAG_HIDDEN); return; }
    for (uint8_t i = 0; i < n; i++) {
        dst[i].x = TBOX_X + (lv_coord_t)(src[i].x * TBOX_S);
        dst[i].y = TBOX_Y + (lv_coord_t)(src[i].y * TBOX_S);
    }
    lv_line_set_points(l, dst, n);
    lv_obj_clear_flag(l, LV_OBJ_FLAG_HIDDEN);
}

static void draw_turn(uint8_t turn, uint8_t exit_no, bool near) {
    const Shape &s = SHAPES[turn < TURN_COUNT ? turn : 0];
    uint32_t col = near ? COL_GOLD : COL_TEXT;
    lv_obj_set_style_line_color(s_turn_shaft, lv_color_hex(col), 0);
    lv_obj_set_style_line_color(s_turn_head, lv_color_hex(col), 0);
    set_poly(s_turn_shaft, s_shaft_pts, s.shaft, s.ns);
    set_poly(s_turn_head, s_head_pts, s.head, s.nh);
    if (s.ring) {
        int d = s.ring == 1 ? 28 : 18;
        lv_obj_set_size(s_turn_ring, d, d);
        lv_obj_set_style_border_width(s_turn_ring, s.ring == 1 ? 5 : 4, 0);
        lv_obj_set_style_border_color(s_turn_ring, lv_color_hex(s.ring == 1 ? COL_OK : col), 0);
        lv_obj_set_pos(s_turn_ring, TBOX_X + 22 - d / 2, TBOX_Y + (s.ring == 1 ? 22 : 25) - d / 2);
        lv_obj_clear_flag(s_turn_ring, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(s_turn_ring, LV_OBJ_FLAG_HIDDEN);
    }
    if (turn == TURN_ROUNDABOUT && exit_no) {
        lv_label_set_text_fmt(s_turn_exit, "%u", exit_no);
        lv_obj_clear_flag(s_turn_exit, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(s_turn_exit, LV_OBJ_FLAG_HIDDEN);
    }
}

// ── build ─────────────────────────────────────────────────────────────
static lv_obj_t *make_me_arrow(lv_obj_t *p) {
    // Position chevron drawn once on a small canvas (heading-up, so it never rotates).
    static lv_color_t buf[LV_CANVAS_BUF_SIZE_TRUE_COLOR_ALPHA(34, 34)];
    lv_obj_t *c = lv_canvas_create(p);
    lv_canvas_set_buffer(c, buf, 34, 34, LV_IMG_CF_TRUE_COLOR_ALPHA);
    lv_canvas_fill_bg(c, lv_color_hex(0), LV_OPA_TRANSP);
    lv_draw_rect_dsc_t d;
    lv_draw_rect_dsc_init(&d);
    d.bg_color = lv_color_hex(0xFFFFFF);
    d.bg_opa = LV_OPA_COVER;
    lv_point_t outer[4] = {{17, 1}, {32, 32}, {17, 24}, {2, 32}};
    lv_canvas_draw_polygon(c, outer, 4, &d);
    d.bg_color = lv_color_hex(COL_ROUTE);
    lv_point_t inner[4] = {{17, 7}, {28, 29}, {17, 22}, {6, 29}};
    lv_canvas_draw_polygon(c, inner, 4, &d);
    lv_obj_set_pos(c, ARROW_X - 17, ARROW_Y - 17);
    return c;
}

void ui_init() {
    lv_obj_t *scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, lv_color_hex(COL_BG), 0);
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    // Waiting for phone
    s_wait = layer(scr);
    label(s_wait, &lv_font_montserrat_20, COL_TEXT, LV_ALIGN_CENTER, 0, -30);
    lv_label_set_text(lv_obj_get_child(s_wait, 0), "NavLink");
    s_wait_dot = label(s_wait, &lv_font_montserrat_48, COL_ROUTE, LV_ALIGN_CENTER, 0, 22);
    lv_label_set_text(s_wait_dot, LV_SYMBOL_BLUETOOTH);
    lv_obj_t *w2 = label(s_wait, &lv_font_montserrat_14, COL_MUTED, LV_ALIGN_CENTER, 0, 70);
    lv_label_set_text(w2, "Waiting for phone...");

    // Connected, idle
    s_idle = layer(scr);
    s_idle_clock = label(s_idle, &lv_font_montserrat_48, COL_TEXT, LV_ALIGN_CENTER, 0, -14);
    lv_obj_t *i2 = label(s_idle, &lv_font_montserrat_16, COL_OK, LV_ALIGN_CENTER, 0, 32);
    lv_label_set_text(i2, LV_SYMBOL_OK " Connected");
    lv_obj_t *i3 = label(s_idle, &lv_font_montserrat_14, COL_MUTED, LV_ALIGN_CENTER, 0, 58);
    lv_label_set_text(i3, "Start a route in NavLink");
    s_idle_bat = label(s_idle, &lv_font_montserrat_14, COL_MUTED, LV_ALIGN_CENTER, 0, 88);

    // Navigation
    s_nav = layer(scr);
    s_route_casing = line(s_nav, 14, COL_CASING);
    s_route_line = line(s_nav, 8, COL_ROUTE);
    lv_obj_set_size(s_route_casing, SCREEN_W, SCREEN_H);
    lv_obj_set_size(s_route_line, SCREEN_W, SCREEN_H);
    s_me = make_me_arrow(s_nav);

    s_top = bar(s_nav, 0, 84);
    s_turn_ring = lv_obj_create(s_top);
    lv_obj_remove_style_all(s_turn_ring);
    lv_obj_set_style_radius(s_turn_ring, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_opa(s_turn_ring, LV_OPA_COVER, 0);
    s_turn_shaft = line(s_top, 6, COL_TEXT);
    s_turn_head = line(s_top, 6, COL_TEXT);
    s_turn_exit = label(s_top, &lv_font_montserrat_14, COL_TEXT, LV_ALIGN_TOP_LEFT, TBOX_X + 17, TBOX_Y + 17);
    s_dist = label(s_top, &lv_font_montserrat_20, COL_TEXT, LV_ALIGN_TOP_LEFT, 108, 26);
    s_street = label(s_top, &lv_font_montserrat_14, 0xC0D0E0, LV_ALIGN_TOP_MID, 0, 62);
    lv_obj_set_width(s_street, 176);
    lv_label_set_long_mode(s_street, LV_LABEL_LONG_SCROLL_CIRCULAR);

    s_bottom = bar(s_nav, 188, 52);
    s_info1 = label(s_bottom, &lv_font_montserrat_14, COL_TEXT, LV_ALIGN_TOP_MID, 0, 6);
    s_info2 = label(s_bottom, &lv_font_montserrat_14, COL_MUTED, LV_ALIGN_TOP_MID, 0, 25);

    s_north = label(s_nav, &lv_font_montserrat_14, COL_MUTED, LV_ALIGN_TOP_LEFT, 0, 0);
    lv_label_set_text(s_north, "N");

    s_lost = label(s_nav, &lv_font_montserrat_16, COL_TEXT, LV_ALIGN_CENTER, 0, 0);
    lv_obj_set_style_bg_color(s_lost, lv_color_hex(0x7A1E26), 0);
    lv_obj_set_style_bg_opa(s_lost, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(s_lost, 6, 0);
    lv_obj_set_style_radius(s_lost, 8, 0);
    lv_label_set_text(s_lost, LV_SYMBOL_WARNING " Signal lost");
    lv_obj_add_flag(s_lost, LV_OBJ_FLAG_HIDDEN);

    // Arrived
    s_arrived = layer(scr);
    lv_obj_t *a1 = label(s_arrived, &lv_font_montserrat_48, COL_OK, LV_ALIGN_CENTER, 0, -18);
    lv_label_set_text(a1, LV_SYMBOL_OK);
    lv_obj_t *a2 = label(s_arrived, &lv_font_montserrat_20, COL_TEXT, LV_ALIGN_CENTER, 0, 30);
    lv_label_set_text(a2, "Arrived");

    ui_set_mode(UI_WAITING);
}

void ui_set_mode(UiMode m) {
    s_mode = m;
    lv_obj_t *all[4] = {s_wait, s_idle, s_nav, s_arrived};
    for (int i = 0; i < 4; i++) {
        if (i == (int)m) lv_obj_clear_flag(all[i], LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(all[i], LV_OBJ_FLAG_HIDDEN);
    }
}

UiMode ui_mode() { return s_mode; }

// ── route view ────────────────────────────────────────────────────────
static void draw_route(const UiState &s) {
    const Route *r = s.route;
    const Position *p = s.pos;
    if (!r || !r->valid || !p || !p->valid) {
        lv_obj_add_flag(s_route_line, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_route_casing, LV_OBJ_FLAG_HIDDEN);
        return;
    }
    // Auto-zoom: wider when fast, tighter near a turn; smoothed.
    float v = p->speed_kmh;
    float span = v < 12 ? 140 : v < 35 ? 260 : v < 70 ? 480 : 800;
    if (s.man && s.man->valid && s.man->to_turn_m < 250) {
        float near = fmaxf(90.0f, s.man->to_turn_m * 1.5f);
        if (near < span) span = near;
    }
    s_span_m += (span - s_span_m) * 0.15f;
    float scale = (ARROW_Y - 20) / s_span_m;           // px per metre

    double lat0 = p->lat / 1e6, lon0 = p->lon / 1e6;
    float kx = (float)(cos(lat0 * M_PI / 180.0) * 111320.0), ky = 110540.0f;
    float h = p->heading * (float)M_PI / 180.0f, ch = cosf(h), sh = sinf(h);
    float limit = s_span_m * 2.2f;                      // stop once far off screen

    int n = 0;
    int start = s.snap_idx > 2 ? s.snap_idx - 2 : 0;
    for (int i = start; i < r->received && n < MAX_VIS; i++) {
        float x = (float)((r->lon[i] / 1e6 - lon0) * kx);
        float y = (float)((r->lat[i] / 1e6 - lat0) * ky);
        float xr = x * ch - y * sh, yr = x * sh + y * ch;   // heading-up
        bool far = fabsf(xr) > limit || fabsf(yr) > limit;
        float sx = ARROW_X + xr * scale, sy = ARROW_Y - yr * scale;
        s_pts[n].x = (lv_coord_t)fmaxf(-2000.0f, fminf(2000.0f, sx));
        s_pts[n].y = (lv_coord_t)fmaxf(-2000.0f, fminf(2000.0f, sy));
        n++;
        if (far && n > 2) break;     // this segment already leaves the view
    }
    if (n < 2) {
        lv_obj_add_flag(s_route_line, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_route_casing, LV_OBJ_FLAG_HIDDEN);
        return;
    }
    lv_line_set_points(s_route_casing, s_pts, n);
    lv_line_set_points(s_route_line, s_pts, n);
    lv_obj_clear_flag(s_route_line, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(s_route_casing, LV_OBJ_FLAG_HIDDEN);

    // Small "N" marker on the edge showing where north is.
    float nx = -sh, ny = ch;   // north unit vector in heading-up screen space
    lv_obj_set_pos(s_north, (lv_coord_t)(120 + nx * 98 - 5), (lv_coord_t)(120 - ny * 98 - 8));
}

void ui_refresh(const UiState &s) {
    char a[48], b[48];
    switch (s_mode) {
    case UI_WAITING: {
        static uint8_t t = 0;   // gentle pulse on the BLE symbol
        t++;
        lv_obj_set_style_text_opa(s_wait_dot, (t / 5) % 2 ? LV_OPA_40 : LV_OPA_COVER, 0);
        break;
    }
    case UI_IDLE:
        fmt_clock(a, sizeof a, (uint32_t)time(nullptr), s.utc_offset_s, s.time_valid);
        lv_label_set_text(s_idle_clock, a);
        if (s.battery_pct >= 0) lv_label_set_text_fmt(s_idle_bat, LV_SYMBOL_BATTERY_FULL " %d%%", s.battery_pct);
        break;
    case UI_NAV: {
        draw_route(s);
        const Maneuver *m = s.man;
        if (m && m->valid) {
            bool near = m->to_turn_m <= 100 && m->turn != TURN_ARRIVE;
            draw_turn(m->turn, m->exit, near);
            fmt_dist(a, sizeof a, m->to_turn_m);
            lv_label_set_text(s_dist, a);
            lv_obj_set_style_text_color(s_dist, lv_color_hex(near ? COL_GOLD : COL_TEXT), 0);
            lv_label_set_text(s_street, m->street);
            fmt_dist(a, sizeof a, m->remaining_m);
            fmt_clock(b, sizeof b, m->eta_unix, s.utc_offset_s, s.time_valid);
            lv_label_set_text_fmt(s_info1, "%s  " LV_SYMBOL_RIGHT "  %s", a, b);
        } else {
            lv_label_set_text(s_dist, "");
            lv_label_set_text(s_street, "Waiting for directions");
            lv_label_set_text(s_info1, "");
        }
        int kmh = s.pos && s.pos->valid ? (int)lroundf(s.pos->speed_kmh) : 0;
        lv_label_set_text_fmt(s_info2, "%d km/h   %s", kmh, LV_SYMBOL_BLUETOOTH);
        lv_obj_set_style_text_color(s_info2, lv_color_hex(s.connected ? COL_OK : COL_BAD), 0);
        if (s.signal_lost) lv_obj_clear_flag(s_lost, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(s_lost, LV_OBJ_FLAG_HIDDEN);
        break;
    }
    case UI_ARRIVED:
        break;
    }
}
