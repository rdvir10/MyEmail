package com.rdvir.mailtree

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
class WindowActivity : MainActivity()
