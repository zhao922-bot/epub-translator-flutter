package com.yang.epubtranslator

/** UI-thread registry. Timed-out requests keep their code until the late
 * Activity result arrives, but release the MethodChannel result reference. */
internal class PickerRequestRegistry<T>(
    private val first: Int = 0x4000,
    private val last: Int = 0xffff,
) {
    private var next = first
    private val pending = mutableMapOf<Int, T?>()

    init {
        require(first in 0..0xffff && last in first..0xffff)
    }

    fun register(attempt: T): Int? {
        repeat(last - first + 1) {
            val code = next
            next = if (next == last) first else next + 1
            if (!pending.containsKey(code)) {
                pending[code] = attempt
                return code
            }
        }
        return null
    }

    fun abandon(code: Int) {
        if (pending.containsKey(code)) pending[code] = null
    }

    fun consume(code: Int): T? = pending.remove(code)

    fun outstandingCodes(): IntArray = pending.keys.toIntArray()

    fun restoreAbandoned(codes: IntArray) {
        for (code in codes) {
            if (code in first..last) pending.putIfAbsent(code, null)
        }
    }
}
