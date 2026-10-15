package com.rdvir.mailtree

import android.os.Bundle

/**
 * The activity a second window runs in.
 *
 * The same activity as the app, under another name, because the name is
 * what Android keys tasks on. MainActivity is singleTop: an intent for it
 * lands on the copy already running, and NEW_DOCUMENT with MULTIPLE_TASK
 * was seen to make no difference to that on One UI (start result
 * "delivered to top", no new task). This one has its own task affinity
 * and launches as a document, so every start is a new task, which is what
 * a window is.
 */
class WindowActivity : MainActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The window that opened this one is waiting to hear it exists. Not
        // a window rebuilt from saved state: nobody is waiting for that.
        if (savedInstanceState == null) {
            WindowsBridge.arrived(intent.getStringExtra("route"))
        }
    }
}
