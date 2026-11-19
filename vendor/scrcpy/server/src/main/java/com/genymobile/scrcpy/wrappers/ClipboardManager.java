package com.genymobile.scrcpy.wrappers;

import com.genymobile.scrcpy.AndroidVersions;
import com.genymobile.scrcpy.FakeContext;

import android.content.ClipData;
import android.content.ClipDescription;
import android.content.Context;
import android.os.Build;
import android.os.PersistableBundle;

public final class ClipboardManager {
    private final android.content.ClipboardManager manager;

    static ClipboardManager create() {
        android.content.ClipboardManager manager = (android.content.ClipboardManager) FakeContext.get().getSystemService(Context.CLIPBOARD_SERVICE);
        if (manager == null) {
            // Some devices have no clipboard manager
            // <https://github.com/Genymobile/scrcpy/issues/1440>
            // <https://github.com/Genymobile/scrcpy/issues/1556>
            return null;
        }
        return new ClipboardManager(manager);
    }

    private ClipboardManager(android.content.ClipboardManager manager) {
        this.manager = manager;
    }

    public CharSequence getText() {
        ClipData clipData = manager.getPrimaryClip();
        if (clipData == null || clipData.getItemCount() == 0) {
            return null;
        }
        return clipData.getItemAt(0).getText();
    }

    public boolean setText(CharSequence text) {
        ClipData clipData = ClipData.newPlainText(null, text);
        manager.setPrimaryClip(clipData);
        return true;
    }

    /**
     * Кладёт текст в буфер для внутренней вставки (фолбэк кириллицы).
     * В отличие от setText() всегда перезаписывает буфер: при наборе
     * повторяющегося символа («пп») текст в буфере не меняется, но PASTE
     * всё равно нужен. На Android 13+ помечает буфер как sensitive,
     * чтобы системный оверлей не показывал и не сохранял набираемое.
     */
    public boolean setTextForPaste(CharSequence text) {
        ClipDescription description = new ClipDescription(null,
                new String[] {ClipDescription.MIMETYPE_TEXT_PLAIN});
        if (Build.VERSION.SDK_INT >= AndroidVersions.API_33_ANDROID_13) {
            PersistableBundle extras = new PersistableBundle();
            extras.putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true);
            description.setExtras(extras);
        }
        ClipData clipData = new ClipData(description, new ClipData.Item(text));
        manager.setPrimaryClip(clipData);
        return true;
    }

    public void addPrimaryClipChangedListener(android.content.ClipboardManager.OnPrimaryClipChangedListener listener) {
        manager.addPrimaryClipChangedListener(listener);
    }
}
