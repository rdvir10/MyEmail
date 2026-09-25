package com.rdvir.mailtree

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Where the browser lands after a Google sign-in.
 *
 * The sign-in page opens in the phone's browser as a custom tab on top of
 * this app's task. When it is done, the browser follows the redirect to the
 * app's own URI scheme, and Android starts this activity for it. Nothing is
 * done here but to pass the URL to MainActivity with CLEAR_TOP, which is
 * what closes the tab above it and hands the running activity the intent
 * through onNewIntent, rather than starting a second copy of the app on
 * top of the first.
 *
 * Exported, because the browser starts it; it takes the URL and nothing
 * else, and MainActivity checks the scheme before it believes any of it.
 */
class OAuthRedirectActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val data = intent?.data
        if (data != null) {
            startActivity(
                Intent(this, MainActivity::class.java).apply {
                    action = Intent.ACTION_VIEW
                    setData(data)
                    addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                },
            )
        }
        finish()
    }
}
