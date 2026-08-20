package com.allthingsclaude.battery.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The wrap is the whole point, so it is the case with the most tests.
 *
 * Everything here is what a Quick Settings tile or a card action will do on a
 * single tap, where there is no picker to fall back on and no room for one —
 * getting "next" wrong there means the user cannot reach an account at all.
 */
class AccountCycleTest {

    @Test
    fun `advances to the following account`() {
        assertEquals("b", AccountCycle.next(listOf("a", "b", "c"), "a"))
        assertEquals("c", AccountCycle.next(listOf("a", "b", "c"), "b"))
    }

    @Test
    fun `wraps from the last account back to the first`() {
        assertEquals("a", AccountCycle.next(listOf("a", "b", "c"), "c"))
    }

    @Test
    fun `two accounts behave as a toggle without a special case`() {
        assertEquals("b", AccountCycle.next(listOf("a", "b"), "a"))
        assertEquals("a", AccountCycle.next(listOf("a", "b"), "b"))
    }

    @Test
    fun `a full cycle returns to where it started`() {
        val ids = listOf("a", "b", "c", "d", "e")
        var at: String? = "a"
        repeat(ids.size) { at = AccountCycle.next(ids, at) }
        assertEquals("a", at)
    }

    @Test
    fun `nothing to switch to`() {
        assertNull(AccountCycle.next(emptyList(), null))
        assertNull(AccountCycle.next(listOf("a"), "a"))
        // Single account, and it is not even the selected one — still nowhere
        // to go, and still not an error.
        assertNull(AccountCycle.next(listOf("a"), "zzz"))
    }

    @Test
    fun `an unset or stale selection starts at the front`() {
        assertEquals("a", AccountCycle.next(listOf("a", "b", "c"), null))
        // The selected account was removed while a tile held a stale id. The
        // cycle must still move rather than stall on a missing member.
        assertEquals("a", AccountCycle.next(listOf("a", "b", "c"), "removed"))
    }
}
