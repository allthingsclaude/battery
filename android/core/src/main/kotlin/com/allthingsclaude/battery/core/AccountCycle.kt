package com.allthingsclaude.battery.core

/**
 * Which account "switch" means next.
 *
 * A cycle, not a toggle. The account list is N long, not two, so the primitive
 * has to be "the one after this one, wrapping" — and the two-account case then
 * falls out of it for free instead of being a second code path that can
 * disagree with the first. Alt-Tab was never designed as a two-window toggle
 * either; MRU cycling just degenerates into one.
 *
 * Pure and here rather than in `AccountStore`, because the store's version of
 * this reads SharedPreferences and the `app` module has no JVM test source set.
 * The wrap and the empty cases are exactly the parts worth pinning down.
 */
object AccountCycle {

    /**
     * The id after [selected] in [ids], wrapping past the end.
     *
     * Null when there is nothing to switch to — an empty list, or a single
     * account. Callers should read that as "leave the surface as it was", not as
     * a failure: one account is an ordinary state, and a Quick Settings tile
     * that reported an error for it would be wrong.
     *
     * An unknown or absent [selected] starts the cycle at the front rather than
     * refusing to move. That falls out of `indexOfFirst` returning -1 and -1 + 1
     * being 0, which is a coincidence worth naming so nobody "corrects" it.
     */
    fun next(ids: List<String>, selected: String?): String? {
        if (ids.size < 2) return null
        return ids[(ids.indexOfFirst { it == selected } + 1) % ids.size]
    }
}
