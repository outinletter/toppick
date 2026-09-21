package com.addvalue.toppicks

import org.junit.Test

import org.junit.Assert.assertEquals

class ExampleUnitTest {
    @Test
    fun returnRate_isCalculatedFromEntryAndExit() {
        assertEquals(10.0, calculateReturn(100.0, 110.0), 0.0001)
        assertEquals(-10.0, calculateReturn(100.0, 90.0), 0.0001)
        assertEquals(0.0, calculateReturn(0.0, 90.0), 0.0001)
    }

    @Test
    fun horizons_areKeptSeparately() {
        assertEquals(emptyList<Int>(), availableHorizons(0))
        assertEquals(listOf(1), availableHorizons(1))
        assertEquals(listOf(1, 2), availableHorizons(2))
        assertEquals(listOf(1, 2, 3), availableHorizons(3))
    }
}
