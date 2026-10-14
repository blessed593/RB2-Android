package org.rb2recomp.android;

import android.content.Context;
import android.graphics.Rect;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.util.TypedValue;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;

import java.util.Arrays;

import org.libsdl.app.SDLActivity;

public class GameActivity extends SDLActivity {

    private long lastControllerMotionLogMs;

    @Override
    protected void onCreate(android.os.Bundle savedInstanceState) {
        try {
            android.content.res.AssetManager assets = getAssets();
            String[] bundled = assets.list("drivers");
            if (bundled != null) {
                for (String name : bundled) {
                    String[] files = assets.list("drivers/" + name);
                    if (files == null) {
                        continue;
                    }
                    java.io.File dst = new java.io.File(getFilesDir(), "drivers/" + name);
                    dst.mkdirs();
                    for (String file : files) {
                        java.io.File out = new java.io.File(dst, file);
                        long want;
                        try (android.content.res.AssetFileDescriptor afd =
                                     assets.openFd("drivers/" + name + "/" + file)) {
                            want = afd.getLength();
                        } catch (java.io.IOException compressed) {
                            want = -1;
                        }
                        if (out.isFile() && want >= 0 && out.length() == want) {
                            continue;
                        }
                        try (java.io.InputStream in = assets.open("drivers/" + name + "/" + file);
                             java.io.OutputStream os = new java.io.FileOutputStream(out)) {
                            byte[] buf = new byte[1 << 16];
                            int n;
                            while ((n = in.read(buf)) > 0) {
                                os.write(buf, 0, n);
                            }
                        }
                        android.util.Log.i("rb2", "bundled driver file copied: " + out);
                        new java.io.File(getFilesDir(), "drivers/.failed_" + name).delete();
                    }
                }
            }
        } catch (Throwable t) {
            android.util.Log.w("rb2", "bundled driver copy failed", t);
        }

        try {
            java.io.File src = new java.io.File(LaunchConfig.root(this), "drivers");
            java.io.File[] folders = src.listFiles();
            if (folders != null) {
                for (java.io.File folder : folders) {
                    java.io.File[] files = folder.listFiles();
                    if (files == null) {
                        continue;
                    }
                    java.io.File dst = new java.io.File(getFilesDir(), "drivers/" + folder.getName());
                    dst.mkdirs();
                    for (java.io.File f : files) {
                        java.io.File out = new java.io.File(dst, f.getName());
                        if (!f.isFile() || (out.isFile() && out.length() == f.length())) {
                            continue;
                        }
                        try (java.io.InputStream in = new java.io.FileInputStream(f);
                             java.io.OutputStream os = new java.io.FileOutputStream(out)) {
                            byte[] buf = new byte[1 << 16];
                            int n;
                            while ((n = in.read(buf)) > 0) {
                                os.write(buf, 0, n);
                            }
                        }
                        android.util.Log.i("rb2", "driver file copied: " + out);
                        new java.io.File(getFilesDir(), "drivers/.failed_" + folder.getName()).delete();
                    }
                }
            }
        } catch (Throwable t) {
            android.util.Log.w("rb2", "driver copy failed", t);
        }

        super.onCreate(savedInstanceState);

        if (mLayout != null && !mBrokenLibraries) {
            menu = new InGameMenu(this, mLayout, LaunchConfig.renderScale(this),
                    new InGameMenu.Native() {
                @Override
                public boolean setCvar(String name, String value) {
                    try {
                        return nativeSetCvar(name, value);
                    } catch (UnsatisfiedLinkError e) {
                        return false;
                    }
                }

                @Override
                public void shown(boolean open) {
                    try {
                        nativeSystemUi(open);
                    } catch (UnsatisfiedLinkError ignored) {
                    }
                    hideSystemBars();
                    if (!open && mSurface != null) {
                        mSurface.requestFocus();
                    }
                }

                @Override
                public void fpsModeChanged(int mode) {
                    requestDisplayRate(mode == 3);
                    getWindow().getDecorView().postDelayed(
                            GameActivity.this::hideSystemBars, 800);
                }
            });

            final View decor = getWindow().getDecorView();

            decor.setOnSystemUiVisibilityChangeListener(visibility -> {
                if ((visibility & View.SYSTEM_UI_FLAG_HIDE_NAVIGATION) == 0) {
                    decor.postDelayed(this::hideSystemBars, 1500);
                }
            });

            decor.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> {
                int w = r - l;
                int h = b - t;
                int band = dp(200);
                int edge = dp(EDGE_DP);
                int top = Math.max(0, h / 2 - band / 2);
                v.setSystemGestureExclusionRects(Arrays.asList(
                        new Rect(0, top, edge, top + band),
                        new Rect(w - edge, top, w, top + band)));
            });
        }
    }

    static native boolean nativeSetCvar(String name, String value);

    static native void nativeSystemUi(boolean open);

    private void hideSystemBars() {
        View decor = getWindow().getDecorView();
        decor.setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);

        if (android.os.Build.VERSION.SDK_INT >= 30) {
            android.view.WindowInsetsController controller =
                    getWindow().getInsetsController();
            if (controller != null) {
                controller.setSystemBarsBehavior(
                        android.view.WindowInsetsController
                                .BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
                controller.hide(android.view.WindowInsets.Type.systemBars());
            }
        }
    }

    private static final int EDGE_DP = 36;
    private static final int SWIPE_DP = 48;

    private InGameMenu menu;
    private boolean edgeTracking, edgeFromRight, swallowGesture;
    private float edgeDownX, edgeDownY;
    private float hatX, hatY;

    /*
     * Diagnóstico do controle.
     * Salva os eventos em controller-input-debug.txt dentro da pasta
     * retornada por LaunchConfig.root(this).
     */
    private void writeInputDiagnostic(String message) {
        android.util.Log.i("RB2_INPUT", message);

        try {
            java.io.File file = new java.io.File(
                    LaunchConfig.root(this),
                    "controller-input-debug.txt");

            java.io.File parent = file.getParentFile();
            if (parent != null && !parent.exists()) {
                parent.mkdirs();
            }

            try (java.io.FileWriter writer =
                         new java.io.FileWriter(file, true)) {
                writer.write(
                        java.text.DateFormat.getDateTimeInstance().format(
                                new java.util.Date())
                                + " " + message + "\n");
            }
        } catch (Exception e) {
            android.util.Log.e(
                    "RB2_INPUT", "Falha ao salvar diagnóstico", e);
        }
    }

    private void logControllerKey(KeyEvent event) {
        InputDevice device = event.getDevice();

        writeInputDiagnostic(
                "KEY action=" + event.getAction()
                + " keyCode=" + event.getKeyCode()
                + " scanCode=" + event.getScanCode()
                + " device=" + (device != null
                        ? device.getName() : "unknown")
                + " vendor=" + (device != null
                        ? device.getVendorId() : -1)
                + " product=" + (device != null
                        ? device.getProductId() : -1)
                + " source=" + event.getSource());
    }

    private void logControllerMotion(MotionEvent event) {
        long now = android.os.SystemClock.uptimeMillis();

        if (now - lastControllerMotionLogMs < 250) {
            return;
        }

        lastControllerMotionLogMs = now;
        InputDevice device = event.getDevice();

        writeInputDiagnostic(
                "MOTION action=" + event.getActionMasked()
                + " device=" + (device != null
                        ? device.getName() : "unknown")
                + " vendor=" + (device != null
                        ? device.getVendorId() : -1)
                + " product=" + (device != null
                        ? device.getProductId() : -1)
                + " source=" + event.getSource()
                + " x=" + event.getAxisValue(MotionEvent.AXIS_X)
                + " y=" + event.getAxisValue(MotionEvent.AXIS_Y)
                + " hatX=" + event.getAxisValue(MotionEvent.AXIS_HAT_X)
                + " hatY=" + event.getAxisValue(MotionEvent.AXIS_HAT_Y));
    }

    private boolean isControllerEvent(KeyEvent event) {
        InputDevice device = event.getDevice();

        if (device == null) {
            return false;
        }

        return event.isFromSource(InputDevice.SOURCE_GAMEPAD)
                || event.isFromSource(InputDevice.SOURCE_DPAD)
                || event.isFromSource(InputDevice.SOURCE_JOYSTICK);
    }

    private boolean isControllerMotion(MotionEvent event) {
        return event.isFromSource(InputDevice.SOURCE_JOYSTICK)
                || event.isFromSource(InputDevice.SOURCE_GAMEPAD);
    }

    private int dp(int value) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP,
                value,
                getResources().getDisplayMetrics()));
    }

    private void openMenu(boolean fromRight) {
        if (menu != null && !menu.isOpen()) {
            menu.open(fromRight);
        }
    }

    private void closeMenuIfOpen() {
        if (menu != null && menu.isOpen()) {
            menu.close();
        }
        if (mSurface != null) {
            mSurface.requestFocus();
        }
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent ev) {
        if (menu == null) {
            return super.dispatchTouchEvent(ev);
        }

        final int action = ev.getActionMasked();

        if (swallowGesture) {
            if (action == MotionEvent.ACTION_UP
                    || action == MotionEvent.ACTION_CANCEL) {
                swallowGesture = false;
            }
            return true;
        }

        if (menu.isOpen()) {
            boolean handled = super.dispatchTouchEvent(ev);
            if (!menu.isOpen() && mSurface != null) {
                mSurface.requestFocus();
            }
            return handled;
        }

        if (action == MotionEvent.ACTION_DOWN) {
            int width = getWindow().getDecorView().getWidth();
            float x = ev.getX();

            edgeTracking = x < dp(EDGE_DP)
                    || x > width - dp(EDGE_DP);
            edgeFromRight = x > width / 2f;
            edgeDownX = x;
            edgeDownY = ev.getY();

        } else if (action == MotionEvent.ACTION_MOVE && edgeTracking) {
            float dx = edgeFromRight
                    ? edgeDownX - ev.getX()
                    : ev.getX() - edgeDownX;
            float dy = Math.abs(ev.getY() - edgeDownY);

            if (dx > dp(SWIPE_DP) && dx > dy) {
                edgeTracking = false;

                MotionEvent cancel = MotionEvent.obtain(ev);
                cancel.setAction(MotionEvent.ACTION_CANCEL);
                super.dispatchTouchEvent(cancel);
                cancel.recycle();

                swallowGesture = true;
                openMenu(edgeFromRight);
                return true;
            }

        } else if (action == MotionEvent.ACTION_UP
                || action == MotionEvent.ACTION_CANCEL) {
            edgeTracking = false;
        }

        return super.dispatchTouchEvent(ev);
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (isControllerEvent(event)) {
            logControllerKey(event);
        }

        if (menu != null && menu.isOpen()) {
            if (menu.onKey(event)) {
                if (!menu.isOpen() && mSurface != null) {
                    mSurface.requestFocus();
                }
                return true;
            }

            getWindow().superDispatchKeyEvent(event);
            return true;
        }

        return super.dispatchKeyEvent(event);
    }

    @Override
    public boolean dispatchGenericMotionEvent(MotionEvent ev) {
        if (ev.getActionMasked() == MotionEvent.ACTION_MOVE
                && isControllerMotion(ev)) {
            logControllerMotion(ev);
        }

        if (menu != null && menu.isOpen()) {
            if ((ev.getSource() & InputDevice.SOURCE_JOYSTICK)
                    == InputDevice.SOURCE_JOYSTICK
                    && ev.getActionMasked() == MotionEvent.ACTION_MOVE) {

                float x = ev.getAxisValue(MotionEvent.AXIS_HAT_X);
                float y = ev.getAxisValue(MotionEvent.AXIS_HAT_Y);
                int key = 0;

                if (x < -0.5f && hatX >= -0.5f) {
                    key = KeyEvent.KEYCODE_DPAD_LEFT;
                } else if (x > 0.5f && hatX <= 0.5f) {
                    key = KeyEvent.KEYCODE_DPAD_RIGHT;
                } else if (y < -0.5f && hatY >= -0.5f) {
                    key = KeyEvent.KEYCODE_DPAD_UP;
                } else if (y > 0.5f && hatY <= 0.5f) {
                    key = KeyEvent.KEYCODE_DPAD_DOWN;
                }

                hatX = x;
                hatY = y;

                if (key != 0) {
                    getWindow().superDispatchKeyEvent(
                            new KeyEvent(KeyEvent.ACTION_DOWN, key));
                    getWindow().superDispatchKeyEvent(
                            new KeyEvent(KeyEvent.ACTION_UP, key));
                }
            }

            return true;
        }

        return super.dispatchGenericMotionEvent(ev);
    }

    @Override
    public void onBackPressed() {
        if (menu == null) {
            super.onBackPressed();
        } else if (menu.isOpen()) {
            closeMenuIfOpen();
        } else {
            openMenu(false);
        }
    }

    @Override
    protected String[] getLibraries() {
        return new String[] {runtimeLibraryName(this), "main"};
    }

    static String runtimeLibraryName(Context context) {
        java.io.File dir = new java.io.File(
                context.getApplicationInfo().nativeLibraryDir);

        java.io.File[] found = dir.listFiles(
                (d, name) -> name.startsWith("librexruntime")
                        && name.endsWith(".so"));

        if (found != null && found.length > 0) {
            String name = found[0].getName();
            return name.substring(3, name.length() - 3);
        }

        return "rexruntime";
    }

    @Override
    protected String[] getArguments() {
        return LaunchConfig.buildArguments(this);
    }

    private void writeDisplayHz() {
        try {
            float hz = getWindowManager()
                    .getDefaultDisplay().getRefreshRate();

            java.io.File f = new java.io.File(
                    LaunchConfig.root(this), "display_hz.txt");

            try (java.io.FileWriter w = new java.io.FileWriter(f)) {
                w.write(Integer.toString(Math.round(hz)));
            }
        } catch (Throwable t) {
            android.util.Log.w("rb2", "display_hz failed", t);
        }
    }

    private android.hardware.display.DisplayManager.DisplayListener displayListener;

    @Override
    protected void onResume() {
        super.onResume();
        writeDisplayHz();

        if (displayListener == null) {
            displayListener =
                    new android.hardware.display.DisplayManager.DisplayListener() {
                @Override
                public void onDisplayAdded(int displayId) {}

                @Override
                public void onDisplayRemoved(int displayId) {}

                @Override
                public void onDisplayChanged(int displayId) {
                    writeDisplayHz();
                }
            };

            ((android.hardware.display.DisplayManager)
                    getSystemService(DISPLAY_SERVICE))
                    .registerDisplayListener(displayListener, null);
        }

        requestDisplayRate(LaunchConfig.fpsMode(this) == 3
                || new java.io.File(
                        LaunchConfig.root(this), "highrefresh.txt").exists());

        getWindow().getDecorView().postDelayed(
                this::hideSystemBars, 800);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);

        if (hasFocus && menu != null) {
            hideSystemBars();
        }
    }

    private void requestDisplayRate(boolean high) {
        try {
            android.view.Display display =
                    getWindowManager().getDefaultDisplay();

            android.view.Display.Mode current = display.getMode();
            float want = high ? 120f : 60f;
            int best = current.getModeId();
            float bestDiff = Float.MAX_VALUE;

            for (android.view.Display.Mode m : display.getSupportedModes()) {
                if (m.getPhysicalWidth() == current.getPhysicalWidth()
                        && m.getPhysicalHeight() == current.getPhysicalHeight()
                        && Math.abs(m.getRefreshRate() - want) < bestDiff) {
                    best = m.getModeId();
                    bestDiff = Math.abs(m.getRefreshRate() - want);
                }
            }

            android.view.WindowManager.LayoutParams lp =
                    getWindow().getAttributes();

            if (lp.preferredDisplayModeId != best) {
                lp.preferredDisplayModeId = best;
                getWindow().setAttributes(lp);

                android.util.Log.i(
                        "rb2",
                        "preferred display mode " + best
                                + " (" + want + " Hz wanted)");
            }
        } catch (Throwable t) {
            android.util.Log.w("rb2", "display rate request failed", t);
        }
    }

    public static ParcelFileDescriptor openContentFd(
            String uri, String mode) {
        try {
            Context context = SDLActivity.getContext();
            return context.getContentResolver()
                    .openFileDescriptor(Uri.parse(uri), mode);
        } catch (Exception e) {
            android.util.Log.e(
                    "rb2", "openContentFd failed for " + uri, e);
            return null;
        }
    }
}
