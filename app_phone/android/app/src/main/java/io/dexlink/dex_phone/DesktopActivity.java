package io.dexlink.dex_phone;

import android.app.Activity;
import android.os.Bundle;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Shader;
import android.view.View;

/** A real background task for DexLink's independent Android display. */
public final class DesktopActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        // Never replace the user's phone launcher or render this on display 0.
        if (getWindowManager().getDefaultDisplay().getDisplayId() == 0) {
            finish();
            return;
        }
        getWindow().getDecorView().setSystemUiVisibility(5894);
        setContentView(new View(this) {
            private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
            @Override protected void onDraw(Canvas canvas) {
                float w = getWidth(), h = getHeight();
                paint.setShader(new LinearGradient(0, 0, w, h,
                        Color.rgb(205, 219, 233), Color.rgb(98, 128, 155), Shader.TileMode.CLAMP));
                canvas.drawRect(0, 0, w, h, paint);
                paint.setShader(null);
                android.graphics.Path ribbon = new android.graphics.Path();
                ribbon.moveTo(-w * .1f, h);
                ribbon.cubicTo(w * .25f, -h * .3f, w * .55f, h * 1.3f, w * 1.1f, -h * .1f);
                ribbon.lineTo(w * 1.1f, h); ribbon.close();
                paint.setShader(new LinearGradient(0, h, w, 0,
                        0x6685A9C5, 0x99DCE8EE, Shader.TileMode.CLAMP));
                canvas.drawPath(ribbon, paint);
                paint.setShader(null);
            }
        });
    }
}
