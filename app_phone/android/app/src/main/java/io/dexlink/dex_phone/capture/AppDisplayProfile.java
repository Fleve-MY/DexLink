package io.dexlink.dex_phone.capture;

/** Per-display layout units. Video pixels alone do not select tablet resources. */
final class AppDisplayProfile {
    static final String TABLET = "tablet", TABLET_WIDE = "tabletWide", RESPONSIVE = "responsive", PHONE = "phone";
    private static final int TABLET_SHORT_DP = 744; // 720 dp content plus system insets.
    final int width, height, density;
    final String layout;

    private AppDisplayProfile(int width, int height, int density, String layout) {
        this.width = width;
        this.height = height;
        this.density = density;
        this.layout = layout;
    }

    static AppDisplayProfile create(int width, int height, String layout) {
        if (width < 240 || height < 240 || width > 2880 || height > 2160
                || (width & 1) != 0 || (height & 1) != 0) {
            throw new IllegalArgumentException("应用窗口尺寸超出范围");
        }
        if (PHONE.equals(layout)) {
            // An explicit compatibility choice, never stretch a portrait app.
            return new AppDisplayProfile(720, 1280, 320, layout);
        }
        if (RESPONSIVE.equals(layout)) return new AppDisplayProfile(width, height, 240, layout);
        if (!TABLET.equals(layout) && !TABLET_WIDE.equals(layout)) throw new IllegalArgumentException("未知应用布局");
        int targetDp = TABLET_WIDE.equals(layout) ? 920 : TABLET_SHORT_DP;
        int shortSide = Math.min(width, height);
        // Keep the viewport's aspect ratio; provision enough actual pixels for
        // small PC windows instead of pretending that 240 px is a tablet.
        if (shortSide < targetDp * 120 / 160) {
            double scale = (double) (targetDp * 120 / 160) / shortSide;
            scale = Math.min(scale, Math.min(2880.0 / width, 2160.0 / height));
            width = ((int) Math.ceil(width * scale)) & ~1;
            height = ((int) Math.ceil(height * scale)) & ~1;
        }
        int density = Math.max(120, Math.min(240,
                (Math.min(width, height) * 160 / targetDp) / 8 * 8));
        return new AppDisplayProfile(width, height, density, layout);
    }

    int smallestWidthDp() { return Math.min(width, height) * 160 / density; }
}
